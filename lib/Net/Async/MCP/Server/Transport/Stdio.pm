package Net::Async::MCP::Server::Transport::Stdio;
# ABSTRACT: Stdio transport for Net::Async::MCP::Server

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use JSON::MaybeXS qw( encode_json decode_json );

our $VERSION = '0.002';

=head1 SYNOPSIS

    use Net::Async::MCP::Server::Transport::Stdio;

    my $transport = Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    );
    $transport->handle_requests;

=head1 DESCRIPTION

Stdio transport for MCP server using newline-delimited JSON-RPC over stdin/stdout.

Each line is a JSON-RPC 2.0 message. Requests and notifications are read from
stdin, responses written to stdout. The transport is stateless — there is no
session, no handshake, and no shared state between requests. The protocol
version, client capabilities, and identity are carried inline in each
request's C<_meta> field (see L<Net::Async::MCP::Server>).

This transport is suitable for MCP clients that communicate via standard input/output,
such as command-line AI tools.

=head1 PROTOCOL

Each JSON-RPC message is a single line terminated by a newline character.
Request format:

    {"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}}

Response format:

    {"jsonrpc": "2.0", "id": 1, "result": {...}}

Error format:

    {"jsonrpc": "2.0", "id": 1, "error": {"code": -32022, "message": "Unsupported protocol version", "data": {"supported": ["2026-07-28"]}}}

Notifications from the client are accepted and discarded (C<handle()> returns
C<undef>, nothing is written to stdout).

=cut

sub new {
    my ( $class, %params ) = @_;
    my $server = delete $params{server};
    my $self = $class->SUPER::new(%params);
    $self->{server} = $server if defined $server;
    return $self;
}

sub configure {
    my ( $self, %params ) = @_;
    if ( exists $params{server} ) {
        $self->{server} = delete $params{server};
    }
    $self->SUPER::configure(%params);
}

=method server

    my $server = $transport->server;

Returns the associated MCP server instance.

=cut

sub server {
    my ( $self ) = @_;
    return $self->{server};
}

=method handle_requests

    $transport->handle_requests;

Enters the main loop, reading JSON-RPC requests from stdin and writing responses
to stdout. This method blocks until stdin is closed (EOF), which is the spec's
graceful-shutdown signal. Per MCP 2026-07-28 the transport is stateless: each
line is an independent request and the server carries no session across calls.

=cut

sub handle_requests {
    my ( $self ) = @_;

    my $loop = $self->loop // IO::Async::Loop->new;

    while ( my $line = <STDIN> ) {
        chomp $line;
        next unless length $line;

        my $request = eval { decode_json($line) };
        if ($@) {
            $self->_send_response({
                jsonrpc => '2.0',
                id      => undef,
                error   => { code => -32700, message => 'Parse error' },
            });
            next;
        }

        my $response = $self->server->handle($request);
        if ($response) {
            $self->_send_response($response);
        }
    }
}

sub _send_response {
    my ( $self, $response ) = @_;
    print STDOUT encode_json($response) . "\n";
}

1;

=head1 SEE ALSO

L<Net::Async::MCP::Server>, L<IO::Async::Notifier>.

=cut
