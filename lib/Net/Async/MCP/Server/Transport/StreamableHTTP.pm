package Net::Async::MCP::Server::Transport::StreamableHTTP;
# ABSTRACT: Streamable HTTP transport for Net::Async::MCP::Server

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use JSON::MaybeXS qw( encode_json decode_json );
use MIME::Base64 qw( decode_base64 );
use Encode      qw( decode FB_DEFAULT );
use Scalar::Util qw( blessed );

our $VERSION = '0.002';

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::MCP::Server;
    use Net::Async::MCP::Server::Transport::StreamableHTTP;

    my $loop = IO::Async::Loop->new;

    my $server = Net::Async::MCP::Server->new(name => 'my-server');
    $loop->add($server);

    my $http = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server       => $server,
        host         => '127.0.0.1',
        port         => 8080,
        path         => '/mcp',
        origin_allow => [ 'https://app.example.com' ],
    );
    $loop->add($http);
    $http->listen;

=head1 DESCRIPTION

L<Net::Async::MCP::Server::Transport::StreamableHTTP> is the Streamable HTTP
transport for MCP 2026-07-28. It exposes a single HTTP POST endpoint per the
spec, validates the L<request metadata
headers|https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#request-metadata>
against the JSON-RPC body, and answers each request with either an
C<application/json> response or a C<text/event-stream> stream.

The transport is a thin wrapper around L<Net::Async::MCP::Server/handle>: the
PSGI handler decodes the envelope and hands the request to C<handle()>. The
spec-mandated header checks run first, but only for requests that carry an
C<id> — a notification (no C<id>) skips them entirely and goes straight to
C<handle()>, since the 2026-07-28 spec does not define header requirements
for notification POSTs. Method implementations live in
L<Net::Async::MCP::Server>; this module is the HTTP layer and nothing else.

=head1 PROTOCOL

A conforming client POSTs every JSON-RPC request or notification to a single
endpoint (the C<MCP endpoint>, by default F</mcp>). Headers it MUST set:

=over 4

=item *

C<MCP-Protocol-Version> — the protocol version, mirrored from
C<params._meta.io.modelcontextprotocol/protocolVersion> in the body.

=item *

C<Mcp-Method> — mirrored from C<method>.

=item *

C<Mcp-Name> — for C<tools/call>, C<resources/read>, C<prompts/get>, mirrored
from C<params.name> (or C<params.uri> for C<resources/read>).

=item *

C<Mcp-Param-{Name}> — for any tool argument annotated with
C<x-mcp-header: "{Name}"> in the tool's C<inputSchema>, mirrored from the
matching C<arguments> value.

=back

Any divergence between header value and body value is rejected with HTTP 400
and JSON-RPC error C<-32020 HeaderMismatch>.

The body MUST be a single JSON-RPC request or notification, C<Content-Type:
application/json>. The client MUST include C<Accept: application/json,
text/event-stream> so the server can pick the matching response mode.

=cut

# The methods whose name-ish parameter is mirrored into Mcp-Name, and the
# parameter it is taken from. Same table the client half uses.
my %NAME_PARAM = (
    'tools/call'     => 'name',
    'resources/read' => 'uri',
    'prompts/get'    => 'name',
);

# The header names the spec owns. HTTP/1.1 header lookup is case-insensitive
# but we still need canonical spellings to read PSGI's HTTP_MCP_PROTOCOL_VERSION
# (a CGI-style env key is one underscore per dash, uppercased) back into the
# spec's form.
my $PROTOCOL_HEADER     = 'MCP-Protocol-Version';
my $METHOD_HEADER       = 'Mcp-Method';
my $NAME_HEADER         = 'Mcp-Name';
my $PARAM_HEADER_PREFIX = 'Mcp-Param-';

sub new {
    my ( $class, %params ) = @_;
    my $server = delete $params{server};
    my $self   = $class->SUPER::new(%params);
    $self->{server} = $server if defined $server;
    return $self;
}

sub configure {
    my ( $self, %params ) = @_;
    for my $key (qw( server host port path origin_allow )) {
        $self->{$key} = delete $params{$key} if exists $params{$key};
    }

    $self->{host}        //= '127.0.0.1';
    $self->{port}        //= 8080;
    $self->{path}        //= '/mcp';
    $self->{origin_allow} //= [];

    # Adapt origin_allow to a hash for O(1) membership tests.
    if ( ref $self->{origin_allow} eq 'ARRAY' ) {
        my %o = map { $_ => 1 } @{ $self->{origin_allow} };
        $self->{origin_allow_set} = \%o;
    }

    $self->SUPER::configure(%params);
}

