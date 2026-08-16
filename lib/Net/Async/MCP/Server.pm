package Net::Async::MCP::Server;
# ABSTRACT: Async MCP server base class

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;

use JSON::MaybeXS qw( encode_json );

our $VERSION = '0.002';

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
built on L<IO::Async>. It implements the stateless, per-request metadata variant
of MCP 2026-07-28: every request carries C<io.modelcontextprotocol/*> keys in
C<_meta>, every successful result carries C<resultType> and an
C<io.modelcontextprotocol/serverInfo> entry in C<_meta>, and the C<initialize>
handshake is gone.

=cut

# The protocol revision this server speaks. Per the 2026-07-28 spec, every
# request must carry this in _meta.io.modelcontextprotocol/protocolVersion.
our $PROTOCOL_VERSION = '2026-07-28';

# The protocol versions a client may negotiate down to. The 2026-07-28 spec is
# not backwards-compatible with 2025-11-25 (the handshake-based predecessor),
# so this list is intentionally a single entry; dual-era support is out of
# scope for 0.002.
sub supported_versions { [ '2026-07-28' ] }

=method supported_versions

Returns ArrayRef of protocol version strings this server accepts.

=cut

sub _init {
  my ( $self, $params ) = @_;
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  if (exists $params{name}) {
    $self->{name} = delete $params{name};
  }
  $self->SUPER::configure(%params);
}

sub _add_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_add_to_loop($loop);
}

sub name { shift->{name} // 'NetAsyncMCPServer' }

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
    return $self->{server_capabilities} // $self->_build_capabilities;
}

=method server_capabilities

Returns the server capabilities hashref.

=cut

sub _build_capabilities {
    my ( $self ) = @_;
    return { tools => {} };
}

async sub discover {
    my ( $self ) = @_;

    $self->{server_capabilities} //= $self->_build_capabilities;

    return {
        resultType        => 'complete',
        supportedVersions  => $self->supported_versions,
        capabilities       => $self->server_capabilities,
        ttlMs              => 300000,
        cacheScope         => 'public',
    };
}

=method discover

Handles the C<server/discover> RPC. Returns the server's supported protocol
versions, capabilities, identity (in C<_meta.io.modelcontextprotocol/serverInfo>),
and caching hints.

=cut

sub tools {
    my ( $self ) = @_;
    return $self->{tools} // [];
}

=method tools

Returns ArrayRef of registered tool definitions (internal storage shape).

=cut

sub register_tool {
    my ( $self, %tool ) = @_;
    die "register_tool requires 'name'" unless defined $tool{name};

    # Normalise input_schema -> inputSchema. Accept the legacy snake_case key
    # so existing callers don't have to change in lockstep.
    if ( exists $tool{input_schema} && !exists $tool{inputSchema} ) {
        $tool{inputSchema} = delete $tool{input_schema};
    }

    die "Tool '$tool{name}' requires 'inputSchema'"
        unless exists $tool{inputSchema};

    $self->{tools} //= [];
    push @{ $self->{tools} }, \%tool;
}

=method register_tool(%tool)

Registers a tool. Expects C<name>, C<description>, C<inputSchema> (or the
legacy C<input_schema> alias), and an optional C<code> reference. The
C<inputSchema> MUST be present — tools without a parameter schema are
non-conformant under MCP 2026-07-28.

=cut

async sub list_tools {
    my ( $self ) = @_;
    return [ map { $self->_tool_wire_shape($_) } @{ $self->{tools} // [] } ];
}

sub _tool_wire_shape {
    my ( $self, $tool ) = @_;
    my %t = (
        name        => $tool->{name},
        description => $tool->{description},
        inputSchema => $tool->{inputSchema},
    );
    $t{title} = $tool->{title} if defined $tool->{title};
    return \%t;
}

=method list_tools

Returns ArrayRef of tool definitions in wire shape (C<inputSchema>, not
C<input_schema>).

=cut

async sub call_tool {
    my ( $self, $name, $arguments ) = @_;

    my $tool = $self->_find_tool($name);
    die "No tool registered: $name" unless $tool;

    if (my $code = $tool->{code}) {
        return $code->($arguments);
    }

    die "Tool '$name' has no implementation";
}

sub _find_tool {
    my ( $self, $name ) = @_;
    for my $tool (@{ $self->{tools} // [] }) {
        return $tool if $tool->{name} eq $name;
    }
    return undef;
}

=method call_tool($name, $arguments)

Called when a client invokes a tool. Subclasses should override to provide
tool implementations. The return value is wrapped by the dispatch layer:

=over

=item *

A plain value (string, number, hashref, arrayref) is wrapped in a single
C<text> content block inside a C<complete> result.

=item *

A hashref that already carries a C<resultType> (e.g. C<input_required> for
MRTR) is passed through unchanged.

=back

To signal that a tool needs more input from the client, return a hashref
shaped like:

    {
        resultType    => 'input_required',
        inputRequests => { ... },
        requestState  => '...',   # optional, opaque
    }

=cut

sub handle {
    my ( $self, $request ) = @_;

    return _jsonrpc_error( -32700, 'Invalid JSON-RPC request' )
        unless ref $request eq 'HASH';

    my $method = $request->{method};
    my $id     = $request->{id};

    return _jsonrpc_error( -32600, 'Missing JSON-RPC method', $id )
        unless defined $method;

    if ( defined $id ) {
        # Per-request _meta validation. Required on every RPC; missing or
        # wrong-version fields short-circuit the dispatch with a JSON-RPC
        # error so the client can fall back / renegotiate.
        if ( my $err = $self->_validate_request_meta($request) ) {
            return $err;
        }

        if ( $method eq 'server/discover' ) {
            return $self->_handle_discover($id);
        }
        elsif ( $method eq 'tools/list' ) {
            return $self->_handle_tools_list($id);
        }
        elsif ( $method eq 'tools/call' ) {
            return $self->_handle_tools_call( $request->{params} // {}, $id );
        }

        return _jsonrpc_error( -32601, "Method '$method' not found", $id );
    }

    # Notifications (no id): no-op. The stdio transport skips writing
    # anything when handle() returns undef.
    return undef;
}

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

sub _handle_discover {
    my ( $self, $id ) = @_;

    my $result = $self->discover->get;
    return $self->_jsonrpc_response( $result, $id );
}

sub _handle_tools_list {
    my ( $self, $id ) = @_;

    my $tools = $self->list_tools->get;
    return $self->_jsonrpc_response(
        {
            resultType => 'complete',
            tools      => $tools,
            ttlMs      => 300000,
            cacheScope => 'public',
        },
        $id,
    );
}

sub _handle_tools_call {
    my ( $self, $params, $id ) = @_;

    my $name = $params->{name}      // '';
    my $args = $params->{arguments} // {};

    # Protocol error: unknown tool. The spec routes this through JSON-RPC,
    # not through an isError result, so the model can't retry it as if it
    # were a recoverable tool failure.
    my $tool = $self->_find_tool($name);
    unless ($tool) {
        return _jsonrpc_error(
            -32602,
            "Invalid params: unknown tool '$name'",
            $id,
        );
    }

    my $result;
    eval {
        $result = $self->call_tool($name, $args)->get;
        1;
    } or do {
        # Tool execution error — wrap in isError content block so the model
        # can see and self-correct, instead of a JSON-RPC error that would
        # abort the call.
        return $self->_jsonrpc_response(
            {
                resultType => 'complete',
                content    => [ { type => 'text', text => "$@" } ],
                isError    => 1,
            },
            $id,
        );
    };

    # MRTR: a tool may return its own result hashref (e.g. resultType =>
    # 'input_required'). Pass through unchanged.
    if ( ref $result eq 'HASH' && defined $result->{resultType} ) {
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

L<Net::Async::MCP::Server::Transport::Stdio>, L<IO::Async::Notifier>, L<Future::AsyncAwait>.

=cut
