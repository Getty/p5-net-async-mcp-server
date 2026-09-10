package Net::Async::MCP::Server::Transport::Stdio;
# ABSTRACT: Stdio transport for Net::Async::MCP::Server

use strict;
use warnings;

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Handle;
use JSON::MaybeXS qw( encode_json decode_json );
use Scalar::Util qw( weaken );

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
    for my $key (qw( server read_handle write_handle )) {
        $self->{$key} = delete $params{$key} if exists $params{$key};
    }

    $self->{read_handle}  //= \*STDIN;
    $self->{write_handle} //= \*STDOUT;

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

=method read_handle

    my $fh = $transport->read_handle;

The filehandle JSON-RPC requests are read from, C<\*STDIN> unless a
C<read_handle> was passed to the constructor or to C<configure>. Overriding it
lets the transport be driven from a pipe — which is how it is tested, without
spawning a process. It must be a real OS handle: L</handle_requests> reads it
through an L<IO::Async::Stream>, so an in-memory filehandle will not do.

=cut

sub read_handle {
    my ( $self ) = @_;
    return $self->{read_handle};
}

=method write_handle

    my $fh = $transport->write_handle;

The filehandle responses are written to, C<\*STDOUT> unless a C<write_handle>
was passed to the constructor or to C<configure>. Unlike L</read_handle> this
one is written to with a plain C<print>, so any filehandle will do.

L</handle_requests> turns C<autoflush> on for it. That is a change to a handle
the caller may own and keep using, but a buffered response is a response the
client never sees in time.

=cut

sub write_handle {
    my ( $self ) = @_;
    return $self->{write_handle};
}

=method handle_requests

    $transport->handle_requests;

Enters the main loop, reading JSON-RPC requests from L</read_handle> and
writing responses to L</write_handle>. This method blocks until the read handle
is closed (EOF), which is the spec's graceful-shutdown signal. Per MCP
2026-07-28 the transport is stateless: each line is an independent request and
the server carries no session across calls.

It blocks the caller, but it does not block the event loop. Reading happens in
an L<IO::Async::Stream> registered as a child of this transport, and the wait
for EOF is a wait on a L<Future>, so every other notifier in the same loop —
timers, other transports — keeps running while requests are being read. If the
transport is not a member of a loop yet, one is created and the transport added
to it.

The read handle is left open on EOF; the caller owns C<STDIN> and may still
want it once the transport has shut down.

C<autoflush> is switched on for L</write_handle> once, on entry: each response
must reach the client as it is written, not when the buffer happens to fill.
The write itself is still a blocking C<print>.

=cut

sub handle_requests {
    my ( $self ) = @_;

    my $loop = $self->loop;
    unless ($loop) {
        $loop = IO::Async::Loop->new;
        $loop->add($self);
    }

    # The write handle is usually a pipe to the client, which Perl block
    # buffers: a finished response would sit in the buffer while the client
    # waits for it and this transport waits for the next request, until 4-8K
    # had piled up or the process exited. Set here rather than in configure
    # because this is the point where the transport takes over a handle the
    # caller owns, and once per run rather than per response.
    $self->write_handle->autoflush(1);

    my $eof_f = $loop->new_future;

    # The stream holds this callback and this transport holds the stream as a
    # child, so capturing $self strongly here would close a cycle no refcount
    # ever breaks. Weakening costs nothing: for as long as the callback can
    # fire at all, the loop is holding the transport for us.
    weaken( my $weak_self = $self );

    my $stream = IO::Async::Stream->new(
        read_handle       => $self->read_handle,
        close_on_read_eof => 0,
        on_read           => sub {
            my ( undef, $buffref, $eof ) = @_;
            my $self = $weak_self or return 0;
            return $self->_on_read( $buffref, $eof );
        },
        on_read_eof => sub {
            $eof_f->done unless $eof_f->is_ready;
        },
    );

    $self->add_child($stream);

    # A tool that dies still propagates out of handle() and thus out of here,
    # as it did from the readline loop this replaced — but the stream has to
    # come back out of the loop either way.
    my $ok  = eval { $eof_f->get; 1 };
    my $err = $@;

    $self->remove_child($stream);

    die $err unless $ok;
    return;
}

sub _on_read {
    my ( $self, $buffref, $eof ) = @_;

    if ( $$buffref =~ s/^([^\n]*)\n// ) {
        $self->_handle_line($1);
        return 1;    # there may be another complete line in the buffer
    }

    # A final line that never got its newline is still a request; the readline
    # loop this replaced delivered it too.
    if ( $eof and length $$buffref ) {
        my $line = $$buffref;
        $$buffref = '';
        $self->_handle_line($line);
    }

    return 0;
}

sub _handle_line {
    my ( $self, $line ) = @_;

    return unless length $line;

    my $request = eval { decode_json($line) };
    if ($@) {
        $self->_send_response({
            jsonrpc => '2.0',
            id      => undef,
            error   => { code => -32700, message => 'Parse error' },
        });
        return;
    }

    my $response = $self->server->handle(
        $request,
        { transport => 'stdio' },
    );
    $self->_send_response($response) if $response;

    return;
}

sub _send_response {
    my ( $self, $response ) = @_;
    print { $self->write_handle } encode_json($response) . "\n";
}

1;

=head1 SEE ALSO

L<Net::Async::MCP::Server>, L<IO::Async::Notifier>.

=cut