=method server

    my $server = $transport->server;

Returns the L<Net::Async::MCP::Server> instance this transport feeds.

=cut

sub server { $_[0]->{server} }

=method host

    my $host = $transport->host;

Returns the interface to bind on. Defaults to C<127.0.0.1>. Non-loopback binds
emit a warning unless the caller has set up C<disable_loopback_warning> (see
L</listen>).

=cut

sub host { $_[0]->{host} }

=method port

    my $port = $transport->port;

Returns the TCP port the transport binds to. Defaults to 8080.

=cut

sub port { $_[0]->{port} }

=method path

    my $path = $transport->path;

Returns the URL path of the MCP endpoint. Defaults to C</mcp>.

=cut

sub path { $_[0]->{path} }

=method origin_allow

    my @allow = @{ $transport->origin_allow };

Returns the ArrayRef of origin URLs the transport permits. An empty list is a
deliberate "allow any" — most operators will want to lock it down to their
known web origins.

=cut

sub origin_allow { $_[0]->{origin_allow} || [] }

=method to_app

    my $psgi = $transport->to_app;
    my $res  = $psgi->($env);

Returns the PSGI coderef that handles a single request. Useful for
C<HTTP::Server::PSGI>-driven bring-up and C<Plack::Test>-driven testing;
production deployments normally wrap this in a reverse proxy.

=cut

sub to_app {
    my ( $self ) = @_;
    my $transport = $self;

    return sub {
        my ( $env ) = @_;
        return $transport->_handle_request($env);
    };
}

=method listen

    $http->listen;

Binds on the configured C<host:port> using L<HTTP::Server::PSGI> and starts
accepting requests. Blocks the caller and the event loop with it: the loop is
not yet wired into the accept loop. Unlike
L<Net::Async::MCP::Server::Transport::Stdio/handle_requests>, which reads
through the loop and leaves other notifiers running, nothing else in the loop
gets a turn here. A real async bring-up is a future ticket.

A non-loopback bind is warned about, since exposing an MCP server on a public
interface is almost always accidental and unauthenticated; pass
C<allow_external_bind> to silence the warning when you really mean it.

=cut

sub listen {
    my ( $self, %opts ) = @_;
    my $host = $self->{host};

    # Refuse to silently expose the server on a public interface.
    unless ( $opts{allow_external_bind}
        || $host eq '127.0.0.1'
        || $host eq '::1'
        || $host eq 'localhost'
        || $host eq '' ) {
        warn "StreamableHTTP listening on $host:${\$self->{port}}; "
          . "this is non-loopback. Set 'host' to 127.0.0.1 or pass "
          . "allow_external_bind to acknowledge.\n";
    }

    require HTTP::Server::PSGI;

    my $server = HTTP::Server::PSGI->new(
        host => $host,
        port => $self->{port},
    );
    $server->run( $self->to_app );
    return $server;
}

# --- The PSGI dispatch path ----------------------------------------------

# Reads the request body off the PSGI input handle. PSGI gives us a stream
# to read from, not a string; this is straightforward but the format's two
# scalar/array forms are easy to get wrong.
sub _read_body {
    my ( $env ) = @_;
    my $in = $env->{'psgi.input'};
    return '' unless $in;

    my $cl = $env->{CONTENT_LENGTH};
    return '' unless defined $cl && length $cl && $cl =~ /\A[0-9]+\z/;

    my $body = '';
    my $remaining = $cl;
    while ( $remaining > 0 ) {
        my $chunk = '';
        my $read  = $in->read( $chunk, $remaining );
        return $body unless defined $read && $read > 0;
        $body .= $chunk;
        $remaining -= $read;
    }
    return $body;
}

# Header lookup, case-insensitive. PSGI already uppercases keys and folds
# dashes to underscores, but a case-insensitive fallback makes tool authors
# who flout that safe.
sub _lookup_psgi_header {
    my ( $env, $name ) = @_;
    my $psgi_key = 'HTTP_' . uc $name;
    $psgi_key =~ tr/-/_/;
    return $env->{$psgi_key};
}

