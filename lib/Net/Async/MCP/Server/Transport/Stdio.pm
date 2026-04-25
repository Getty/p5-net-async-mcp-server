package Net::Async::MCP::Server::Transport::Stdio;
# ABSTRACT: Stdio transport for Net::Async::MCP::Server

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use JSON::MaybeXS qw( encode_json decode_json );

our $VERSION = '0.001';

=head1 SYNOPSIS

    use Net::Async::MCP::Server::Transport::Stdio;

    my $transport = Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    );
    $transport->handle_requests;

=head1 DESCRIPTION

Stdio transport for MCP server using newline-delimited JSON-RPC over stdin/stdout.

Each line is a JSON-RPC 2.0 message. Requests are read from stdin, responses written
to stdout.

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

sub server {
    my ( $self ) = @_;
    return $self->{server};
}

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