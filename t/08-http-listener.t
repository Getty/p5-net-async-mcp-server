use strict;
use warnings;

use Test2::V0;
use JSON::MaybeXS qw( encode_json decode_json );
use Future;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Timer::Periodic;

use Net::Async::MCP::Server;
use Net::Async::MCP::Server::Transport::StreamableHTTP;

# The non-blocking start() path, driven over a real loopback socket by a
# client that lives in the same loop. If start() blocked the loop (as listen()
# does), the client could never run and every request below would time out.
# HTTP::Server::PSGI is never involved.

my $loop = IO::Async::Loop->new;

my $server = Net::Async::MCP::Server->new( name => 'listener-test' );
$server->register_tool(
    name        => 'echo',
    description => 'Echoes msg',
    inputSchema => { type => 'object', properties => { msg => { type => 'string' } } },
    code        => sub { return { echoed => $_[0]{msg} } },
);

my $http = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
    server => $server,
    host   => '127.0.0.1',
    port   => 0,
);

is( dies { $http->start }, match qr/add the transport to a loop/, 'start before add croaks' );

$loop->add($http);

my $listener = $http->start->get;
my $port     = $listener->read_handle->sockport;
ok( $port, "bound an ephemeral port ($port)" );
is( dies { $http->start }, match qr/already started/, 'second start croaks' );

# Sends $raw, collects the reply until $done->($buf) is true (or 5s).
sub _exchange {
    my ( $raw, $done ) = @_;
    my $buf = '';
    my $f   = $loop->new_future;
    my $stream = IO::Async::Stream->new(
        on_read => sub {
            my ( $self, $buffref, $eof ) = @_;
            $buf .= $$buffref;
            $$buffref = '';
            $f->done($buf) if !$f->is_ready && ( $eof || $done->($buf) );
            return 0;
        },
        on_closed => sub { $f->done($buf) unless $f->is_ready },
    );
    $loop->add($stream);
    $loop->connect(
        addr => { family => 'inet', socktype => 'stream', ip => '127.0.0.1', port => $port },
    )->then( sub {
        my ($sock) = @_;
        $stream->configure( handle => $sock );
        $stream->write($raw);
        Future->done;
    } )->get;
    my $timeout = $loop->timeout_future( after => 5 );
    my $out = Future->wait_any( $f, $timeout->then( sub { Future->fail('timeout') } ) )->get;
    $loop->remove($stream);
    return $out;
}

sub _post {
    my ( $accept, $payload ) = @_;
    my $body = encode_json($payload);
    return "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
      . "Content-Type: application/json\r\nAccept: $accept\r\n"
      . "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: $payload->{method}\r\n"
      . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
}

my $discover = {
    jsonrpc => '2.0',
    id      => 7,
    method  => 'server/discover',
    params  => {
        _meta => {
            'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
            'io.modelcontextprotocol/clientCapabilities' => {},
        },
    },
};

# A timer that must keep ticking while requests are served: proof the loop is
# shared and not held by an accept loop.
my $ticks = 0;
my $timer = IO::Async::Timer::Periodic->new( interval => 0.02, on_tick => sub { $ticks++ } );
$loop->add($timer);
$timer->start;

subtest 'JSON request over the loop-native listener' => sub {
    my $raw = _exchange( _post( 'application/json', $discover ), sub { $_[0] =~ /"resultType"/ } );
    like( $raw, qr{\AHTTP/1\.1 200 }, '200 status line' );
    like( $raw, qr{Content-Type: application/json}i, 'JSON content type' );
    my ($json) = $raw =~ /(\{.*\})\s*\z/s;
    my $res = decode_json($json);
    is( $res->{id}, 7, 'id echoed' );
    is( $res->{result}{resultType}, 'complete', 'discover answered' );
};

subtest 'SSE response is streamed chunked' => sub {
    my $raw = _exchange(
        _post( 'application/json, text/event-stream', $discover ),
        sub { $_[0] =~ /\r\n0\r\n\r\n\z/ },
    );
    like( $raw, qr{\AHTTP/1\.1 200 }, '200 status line' );
    like( $raw, qr{Content-Type: text/event-stream}i, 'SSE content type' );
    like( $raw, qr{Transfer-Encoding: chunked}i, 'chunked' );
    like( $raw, qr{data: \{.*"id":7}, 'event carries the response' );
};

subtest 'header parity check still applies' => sub {
    my $call = {
        jsonrpc => '2.0',
        id      => 3,
        method  => 'tools/call',
        params  => {
            %{ $discover->{params} },
            name      => 'echo',
            arguments => { msg => 'hi' },
        },
    };
    # Mcp-Name header absent for tools/call -> parity error
    my $raw = _exchange( _post( 'application/json', $call ), sub { $_[0] =~ /"error"/ } );
    like( $raw, qr{\AHTTP/1\.1 400 }, '400 for mismatching headers' );
    like( $raw, qr{-32020}, 'HeaderMismatch' );
};

ok( $ticks >= 1, "timer ticked while serving ($ticks ticks)" );
$timer->stop;

$loop->remove($http);
ok( !defined $listener->loop, 'removing the transport stops the listener' );

done_testing;