sub _check_origin {
    my ( $self, $env ) = @_;

    my $set = $self->{origin_allow_set};
    return undef unless $set && keys %$set;

    my $origin = $env->{HTTP_ORIGIN};
    return undef unless defined $origin && length $origin;

    return undef if $set->{$origin};
    return $self->_origin_blocked_response();
}

sub _origin_blocked_response {
    my ( $self ) = @_;
    my $body = encode_json({
        jsonrpc => '2.0',
        id      => undef,
        error   => {
            code    => -32600,
            message => 'Forbidden: invalid Origin',
        },
    });
    return [
        403,
        [
            'Content-Type'   => 'application/json',
            'Content-Length' => length($body),
        ],
        [$body],
    ];
}

# The PSGI entry point (private) — one call per HTTP request. Exposed
# mostly for tests that want to feed canned %env hashes around to_app.
sub _handle_request {
    my ( $self, $env ) = @_;

    # Anything not on the configured MCP endpoint is a 404. A real server
    # might also host a management UI or health check; this one does not.
    my $path = $env->{PATH_INFO} // '/';
    $path = '/' . $path unless $path =~ m{^/};
    return $self->_not_found_response() unless $path eq $self->{path};

    # Origin is checked on every request, including GET/DELETE — the spec's
    # DNS-rebinding guard isn't only about POST.
    if ( my $err = $self->_check_origin($env) ) {
        return $err;
    }

    my $method = $env->{REQUEST_METHOD} // 'GET';

    # Per the 2026-07-28 spec, the only client-server methods this revision
    # binds to the MCP endpoint are POST and GET on /mcp. GET is the legacy
    # stream-open hook that 2025-03-26..2025-11-25 servers used, and this
    # revision dropped it — answering 405 makes the era difference visible.
    unless ( $method eq 'POST' || $method eq 'GET' || $method eq 'DELETE' ) {
        return $self->_method_not_allowed_response();
    }

    if ( $method eq 'GET' || $method eq 'DELETE' ) {
        return $self->_method_not_allowed_response();
    }

    # Content-Type MUST be application/json. Anything else (text/plain,
    # multipart/form-data, an empty body with a notification) is a client
    # error we surface immediately rather than waste a parse on.
    my $ct = $env->{CONTENT_TYPE} // '';
    unless ( $ct =~ m{^application/json\b}i ) {
        return $self->_json_rpc_error_response(
            -32700, 'Content-Type must be application/json', undef,
        );
    }

    my $body = _read_body($env);
    my $request = eval { decode_json($body) };
    if ( $@ || ref $request ne 'HASH' ) {
        return $self->_json_rpc_error_response(
            -32700, 'Parse error', undef,
        );
    }

    # A notification (no id) is accepted and discarded; the spec calls for
    # 202 Accepted with no body. The 2026-07-28 spec explicitly notes that
    # "header requirements for notification POSTs are not defined by this
    # revision", so we skip the full header validation path here.
    if ( !defined $request->{id} ) {
        $self->server->handle($request);
        return $self->_accepted_response();
    }

    if ( my $err = $self->_validate_headers($env, $request) ) {
        return $err;
    }

    # subscriptions/listen has no server->client push channel to deliver
    # *ListChanged in 0.002, so it falls through to handle() and gets the
    # normal -32601 — the same answer the Stdio transport gives. Real push
    # delivery is deferred to karr #24.

    # Default: synchronous JSON-RPC dispatch. handle() returns either a
    # response hashref or undef (the no-id case we already handled above
    # doesn't reach here, so undef here would be a malformed request —
    # treat it as such).
    my $response = $self->server->handle($request);
    if ( !$response ) {
        return $self->_json_rpc_error_response(
            -32600, 'Invalid request', $request->{id},
        );
    }

    # The client's Accept governs whether we wrap as JSON or as SSE. The
    # spec gives the server the choice per request, and clients that send
    # both content types leave it free. We pick the one the client says it
    # can handle; absent Accept, default to application/json.
    my $accept = $env->{HTTP_ACCEPT} // '';
    my $sse    = $accept =~ m{text/event-stream}i;

    if ( $sse && ( $response->{error} || !$response->{result} ) ) {
        # Errors and notifications don't naturally stream; SSE alone won't
        # carry a JSON-RPC error in any spec-mandated way. Stay on JSON.
        $sse = 0;
    }

    if ( $sse ) {
        return $self->_handle_sse_stream($env, $request, $response);
    }

    return $self->_json_response($response);
}

