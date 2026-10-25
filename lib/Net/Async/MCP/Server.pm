package Net::Async::MCP::Server;
# ABSTRACT: Async MCP server base class

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future;
use Scalar::Util ();
use Future::AsyncAwait;

use JSON::MaybeXS qw( encode_json );
use Carp qw( croak );
use MIME::Base64 qw( encode_base64 decode_base64 );

our $VERSION = '0.004';

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::MCP::Server;
    use Net::Async::MCP::Server::Transport::Stdio;

    my $loop = IO::Async::Loop->new;

    my $server = Net::Async::MCP::Server->new(
        name => 'my-server',
    );

    $loop->add($server);

    Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    )->handle_requests;

=head1 DESCRIPTION

L<Net::Async::MCP::Server> is an asynchronous MCP (Model Context Protocol) server
built on L<IO::Async>. By default it implements the stateless, per-request
metadata variant of MCP 2026-07-28: every request carries
C<io.modelcontextprotocol/*> keys in C<_meta>, every successful result carries
C<resultType> and an C<io.modelcontextprotocol/serverInfo> entry in C<_meta>,
and the C<initialize> handshake is rejected.

Set C<< legacy_compat => 1 >> only when constructing a server used with
L<Net::Async::MCP::Server::Transport::Stdio> for a MCP 2025-11-25 client. In
that opt-in path, the Stdio transport accepts the legacy lifecycle and emits
legacy result shapes; 2026 requests continue to use the stateless wire format.
L<Net::Async::MCP::Server::Transport::StreamableHTTP> remains 2026-only.

=cut

# The protocol revision this server advertises through the 2026-07-28
# server/discover response. legacy_compat has a separate Stdio-only wire path;
# it does not make 2025-11-25 a valid 2026 per-request metadata version.
our $PROTOCOL_VERSION = '2026-07-28';

# The 2026-07-28 metadata format does not negotiate down to its handshake-based
# predecessor. legacy_compat handles 2025-11-25 separately for Stdio.
sub supported_versions { [ '2026-07-28' ] }

=method supported_versions

Returns ArrayRef of protocol version strings this server accepts.

=cut

# --- Registry: the three registrable kinds -------------------------------
#
# tools, resources and prompts share one storage / lookup / wire-shape
# mechanism. Each kind names the field its entries are keyed by (used by
# _find) and the field lists that build its tools/list-style wire shape:
# `required` fields are copied verbatim, `optional` fields only when defined,
# and `defaults` supplies a value for a required field the caller omitted
# (prompts' arguments). register_* keeps its own validation — the required
# fields, error messages and normalisation genuinely differ per kind — but
# everything downstream of a stored entry is generic.
my %REGISTRY = (
  tools => {
    key  => 'name',
    wire => {
      required => [qw( name description inputSchema )],
      optional => [qw( title annotations outputSchema )],
    },
  },
  resources => {
    key  => 'uri',
    wire => {
      required => [qw( uri name )],
      optional => [qw( mimeType description title )],
    },
  },
  prompts => {
    key  => 'name',
    wire => {
      required => [qw( name )],
      optional => [qw( title description )],
      defaults => { arguments => sub { [] } },
    },
  },
);

sub _register {
  my ( $self, $kind, %def ) = @_;
  my $key = $def{ $REGISTRY{$kind}{key} };
  ( my $label = $kind ) =~ s/s\z//;
  croak ucfirst( $label ).q{ '}.$key.q{' is already registered}
    if $self->_find( $kind => $key );
  push @{ $self->{$kind} //= [] }, \%def;
  $self->notify_list_changed($kind);
  return;
}

sub _find {
  my ( $self, $kind, $key ) = @_;
  my $field = $REGISTRY{$kind}{key};
  for my $entry ( @{ $self->{$kind} // [] } ) {
    return $entry if $entry->{$field} eq $key;
  }
  return;
}

sub _wire_shape {
  my ( $self, $kind, $def ) = @_;
  my $spec = $REGISTRY{$kind}{wire};

  my %wire;
  $wire{$_} = $def->{$_} for @{ $spec->{required} };
  for my $field ( sort keys %{ $spec->{defaults} // {} } ) {
    $wire{$field} = defined $def->{$field}
      ? $def->{$field}
      : $spec->{defaults}{$field}->();
  }
  for my $field ( @{ $spec->{optional} } ) {
    $wire{$field} = $def->{$field} if defined $def->{$field};
  }
  return \%wire;
}

sub configure {
  my ( $self, %params ) = @_;
  if (exists $params{name}) {
    $self->{name} = delete $params{name};
  }
  if (exists $params{legacy_compat}) {
    $self->{legacy_compat} = delete $params{legacy_compat} ? 1 : 0;
  }
  if (exists $params{page_size}) {
    my $size = delete $params{page_size};
    croak 'page_size must be a positive integer or undef'
      if defined $size && $size !~ /\A[1-9][0-9]*\z/;
    $self->{page_size} = $size;
  }
  $self->SUPER::configure(%params);
}

sub name { shift->{name} // 'NetAsyncMCPServer' }

sub legacy_compat { shift->{legacy_compat} // 0 }

sub page_size { shift->{page_size} }

=method page_size

Returns the maximum number of entries C<tools/list>, C<resources/list> and
C<prompts/list> return per page, or C<undef> (the default) when each list is
returned as one complete page. When set, a response that has more entries
left carries an opaque C<nextCursor>, which the client passes back as
C<params.cursor> to get the following page. Pass C<< page_size => $n >> to the
constructor with a positive integer.

A C<cursor> that was not issued by this server is answered with C<-32602>.
Legacy C<tools/list> (see L</legacy_compat>) is never paginated.

=cut

=method legacy_compat

Returns true when the optional MCP 2025-11-25 compatibility path is enabled
for L<Net::Async::MCP::Server::Transport::Stdio>. It is false by default.

=cut

=method name

Returns the server name exposed via MCP protocol.

=cut

sub server_info {
  my ( $self ) = @_;
  return {
    name    => $self->name,
    version => $VERSION,
  };
}

=method server_info

Returns a hashref with C<name> and C<version> keys for the MCP protocol.

=cut

sub server_capabilities {
  my ( $self ) = @_;
  return $self->_build_capabilities;
}

=method server_capabilities

Returns the server capabilities hashref.

=cut

sub _build_capabilities {
  my ( $self ) = @_;
  my $changed = { listChanged => JSON::MaybeXS::true() };
  my %cap = ( tools => {%$changed}, logging => {} );
  $cap{resources} = {%$changed} if @{ $self->resources };
  $cap{prompts}   = {%$changed} if @{ $self->prompts };
  return \%cap;
}

async sub discover {
  my ( $self ) = @_;

  return {
    resultType        => 'complete',
    supportedVersions  => $self->supported_versions,
    capabilities       => $self->server_capabilities,
    ttlMs              => 300000,
    cacheScope         => 'public',
  };
}

=method discover

Handles the C<server/discover> RPC. Returns a Future that resolves to a
hashref of the server's supported protocol versions, capabilities, and
caching hints: C<< { resultType, supportedVersions, capabilities, ttlMs,
cacheScope } >>. The C<_meta.io.modelcontextprotocol/serverInfo> entry seen
on the wire is not part of this result — it is added afterwards, by
C<_jsonrpc_response>, to every response C<handle> sends.

=cut

sub tools {
  my ( $self ) = @_;
  return $self->{tools} // [];
}

=method tools

Returns ArrayRef of registered tool definitions (internal storage shape).

=cut

sub find_tool {
  my ( $self, $name ) = @_;
  return unless defined $name;
  return $self->_find( tools => $name );
}

=method find_tool

    my $tool = $server->find_tool('echo');

Returns the registered tool definition hashref (internal storage shape,
C<inputSchema> normalised) for C<$name>, or an empty list when no such tool
is registered. Transports use this to consult a tool's schema; the returned
hash is the registry's own, so treat it as read-only.

=cut

sub register_tool {
  my ( $self, %tool ) = @_;
  croak q{register_tool requires 'name'} unless defined $tool{name};

  # Normalise input_schema -> inputSchema. Accept the legacy snake_case key
  # so existing callers don't have to change in lockstep.
  if ( exists $tool{input_schema} && !exists $tool{inputSchema} ) {
    $tool{inputSchema} = delete $tool{input_schema};
  }

  croak "Tool '$tool{name}' requires 'inputSchema'"
    unless exists $tool{inputSchema};

  return $self->_register( tools => %tool );
}

=method register_tool(%tool)

Registers a tool. Expects C<name>, C<description>, C<inputSchema> (or the
legacy C<input_schema> alias), and an optional C<code> reference. The
C<inputSchema> MUST be present — tools without a parameter schema are
non-conformant under MCP 2026-07-28.

Croaks when a tool with the same C<name> is already registered; a registered
tool is never silently replaced or duplicated.

The optional C<title>, C<annotations> and C<outputSchema> keys are passed
through unchanged into the tool's wire shape in C<tools/list> (see
L</list_tools>) when defined, and omitted from it otherwise.

=cut

async sub list_tools {
  my ( $self ) = @_;
  return [ map { $self->_wire_shape( tools => $_ ) } @{ $self->{tools} // [] } ];
}

=method list_tools

Returns a Future that resolves to an ArrayRef of tool definitions in wire
shape (C<name>, C<description>, C<inputSchema>, not C<input_schema>, and the
optional C<title>, C<annotations>, C<outputSchema> when set).

=cut

async sub call_tool {
  my ( $self, $name, $arguments, $context ) = @_;

  my $tool = $self->_find( tools => $name );
  croak "No tool registered: $name" unless $tool;

  if (my $code = $tool->{code}) {
    my $result = $code->( $arguments, $context // $self->_tool_context );
    $result = await $result if Scalar::Util::blessed($result) && $result->isa('Future');
    return $result;
  }

  croak "Tool '$name' has no implementation";
}

=method call_tool($name, $arguments, $context)

Called when a client invokes a tool. Subclasses should override to provide
tool implementations. C<$context> is optional; it is handed to a registered
tool's C<code> reference as its second argument, after C<$arguments>, and is
a hashref whose C<progress> entry is a code reference
C<< ->( $progress, $total, $message ) >> that reports progress for this call
(see L</emit_notification>); C<$total> and C<$message> are optional. It returns a
L<Future>, and is a no-op that resolves immediately when the client did not
send a C<progressToken>, so a tool may call it unconditionally. Returns a Future that resolves to the tool's return
value, which the dispatch layer then wraps:

=over

=item *

A plain value (string, number, hashref, arrayref) is wrapped in a single
C<text> content block inside a C<complete> result.

=item *

A hashref that already carries a C<resultType> (e.g. C<input_required> for
MRTR) is passed through unchanged.

=item *

A hashref carrying a C<content> arrayref and/or a C<structuredContent> key
(but no C<resultType>) is passed through verbatim, wrapped in a C<complete>
result. This lets a tool return its own content blocks — images, multiple
text blocks, structured output — instead of the single stringified text
block the default wrapping produces. When only C<structuredContent> is
given, a C<content> array with one text block holding its JSON encoding is
added.

=back

To signal that a tool needs more input from the client, return a hashref
shaped like:

    {
        resultType    => 'input_required',
        inputRequests => { ... },
        requestState  => '...',   # optional, opaque
    }

=cut

sub resources {
  my ( $self ) = @_;
  return $self->{resources} // [];
}

=method resources

Returns ArrayRef of registered resource definitions (internal storage shape).

=cut

sub register_resource {
  my ( $self, %resource ) = @_;
  croak q{register_resource requires 'uri'}  unless defined $resource{uri};
  croak q{register_resource requires 'name'} unless defined $resource{name};

  return $self->_register( resources => %resource );
}

=method register_resource(%resource)

Registers a resource. Expects C<uri> and C<name>, an optional C<mimeType>,
C<description> and C<title>, and a C<code> reference invoked with the resource
URI when the resource is read.

Croaks when a resource with the same C<uri> is already registered.

=cut

async sub list_resources {
  my ( $self ) = @_;
  return [ map { $self->_wire_shape( resources => $_ ) } @{ $self->{resources} // [] } ];
}

=method list_resources

Returns a Future that resolves to an ArrayRef of resource definitions in wire
shape (C<uri>, C<name>, and the optional C<mimeType>, C<description>,
C<title>).

=cut

async sub read_resource {
  my ( $self, $uri ) = @_;

  my $resource = $self->_find( resources => $uri );
  croak "No resource registered: $uri" unless $resource;

  my $result;
  if ( my $code = $resource->{code} ) {
    $result = $code->($uri);
    $result = await $result if Scalar::Util::blessed($result) && $result->isa('Future');
  }
  else {
    croak "Resource '$uri' has no implementation";
  }

  # A resource may return its own result hashref already carrying contents
  # blocks (multiple parts, a blob, an explicit mimeType). Pass it through.
  return $result
    if ref $result eq 'HASH' && ref $result->{contents} eq 'ARRAY';

  # Default wrapping: a bare scalar becomes a single text content block,
  # tagged with the resource's declared mimeType when it has one.
  my $content = {
    uri  => $uri,
    text => ( defined $result ? "$result" : '' ),
  };
  $content->{mimeType} = $resource->{mimeType} if defined $resource->{mimeType};

  return { contents => [ $content ] };
}

=method read_resource($uri)

Called when a client reads a resource. Looks up C<$uri> in the resource
registry and invokes its C<code> reference with the URI. Returns a Future that
resolves to a hashref of the shape C<< { contents => [ { uri, mimeType?, text } ] } >>.

A resource whose C<code> returns a hashref already carrying a C<contents>
arrayref is passed through verbatim; any other return value is stringified
into a single text content block tagged with the resource's C<mimeType>.

=cut

sub prompts {
  my ( $self ) = @_;
  return $self->{prompts} // [];
}

=method prompts

Returns ArrayRef of registered prompt definitions (internal storage shape).

=cut

sub register_prompt {
  my ( $self, %prompt ) = @_;
  croak q{register_prompt requires 'name'} unless defined $prompt{name};

  return $self->_register( prompts => %prompt );
}

=method register_prompt(%prompt)

Registers a prompt. Expects C<name>, optional C<title>, C<description> and an
C<arguments> ArrayRef, and a C<code> reference invoked with the request
arguments when the prompt is fetched. An C<arguments> entry with a true
C<required> must be present in C<prompts/get> or the request fails with
C<-32602> before C<code> runs.

Croaks when a prompt with the same C<name> is already registered.

=cut

async sub list_prompts {
  my ( $self ) = @_;
  return [ map { $self->_wire_shape( prompts => $_ ) } @{ $self->{prompts} // [] } ];
}

=method list_prompts

Returns a Future that resolves to an ArrayRef of prompt definitions in wire
shape (C<name>, C<arguments>, and the optional C<title>, C<description>).

=cut

async sub get_prompt {
  my ( $self, $name, $arguments ) = @_;

  my $prompt = $self->_find( prompts => $name );
  croak "No prompt registered: $name" unless $prompt;

  my $result;
  if ( my $code = $prompt->{code} ) {
    $result = $code->($arguments);
    $result = await $result if Scalar::Util::blessed($result) && $result->isa('Future');
  }
  else {
    croak "Prompt '$name' has no implementation";
  }

  # A prompt may return its own result hashref already carrying a messages
  # arrayref (and an optional description). Pass it through verbatim.
  return $result
    if ref $result eq 'HASH' && ref $result->{messages} eq 'ARRAY';

  # Default wrapping: a bare scalar becomes a single user text message.
  return {
    messages => [
      {
        role    => 'user',
        content => {
          type => 'text',
          text => ( defined $result ? "$result" : '' ),
        },
      },
    ],
  };
}

=method get_prompt($name, $arguments)

Called when a client fetches a prompt. Looks up C<$name> in the prompt
registry and invokes its C<code> reference with C<$arguments>. Returns a
Future that resolves to a hashref of the shape
C<< { description?, messages => [ { role, content => { type => 'text', text } } ] } >>.

A prompt whose C<code> returns a hashref already carrying a C<messages>
arrayref is passed through verbatim; any other return value is stringified
into a single C<user> text message.

=cut

# --- Notifications: sink registry and fan-out ----------------------------

my @LOG_LEVELS = qw( debug info notice warning error critical alert emergency );
my %LOG_RANK   = map { $LOG_LEVELS[$_] => $_ } 0 .. $#LOG_LEVELS;

sub add_notification_sink {
  my ( $self, $sink, %opts ) = @_;
  croak 'add_notification_sink requires a code reference'
    unless ref $sink eq 'CODE';

  my $methods = $opts{methods};
  croak q{add_notification_sink: 'methods' must be an array reference}
    if defined $methods && ref $methods ne 'ARRAY';

  my $token = ++$self->{sink_seq};
  $self->{sinks}{$token} = {
    code    => $sink,
    methods => $methods ? { map { $_ => 1 } @{$methods} } : undef,
  };
  return $token;
}

=method add_notification_sink($sink, %opts)

Registers C<$sink> to receive server-initiated notifications and returns a
token for L</remove_notification_sink>. A transport that holds a stream open
to the client registers one for as long as the stream lives. C<$sink> is
called with the complete JSON-RPC notification hashref (C<jsonrpc>,
C<method>, C<params>) and may return a L<Future> that resolves once the
message has been written. A sink that dies, or whose Future fails, is removed
from the registry: its stream is gone.

With C<< methods => [ ... ] >> the sink only sees notifications whose method
is in the list; without it, it sees all of them.

=cut

sub remove_notification_sink {
  my ( $self, $token ) = @_;
  return defined $token && delete $self->{sinks}{$token} ? 1 : 0;
}

=method remove_notification_sink($token)

Unregisters the sink C<$token> was returned for. Returns true if it was
still registered.

=cut

sub notification_sink_count {
  my ( $self ) = @_;
  return scalar keys %{ $self->{sinks} // {} };
}

=method notification_sink_count

The number of sinks currently registered.

=cut

sub emit_notification {
  my ( $self, $method, $params ) = @_;
  croak 'emit_notification requires a method' unless defined $method && length $method;

  my %message = ( jsonrpc => '2.0', method => $method );
  $message{params} = $params if defined $params;

  my @pending;
  my $sinks = $self->{sinks} // {};
  for my $token ( sort { $a <=> $b } keys %{$sinks} ) {
    my $entry = $sinks->{$token} or next;
    next if $entry->{methods} && !$entry->{methods}{$method};

    my $f = eval { $entry->{code}->( {%message} ) };
    $f = Future->fail($@) if $@;
    $f = Future->done unless ref $f && $f->isa('Future');
    push @pending, $f->else( sub {
      delete $self->{sinks}{$token};
      return Future->done;
    } )->then( sub { Future->done(1) } );
  }

  # Not returned directly: a caller that drops the Future (void context) must
  # not make ->then warn.
  my $all = Future->wait_all(@pending)->then( sub { Future->done( scalar @pending ) } );
  return $all;
}

=method emit_notification($method, $params)

Sends the notification C<$method> with the optional C<$params> hashref to
every registered sink that wants it, and returns a L<Future> that resolves to
the number of sinks it was offered to once all of them have finished. It never
fails because a sink did: such a sink is dropped. With no sink registered it
resolves to C<0> and nothing else happens.

=cut

sub notify_list_changed {
  my ( $self, $kind ) = @_;
  return Future->done(0) unless exists $REGISTRY{$kind};
  return Future->done(0) unless $self->notification_sink_count;
  my $f = $self->emit_notification("notifications/$kind/list_changed");
  $f->retain;
  return $f;
}

=method notify_list_changed($kind)

Tells the clients that the C<tools>, C<resources> or C<prompts> list changed,
with C<notifications/tools/list_changed> and its siblings. The C<register_*>
methods call it themselves, so a tool registered while a client is listening
reaches that client. Returns a L<Future> like L</emit_notification>.

=cut

sub log_level {
  my ( $self ) = @_;
  return $self->{log_level} // 'info';
}

=method log_level

The lowest severity L</log> delivers, C<info> until a client changes it with
C<logging/setLevel>. The level belongs to the server, not to a client: the
2026-07-28 protocol keeps no per-client state between requests.

=cut

sub log {
  my ( $self, $level, $data, $logger ) = @_;
  croak "log: unknown level '".( $level // 'undef' )."'"
    unless defined $level && exists $LOG_RANK{$level};

  return Future->done(0) if $LOG_RANK{$level} < $LOG_RANK{ $self->log_level };

  my %params = ( level => $level, data => $data );
  $params{logger} = $logger if defined $logger;
  return $self->emit_notification( 'notifications/message', \%params );
}

=method log($level, $data, $logger)

Sends a C<notifications/message> log record to the listening clients, if
C<$level> (one of C<debug>, C<info>, C<notice>, C<warning>, C<error>,
C<critical>, C<alert>, C<emergency>) is at or above L</log_level>.
C<$data> is any JSON-serialisable value, C<$logger> an optional name.
Returns a L<Future> like L</emit_notification>.

=cut

# subscriptions/listen opens a long-lived stream, which only a transport that
# has one can do: it supplies $context->{listen}. Everywhere else the method
# stays unknown, as it was before there was a push channel (Stdio sends its
# notifications without being asked).
async sub _handle_subscriptions_listen {
  my ( $self, $params, $id, $context ) = @_;

  my $listen = ref $context eq 'HASH' ? $context->{listen} : undef;
  return _jsonrpc_error( -32601, "Method 'subscriptions/listen' not found", $id )
    unless $listen;

  my $wanted = $params->{notifications};
  return _jsonrpc_error( -32602, 'Invalid params: notifications must be an object', $id )
    if defined $wanted && ref $wanted ne 'HASH';

  # Keys name the notification without its "notifications/" prefix
  # ("tools/list_changed"); none at all means everything.
  $listen->( [ map { "notifications/$_" } sort keys %{ $wanted // {} } ] );
  return undef;
}

async sub _handle_logging_set_level {
  my ( $self, $params, $id ) = @_;

  my $level = $params->{level};
  unless ( defined $level && !ref $level && exists $LOG_RANK{$level} ) {
    return _jsonrpc_error( -32602, 'Invalid params: invalid log level', $id );
  }

  $self->{log_level} = $level;
  return $self->_jsonrpc_response( {}, $id );
}

# The context handed to a tool: progress() reports on this tools/call. The
# progressToken comes from the request's _meta; without one it does nothing.
# Notifications go to the stream of the request itself when the transport
# supplied one ($context->{notify}), else to every sink.
sub _tool_context {
  my ( $self, $params, $request_context ) = @_;

  my $token = ref $params eq 'HASH' && ref $params->{_meta} eq 'HASH'
    ? $params->{_meta}{progressToken}
    : undef;
  return { progress => sub { Future->done(0) } } unless defined $token;

  my $notify = ref $request_context eq 'HASH' ? $request_context->{notify} : undef;
  return {
    progressToken => $token,
    progress      => sub {
      my ( $progress, $total, $message ) = @_;
      my %p = ( progressToken => $token, progress => $progress );
      $p{total}   = $total   if defined $total;
      $p{message} = $message if defined $message;
      return $notify
        ? $notify->( { jsonrpc => '2.0', method => 'notifications/progress', params => \%p } )
        : $self->emit_notification( 'notifications/progress', \%p );
    },
  };
}

# JSON-RPC method -> handler, tried once per-request _meta has validated. Each
# entry is invoked as $self->$handler( $request, $id ) and pulls whatever it
# needs (params, id) from those; this map replaces the former if/elsif ladder.
my %DISPATCH = (
  'server/discover' => sub { $_[0]->_handle_discover( $_[2] ) },
  'tools/list'      => sub { $_[0]->_handle_tools_list( $_[1]->{params} // {}, $_[2] ) },
  'tools/call'      => sub { $_[0]->_handle_tools_call( $_[1]->{params} // {}, $_[2], $_[3] ) },
  'resources/list'  => sub { $_[0]->_handle_resources_list( $_[1]->{params} // {}, $_[2] ) },
  'resources/read'  => sub { $_[0]->_handle_resources_read( $_[1]->{params} // {}, $_[2] ) },
  'prompts/list'    => sub { $_[0]->_handle_prompts_list( $_[1]->{params} // {}, $_[2] ) },
  'prompts/get'     => sub { $_[0]->_handle_prompts_get( $_[1]->{params} // {}, $_[2] ) },
  'subscriptions/listen' => sub { $_[0]->_handle_subscriptions_listen( $_[1]->{params} // {}, $_[2], $_[3] ) },
  'logging/setLevel' => sub { $_[0]->_handle_logging_set_level( $_[1]->{params} // {}, $_[2] ) },
);

sub handle {
  my ( $self, $request, $context ) = @_;
  return $self->handle_f( $request, $context )->get;
}

async sub handle_f {
  my ( $self, $request, $context ) = @_;

  return _jsonrpc_error( -32700, 'Invalid JSON-RPC request' )
    unless ref $request eq 'HASH';

  my $method = $request->{method};
  my $id     = $request->{id};

  return _jsonrpc_error( -32600, 'Missing JSON-RPC method', $id )
    unless defined $method;

  return await $self->_handle_legacy_request($request)
    if $self->_is_legacy_stdio_request( $request, $context );

  if ( defined $id ) {
    # Per-request _meta validation. Required on every RPC; missing or
    # wrong-version fields short-circuit the dispatch with a JSON-RPC
    # error so the client can fall back / renegotiate.
    if ( my $err = $self->_validate_request_meta($request) ) {
      return $err;
    }

    if ( my $handler = $DISPATCH{$method} ) {
      return await $self->$handler( $request, $id, $context );
    }

    return _jsonrpc_error( -32601, "Method '$method' not found", $id );
  }

  # Notifications (no id): no-op. The stdio transport skips writing
  # anything when the response is undef.
  return undef;
}

sub _is_legacy_stdio_request {
  my ( $self, $request, $context ) = @_;

  return unless $self->legacy_compat;
  return unless ref $context eq 'HASH' && ( $context->{transport} // '' ) eq 'stdio';
  return unless $request->{method} =~ /\A(?:initialize|ping|notifications\/initialized|tools\/list|tools\/call)\z/;
  return unless !defined $self->_request_protocol_version($request);

  return 1;
}

sub _request_protocol_version {
  my ( $self, $request ) = @_;

  my $params = $request->{params};
  return undef unless ref $params eq 'HASH';

  my $meta = $params->{_meta};
  return undef unless ref $meta eq 'HASH';

  return $meta->{'io.modelcontextprotocol/protocolVersion'};
}

async sub _handle_legacy_request {
  my ( $self, $request ) = @_;

  my $method = $request->{method};
  my $id     = $request->{id};

  return undef if $method eq 'notifications/initialized' && !defined $id;
  return undef unless defined $id;

  if ( $method eq 'initialize' ) {
    my $params = ref $request->{params} eq 'HASH' ? $request->{params} : {};
    my $version = $params->{protocolVersion};
    unless ( defined $version && $version eq '2025-11-25' ) {
      return _jsonrpc_error(
        -32602,
        'Invalid params: unsupported protocolVersion',
        $id,
      );
    }

    return $self->_legacy_jsonrpc_response(
      {
        protocolVersion => '2025-11-25',
        capabilities    => { tools => {} },
        serverInfo      => $self->server_info,
      },
      $id,
    );
  }

  return $self->_legacy_jsonrpc_response( {}, $id ) if $method eq 'ping';
  return await $self->_handle_legacy_tools_list($id) if $method eq 'tools/list';
  if ( $method eq 'tools/call' ) {
    my $params = $request->{params} // {};
    return _jsonrpc_error( -32602, 'Invalid params: params must be an object', $id )
      unless ref $params eq 'HASH';
    return await $self->_handle_legacy_tools_call( $params, $id );
  }

  return _jsonrpc_error( -32601, "Method '$method' not found", $id );
}

async sub _handle_legacy_tools_list {
  my ( $self, $id ) = @_;

  return $self->_legacy_jsonrpc_response(
    { tools => (await $self->list_tools) },
    $id,
  );
}

async sub _handle_legacy_tools_call {
  my ( $self, $params, $id ) = @_;

  my $name = $params->{name}      // '';
  my $args = $params->{arguments} // {};

  return _jsonrpc_error( -32602, 'Invalid params: arguments must be an object', $id )
    unless ref $args eq 'HASH';

  my $tool = $self->_find( tools => $name );
  unless ($tool) {
    return _jsonrpc_error(
      -32602,
      "Invalid params: unknown tool '$name'",
      $id,
    );
  }

  my $result;
  eval {
    $result = await $self->call_tool( $name, $args );
    1;
  } or do {
    return $self->_legacy_jsonrpc_response(
      {
        content => [ { type => 'text', text => "$@" } ],
        isError => JSON::MaybeXS::true(),
      },
      $id,
    );
  };

  return $self->_legacy_jsonrpc_response(
    $self->_legacy_tool_result($result),
    $id,
  );
}

sub _legacy_tool_result {
  my ( $self, $result ) = @_;

  if ( ref $result eq 'HASH'
    && ( ref $result->{content} eq 'ARRAY'
      || exists $result->{structuredContent} ) ) {
    my %legacy = (
      isError => $self->_legacy_boolean($result->{isError}),
    );
    $legacy{content} = $result->{content}
      if ref $result->{content} eq 'ARRAY';
    $legacy{structuredContent} = $result->{structuredContent}
      if exists $result->{structuredContent};
    $legacy{content} = [
      {
        type => 'text',
        text => encode_json($result->{structuredContent}),
      },
    ] unless exists $legacy{content};
    return \%legacy;
  }

  if ( ref $result eq 'HASH' && defined $result->{resultType} ) {
    return {
      content => [
        {
          type => 'text',
          text => 'Tool result type '.$result->{resultType}
            .' is unavailable with protocol version 2025-11-25',
        },
      ],
      isError => JSON::MaybeXS::true(),
    };
  }

  my $text = ref $result
    ? encode_json($result)
    : ( defined $result ? "$result" : '' );

  return {
    content => [ { type => 'text', text => $text } ],
    isError => JSON::MaybeXS::false(),
  };
}

sub _legacy_boolean {
  my ( $self, $value ) = @_;
  return $value ? JSON::MaybeXS::true() : JSON::MaybeXS::false();
}

sub _legacy_jsonrpc_response {
  my ( $self, $result, $id ) = @_;
  return { jsonrpc => '2.0', id => $id, result => $result };
}

=method handle($request, $context)

The JSON-RPC dispatch entry point. C<$request> is a single decoded
JSON-RPC request or notification hashref (C<jsonrpc>, C<method>, and
optionally C<id> and C<params>); transports are responsible for decoding
wire JSON before calling this and for encoding whatever it returns.

C<handle> is the synchronous convenience over L</handle_f>: it calls
C<-E<gt>get> on the C<Future> C<handle_f> returns and hands back a plain
result. It suits callers that do not run an event loop, and tests; a
C<call_tool> that waits on I/O would block it. Transports use L</handle_f>.

If C<$request> has a defined C<id> key (C<0> or C<''> counts; only an
absent key or a JSON C<null> id does not), C<handle> returns a JSON-RPC
response or error hashref, e.g.:

    { jsonrpc => '2.0', id => 1, result => { ... } }
    { jsonrpc => '2.0', id => 1, error  => { code => -32602, message => '...' } }

Otherwise C<$request> is treated as a notification: C<_meta> is never
validated, nothing is dispatched, and C<handle> returns C<undef>
(transports skip writing a response when they get C<undef> back).

Malformed input is rejected before any of that, regardless of C<id>: a
C<$request> that is not a hashref returns C<-32700>; a hashref with no
defined C<method> returns C<-32600>.

For every request that does carry an C<id>, the per-request C<_meta>
contract, read from C<params._meta>, is validated before dispatch:

=over

=item *

C<io.modelcontextprotocol/protocolVersion> must be a defined, non-empty
string listed in C<supported_versions>. Missing or empty returns
C<-32602>; present but unsupported returns C<-32022>, with the server's
supported list and the requested version in the error's C<data>.

=item *

C<io.modelcontextprotocol/clientCapabilities> must be present as a key in
C<_meta> — its value is not otherwise inspected, so C<undef>/JSON C<null>
satisfies the check. Missing the key returns C<-32602>.

=back

Once C<_meta> validates, C<method> is mapped as:

=over

=item *

C<server/discover> dispatches to C<discover>.

=item *

C<tools/list> dispatches to C<list_tools>.

=item *

C<tools/call> looks up C<params.name> in the tool registry (unregistered
name: C<-32602>) and dispatches to C<call_tool> with C<params.arguments>;
see the C<call_tool> method above for how a tool's return value or
exception becomes the result.

=item *

C<resources/list> dispatches to C<list_resources>.

=item *

C<resources/read> looks up C<params.uri> in the resource registry
(unregistered URI: C<-32602>) and dispatches to C<read_resource> with the
URI.

=item *

C<prompts/list> dispatches to C<list_prompts>.

=item *

C<prompts/get> looks up C<params.name> in the prompt registry (unregistered
name: C<-32602>), checks that every registered argument with a true
C<required> is defined in C<params.arguments> (missing: C<-32602>), and
dispatches to C<get_prompt> with C<params.name> and C<params.arguments>.

=item *

Anything else returns C<-32601>, including legacy handshake method names
such as C<initialize>, C<ping> or C<notifications/initialized> by default.
When C<legacy_compat> is true and the request arrived from the Stdio transport
without 2026 request metadata, the 2025-11-25 forms of those methods plus
C<tools/list> and C<tools/call> use the legacy response shapes instead. The
same names sent as notifications (no C<id>) otherwise never reach this dispatch
— they fall into the no-op/C<undef> path above like any other notification.

=back

The full set of JSON-RPC error codes C<handle> itself can produce:
C<-32700>, C<-32600>, C<-32601>, C<-32602>, C<-32022>. C<-32020>
(header/body mismatch) is raised by
L<Net::Async::MCP::Server::Transport::StreamableHTTP>, not by C<handle>.

=cut

=method handle_f($request, $context)

The core of the dispatch: everything L</handle> says about C<$request> and
what it returns holds here, except that the result is a L<Future> resolving to
the response hashref (or C<undef> for a notification). It dispatches to the
C<async sub> methods C<discover>, C<list_tools>, C<call_tool>,
C<list_resources>, C<read_resource>, C<list_prompts> and C<get_prompt> and
waits for them without blocking the loop. An exception those methods let
escape (other than a tool, resource or prompt failing, which become results
as described above) fails the Future.

C<$context> is an optional hashref set by the transport. C<transport> names
it (C<stdio> enables the C<legacy_compat> path). C<notify>, a code reference
taking a complete notification hashref and returning a L<Future>, is where a
request's own notifications go (the C<notifications/progress> of its
C<tools/call>); without it they go to every sink, see L</emit_notification>.

=cut

sub _validate_request_meta {
  my ( $self, $request ) = @_;
  my $id     = $request->{id};
  my $params = $request->{params};
  my $meta   = ( ref $params eq 'HASH' && ref $params->{_meta} eq 'HASH' )
    ? $params->{_meta}
    : {};

  my $version = $meta->{'io.modelcontextprotocol/protocolVersion'};
  unless ( defined $version && length $version ) {
    return _jsonrpc_error(
      -32602,
      'Invalid params: missing io.modelcontextprotocol/protocolVersion',
      $id,
    );
  }

  my $supported = $self->supported_versions;
  unless ( grep { $_ eq $version } @{$supported} ) {
    return _jsonrpc_error(
      -32022,
      'Unsupported protocol version',
      $id,
      {
        supported => $supported,
        requested => $version,
      },
    );
  }

  unless ( exists $meta->{'io.modelcontextprotocol/clientCapabilities'} ) {
    return _jsonrpc_error(
      -32602,
      'Invalid params: missing io.modelcontextprotocol/clientCapabilities',
      $id,
    );
  }

  return undef;
}

async sub _handle_discover {
  my ( $self, $id ) = @_;

  my $result = await $self->discover;
  return $self->_jsonrpc_response( $result, $id );
}

# Slice a complete list into the page params.cursor asks for. Returns the
# page and the extra result keys (nextCursor when more is left), or undef and
# a JSON-RPC error when the cursor is not one this server issued. The cursor
# is opaque to clients: base64 of the offset of the first entry of the page.
sub _paginate {
  my ( $self, $items, $params, $id ) = @_;

  my $size = $self->page_size;
  return ( $items, {} ) unless defined $size;

  my $offset = 0;
  if ( exists $params->{cursor} ) {
    my $cursor = $params->{cursor};
    my $bad    = _jsonrpc_error( -32602, 'Invalid params: invalid cursor', $id );
    return ( undef, $bad ) if !defined $cursor || ref $cursor;
    my $plain = $cursor =~ m{\A[A-Za-z0-9+/]+={0,2}\z} ? decode_base64($cursor) : '';
    return ( undef, $bad ) unless $plain =~ /\Aoffset:([0-9]+)\z/;
    $offset = $1;
    return ( undef, $bad ) if $offset > @{$items};
  }

  my $end  = $offset + $size;
  my $last = ( $end < @{$items} ? $end : scalar @{$items} ) - 1;
  my %extra;
  $extra{nextCursor} = encode_base64( "offset:$end", '' ) if $end < @{$items};
  return ( [ @{$items}[ $offset .. $last ] ], \%extra );
}

async sub _handle_tools_list {
  my ( $self, $params, $id ) = @_;

  my ( $tools, $extra ) = $self->_paginate( (await $self->list_tools), $params, $id );
  return $extra unless $tools;
  return $self->_jsonrpc_response(
    {
      resultType => 'complete',
      tools      => $tools,
      ttlMs      => 300000,
      cacheScope => 'public',
      %{$extra},
    },
    $id,
  );
}

async sub _handle_tools_call {
  my ( $self, $params, $id, $context ) = @_;

  my $name = $params->{name}      // '';
  my $args = $params->{arguments} // {};

  # Protocol error: unknown tool. The spec routes this through JSON-RPC,
  # not through an isError result, so the model can't retry it as if it
  # were a recoverable tool failure.
  my $tool = $self->_find( tools => $name );
  unless ($tool) {
    return _jsonrpc_error(
      -32602,
      "Invalid params: unknown tool '$name'",
      $id,
    );
  }

  my $result;
  eval {
    $result = await $self->call_tool(
      $name, $args, $self->_tool_context( $params, $context ),
    );
    1;
  } or do {
    # Tool execution error — wrap in isError content block so the model
    # can see and self-correct, instead of a JSON-RPC error that would
    # abort the call.
    return $self->_jsonrpc_response(
      {
        resultType => 'complete',
        content    => [ { type => 'text', text => "$@" } ],
        isError    => JSON::MaybeXS::true(),
      },
      $id,
    );
  };

  # MRTR: a tool may return its own result hashref (e.g. resultType =>
  # 'input_required'). Passed through; only isError is normalized, on a
  # shallow copy so the tool's own hash is not mutated.
  if ( ref $result eq 'HASH' && defined $result->{resultType} ) {
    $result = { %$result, isError => $self->_legacy_boolean( $result->{isError} ) }
      if exists $result->{isError};
    return $self->_jsonrpc_response( $result, $id );
  }

  # Rich content: a tool may return a hashref carrying its own content
  # blocks and/or structuredContent (without a resultType). Pass it
  # through verbatim; _jsonrpc_response fills in resultType => 'complete'.
  if ( ref $result eq 'HASH'
    && ( ref $result->{content} eq 'ARRAY'
      || exists $result->{structuredContent} ) ) {
    # isError is a schema boolean; tool authors may return Perl truthiness.
    $result = { %$result, isError => $self->_legacy_boolean( $result->{isError} ) }
      if exists $result->{isError};
    # CallToolResult requires content; for backwards compatibility the
    # spec says structured content SHOULD also be serialized as text.
    $result = {
      %$result,
      content => [ { type => 'text', text => encode_json( $result->{structuredContent} ) } ],
    } if exists $result->{structuredContent} && ref $result->{content} ne 'ARRAY';
    return $self->_jsonrpc_response( $result, $id );
  }

  # Default wrapping: a tool's plain return value becomes a text content
  # block inside a complete result. Scalars are stringified; refs are
  # JSON-encoded so the tool author can return any JSON-shaped data
  # without having to think about it.
  my $text = ref $result
    ? encode_json($result)
    : ( defined $result ? "$result" : '' );

  return $self->_jsonrpc_response(
    {
      resultType => 'complete',
      content    => [ { type => 'text', text => $text } ],
    },
    $id,
  );
}

async sub _handle_resources_list {
  my ( $self, $params, $id ) = @_;

  my ( $resources, $extra ) = $self->_paginate( (await $self->list_resources), $params, $id );
  return $extra unless $resources;
  return $self->_jsonrpc_response(
    {
      resultType => 'complete',
      resources  => $resources,
      %{$extra},
    },
    $id,
  );
}

async sub _handle_resources_read {
  my ( $self, $params, $id ) = @_;

  my $uri = $params->{uri} // '';

  # Protocol error: unknown resource. Routed through JSON-RPC -32602.
  my $resource = $self->_find( resources => $uri );
  unless ($resource) {
    return _jsonrpc_error(
      -32602,
      "Invalid params: unknown resource '$uri'",
      $id,
    );
  }

  my $result;
  eval {
    $result = await $self->read_resource($uri);
    1;
  } or do {
    # Resource execution error — a dying code ref or a registered-but-
    # codeless resource. Unlike tools/call, which routes tool execution
    # failures into isError content blocks so the model can self-correct,
    # a resource read failure is a server-side internal error: -32603.
    return _jsonrpc_error( -32603, "Internal error: $@", $id );
  };

  return $self->_jsonrpc_response( $result, $id );
}

async sub _handle_prompts_list {
  my ( $self, $params, $id ) = @_;

  my ( $prompts, $extra ) = $self->_paginate( (await $self->list_prompts), $params, $id );
  return $extra unless $prompts;
  return $self->_jsonrpc_response(
    {
      resultType => 'complete',
      prompts    => $prompts,
      %{$extra},
    },
    $id,
  );
}

async sub _handle_prompts_get {
  my ( $self, $params, $id ) = @_;

  my $name = $params->{name}      // '';
  my $args = $params->{arguments} // {};

  # Protocol error: unknown prompt. Routed through JSON-RPC -32602.
  my $prompt = $self->_find( prompts => $name );
  unless ($prompt) {
    return _jsonrpc_error(
      -32602,
      "Invalid params: unknown prompt '$name'",
      $id,
    );
  }

  # Protocol error: a registered argument marked required must be present.
  for my $def ( @{ $prompt->{arguments} // [] } ) {
    next unless ref $def eq 'HASH' && $def->{required};
    my $arg = $def->{name};
    next unless defined $arg;
    next if ref $args eq 'HASH' && defined $args->{$arg};
    return _jsonrpc_error(
      -32602,
      "Invalid params: missing required argument '$arg'",
      $id,
    );
  }

  my $result;
  eval {
    $result = await $self->get_prompt($name, $args);
    1;
  } or do {
    # Prompt execution error — a dying code ref or a registered-but-
    # codeless prompt. Unlike tools/call, which routes tool execution
    # failures into isError content blocks so the model can self-correct,
    # a prompt fetch failure is a server-side internal error: -32603.
    return _jsonrpc_error( -32603, "Internal error: $@", $id );
  };

  return $self->_jsonrpc_response( $result, $id );
}

sub _jsonrpc_error {
  my ( $code, $message, $id, $data ) = @_;
  my $err = { code => $code, message => $message };
  $err->{data} = $data if defined $data;
  return {
    jsonrpc => '2.0',
    id      => $id,
    error   => $err,
  };
}

sub _jsonrpc_response {
  my ( $self, $result, $id ) = @_;
  if ( ref $result eq 'HASH' ) {
    $result->{resultType} //= 'complete';
    $result->{_meta}{'io.modelcontextprotocol/serverInfo'} = $self->server_info;
  }
  return { jsonrpc => '2.0', id => $id, result => $result };
}

1;

=head1 SEE ALSO

L<Net::Async::MCP::Server::Transport::Stdio>,
L<Net::Async::MCP::Server::Transport::StreamableHTTP>, L<IO::Async::Notifier>,
L<Future::AsyncAwait>.

=cut
