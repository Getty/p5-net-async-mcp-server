package Net::Async::MCP::Server;
# ABSTRACT: Async MCP server base class

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;

our $VERSION = '0.001';

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
built on L<IO::Async>. It handles the MCP protocol handshake and request routing,
allowing subclasses to implement specific tools.

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
    return $self->{server_capabilities} // {};
}

=method server_capabilities

Returns the server capabilities hashref.

=cut

async sub initialize {
    my ( $self ) = @_;

    $self->{server_capabilities} = $self->_build_capabilities;
    $self->{_initialized} = 1;

    return {
        protocolVersion => '2025-11-25',
        capabilities    => $self->server_capabilities,
        serverInfo      => $self->server_info,
    };
}

=method initialize

Performs MCP server initialization. Handles the C<initialize> request from the
client, returns server info and capabilities.

=cut

sub _build_capabilities {
    my ( $self ) = @_;
    return { tools => {} };
}

sub tools {
    my ( $self ) = @_;
    return $self->{tools} // [];
}

=method tools

Returns ArrayRef of registered tool definitions.

=cut

sub register_tool {
    my ( $self, %tool ) = @_;
    $self->{tools} //= [];
    push @{ $self->{tools} }, \%tool;
}

=method register_tool(%tool)

Registers a tool. Expects C<name>, C<description>, C<input_schema>, C<code>.

=cut

async sub list_tools {
    my ( $self ) = @_;
    return $self->tools;
}

=method list_tools

Returns ArrayRef of tool definitions.

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
tool implementations.

=cut

sub handle {
    my ( $self, $request, $context ) = @_;

    return _jsonrpc_error( -32700, 'Invalid JSON-RPC request' )
        unless ref $request eq 'HASH';

    my $method = $request->{method};
    my $id     = $request->{id};

    return _jsonrpc_error( -32600, 'Missing JSON-RPC method', $id )
        unless defined $method;

    if ( defined $id ) {
        if ( $method eq 'initialize' ) {
            return $self->_handle_initialize( $request->{params} // {}, $id );
        }
        elsif ( $method eq 'tools/list' ) {
            return $self->_handle_tools_list( $id );
        }
        elsif ( $method eq 'tools/call' ) {
            return $self->_handle_tools_call( $request->{params} // {}, $id );
        }
        elsif ( $method eq 'ping' ) {
            return _jsonrpc_response( {}, $id );
        }

        return _jsonrpc_error( -32601, "Method '$method' not found", $id );
    }

    if ( $method eq 'notifications/initialized' ) {
        return undef;
    }
    elsif ( $method eq 'shutdown' ) {
        return undef;
    }

    return undef;
}

sub _handle_initialize {
    my ( $self, $params, $id ) = @_;

    my $result = $self->initialize->get;

    return _jsonrpc_response( $result, $id );
}

sub _handle_tools_list {
    my ( $self, $id ) = @_;

    my $tools = $self->list_tools->get;
    return _jsonrpc_response( { tools => $tools }, $id );
}

sub _handle_tools_call {
    my ( $self, $params, $id ) = @_;

    my $name = $params->{name}      // '';
    my $args = $params->{arguments} // {};

    my $result = $self->call_tool( $name, $args )->get;
    return _jsonrpc_response( $result, $id );
}

sub _jsonrpc_error {
    my ( $code, $message, $id ) = @_;
    return {
        jsonrpc => '2.0',
        id      => $id,
        error   => { code => $code, message => $message },
    };
}

sub _jsonrpc_response {
    my ( $result, $id ) = @_;
    return { jsonrpc => '2.0', id => $id, result => $result };
}

1;

=head1 SEE ALSO

L<Net::Async::MCP::Server::Transport::Stdio>, L<IO::Async::Notifier>, L<Future::AsyncAwait>.

=cut