# --- Header validation per spec section "Server Validation" -------------

sub _validate_headers {
    my ( $self, $env, $request ) = @_;

    # MCP-Protocol-Version: derived from the body's
    # _meta.io.modelcontextprotocol/protocolVersion; missing or mismatched
    # is a HeaderMismatch.
    my $protocol_header = _lookup_psgi_header($env, $PROTOCOL_HEADER);
    unless ( defined $protocol_header && length $protocol_header ) {
        return $self->_header_mismatch(
            "$PROTOCOL_HEADER header is required",
            $request->{id},
        );
    }
    my $body_version = $self->_meta_field($request, 'io.modelcontextprotocol/protocolVersion');
    unless ( defined $body_version && length $body_version ) {
        return $self->_json_rpc_error_response(
            -32602,
            'Invalid params: missing io.modelcontextprotocol/protocolVersion',
            $request->{id},
        );
    }
    unless ( $protocol_header eq $body_version ) {
        return $self->_header_mismatch(
            "$PROTOCOL_HEADER header '$protocol_header' does not match "
              . "body '$body_version'",
            $request->{id},
        );
    }

    # Mcp-Method: mirrors method.
    my $method_header = _lookup_psgi_header($env, $METHOD_HEADER);
    unless ( defined $method_header && length $method_header ) {
        return $self->_header_mismatch(
            "$METHOD_HEADER header is required",
            $request->{id},
        );
    }
    my $body_method = $request->{method};
    unless ( defined $body_method && length $body_method ) {
        return $self->_json_rpc_error_response(
            -32600, 'Missing JSON-RPC method', $request->{id},
        );
    }
    unless ( $method_header eq $body_method ) {
        return $self->_header_mismatch(
            "$METHOD_HEADER header '$method_header' does not match body",
            $request->{id},
        );
    }

    # Mcp-Name: required for tools/call, resources/read, prompts/get.
    my $name_param = $NAME_PARAM{ $body_method };
    if ( $name_param ) {
        my $name_header = _lookup_psgi_header($env, $NAME_HEADER);
        unless ( defined $name_header && length $name_header ) {
            return $self->_header_mismatch(
                "$NAME_HEADER header is required for $body_method",
                $request->{id},
            );
        }

        my $body_params = ref $request->{params} eq 'HASH' ? $request->{params} : {};
        my $body_name   = $body_params->{$name_param};
        unless ( defined $body_name && length $body_name ) {
            return $self->_json_rpc_error_response(
                -32602,
                "Invalid params: missing params.$name_param",
                $request->{id},
            );
        }

        my $decoded_name = $self->_decode_header($name_header);
        unless ( defined $decoded_name && $decoded_name eq $body_name ) {
            return $self->_header_mismatch(
                "$NAME_HEADER header value does not match body "
                  . "params.$name_param",
                $request->{id},
            );
        }
    }

    # Mcp-Param-{Name}: only meaningful for tools/call. The spec names these
    # via x-mcp-header annotations in inputSchema; we don't track the schema
    # here. Instead, every Mcp-Param-* header present on the request must
    # match a value at the same name in params.arguments.
    if ( $body_method eq 'tools/call' ) {
        my $params = ref $request->{params} eq 'HASH' ? $request->{params} : {};
        my $arguments = ref $params->{arguments} eq 'HASH' ? $params->{arguments} : {};

        # HTTP field names are case-insensitive (RFC 9110) and tool authors
        # are free to annotate a JSON property `region` with x-mcp-header
        # "Region", so the body-side lookup has to follow.
        my %lc_args = map { lc $_ => $_ } keys %$arguments;

        for my $key ( sort keys %{$env} ) {
            next unless $key =~ m{^HTTP_MCP_PARAM_(.+)$};
            my $arg_name = $1;
            $arg_name =~ tr/_/-/;
            my $header_value = $env->{$key};

            my $body_key = $lc_args{ lc $arg_name };
            unless ($body_key) {
                return $self->_header_mismatch(
                    "$PARAM_HEADER_PREFIX$arg_name header set but body "
                      . "has no arguments.$arg_name",
                    $request->{id},
                );
            }

            my $body_value = $arguments->{$body_key};
            my $decoded    = $self->_decode_header($header_value);
            unless (
                defined $decoded
                && ( "$decoded" eq "$body_value" )
            ) {
                return $self->_header_mismatch(
                    "$PARAM_HEADER_PREFIX$arg_name header value does not "
                      . "match body arguments.$body_key",
                    $request->{id},
                );
            }
        }
    }

    return undef;
}

sub _meta_field {
    my ( $self, $request, $name ) = @_;
    my $params = ref $request->{params} eq 'HASH' ? $request->{params} : {};
    my $meta   = ref $params->{_meta} eq 'HASH' ? $params->{_meta} : {};
    return $meta->{$name};
}

# Decodes a Mcp-Name / Mcp-Param-* header. A value wrapped in the
# =?base64?...?= sentinel is decoded from Base64 of UTF-8; everything else
# is returned as-is. A value that looks like the sentinel but doesn't
# actually decode is flagged as an invalid header.
sub _decode_header {
    my ( $self, $value ) = @_;

    if ( $value =~ /\A=\?base64\?(.*)\?=\z/s ) {
        my $raw = $1;
        my $bytes = eval { decode_base64($raw) };
        return undef unless defined $bytes && length $bytes;
        my $decoded = eval { decode('UTF-8', $bytes, FB_DEFAULT) };
        return $decoded unless $@;
        return undef;
    }

    return $value;
}

sub _header_mismatch {
    my ( $self, $message, $id ) = @_;
    return $self->_json_rpc_error_response(
        -32020, "Header mismatch: $message", $id,
    );
}

sub _json_rpc_error_response {
    my ( $self, $code, $message, $id, $data ) = @_;
    my $err = { code => $code, message => $message };
    $err->{data} = $data if defined $data;
    my $body = encode_json({
        jsonrpc => '2.0',
        id      => $id,
        error   => $err,
    });
    return [
        400,
        [
            'Content-Type'   => 'application/json',
            'Content-Length' => length($body),
        ],
        [$body],
    ];
}

sub _json_response {
    my ( $self, $response ) = @_;
    my $body = encode_json($response);
    return [
        200,
        [
            'Content-Type'   => 'application/json',
            'Content-Length' => length($body),
        ],
        [$body],
    ];
}

sub _accepted_response {
    return [
        202,
        [
            'Content-Length' => 0,
        ],
        [''],
    ];
}

sub _not_found_response {
    my $body = '';
    return [
        404,
        [
            'Content-Type'   => 'text/plain',
            'Content-Length' => 0,
        ],
        [$body],
    ];
}

sub _method_not_allowed_response {
    return [
        405,
        [
            'Allow'          => 'POST',
            'Content-Length' => 0,
        ],
        [''],
    ];
}

# --- SSE response path ----------------------------------------------------

# A successful request that the client wants as SSE arrives here. We emit
# the JSON-RPC response as the single SSE event so the client gets its
# answer in the stream form it asked for; the stream is closed afterwards.
# Keepalives are pointlessly short-circuited because the response closes it.
sub _handle_sse_stream {
    my ( $self, $env, $request, $response ) = @_;
    my $jsonrpc = encode_json($response);

    return sub {
        my ( $respond ) = @_;
        my $writer = $respond->([
            200,
            $self->_sse_headers,
        ]);
        $writer->write( $self->_format_sse_event( '', $jsonrpc ) );
        $writer->close;
        return;
    };
}

sub _sse_headers {
    return [
        'Content-Type'      => 'text/event-stream',
        'X-Accel-Buffering' => 'no',
        'Cache-Control'     => 'no-cache',
        'Connection'        => 'keep-alive',
    ];
}

# Formats a single SSE event. data lines prefix each line of the JSON
# with "data: " per the spec; the event terminator is a blank line.
sub _format_sse_event {
    my ( $self, $event_name, $data ) = @_;

    my @lines;
    if ( defined $event_name && length $event_name ) {
        push @lines, "event: $event_name";
    }
    my $payload = defined $data ? $data : '';
    for my $line ( split /\r?\n/, $payload, -1 ) {
        push @lines, "data: $line";
    }
    # The trailing blank line that terminates the event.
    return join("\n", @lines, '') . "\n";
}

1;

=head1 SEE ALSO

L<Net::Async::MCP::Server>, L<Net::Async::MCP::Server::Transport::Stdio>,
L<HTTP::Server::PSGI>, L<Plack::Test>, L<IO::Async::Notifier>.

L<https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http>
— the protocol this transport speaks.

=cut
