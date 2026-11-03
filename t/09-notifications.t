#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use JSON::MaybeXS qw( encode_json decode_json );
use Future;

use Net::Async::MCP::Server;
use Net::Async::MCP::Server::Transport::Stdio;
use Net::Async::MCP::Server::Transport::StreamableHTTP;

# The server->client push channel: handle_f, the sink registry and
# emit_notification, list-changed, logging and progress, and the two
# transports that carry them.

my $META = {
    'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
    'io.modelcontextprotocol/clientCapabilities' => {},
};

sub _request {
    my ( $id, $method, %params ) = @_;
    return { jsonrpc => '2.0', id => $id, method => $method, params => { %params, _meta => { %$META, %{ delete $params{_meta} // {} } } } };
}

sub _server {
    my $server = Net::Async::MCP::Server->new( name => 'push-test' );
    $server->register_tool(
        name        => 'echo',
        description => 'Echoes text',
        inputSchema => { type => 'object' },
        code        => sub { return $_[0]{text} },
    );
    return $server;
}

subtest 'handle_f is the core, handle the synchronous wrapper' => sub {
    my $server = _server;

    my $f = $server->handle_f( _request( 1, 'tools/list' ) );
    isa_ok( $f, ['Future'], 'handle_f returns a Future' );
    ok( $f->is_ready, 'ready at once for a tool that does not wait' );
    is( $server->handle( _request( 1, 'tools/list' ) ), $f->get, 'handle returns what handle_f resolves to' );

    my $note = $server->handle_f( { jsonrpc => '2.0', method => 'notifications/initialized' } );
    is( $note->get, undef, 'a notification resolves to undef' );

    my $pending = Future->new;
    $server->register_tool(
        name        => 'slow',
        description => 'Waits',
        inputSchema => { type => 'object' },
        code        => sub { return $pending },
    );
    my $call = $server->handle_f( _request( 2, 'tools/call', name => 'slow', arguments => {} ) );
    ok( !$call->is_ready, 'a tool that waits leaves the request pending, nothing blocks' );
    $pending->done('late');
    is( $call->get->{result}{content}[0]{text}, 'late', 'and it resolves when the tool does' );
};

subtest 'sink registry and emit_notification' => sub {
    my $server = _server;
    my ( @a, @b, @only_tools );

    my $ta = $server->add_notification_sink( sub { push @a, $_[0] } );
    my $tb = $server->add_notification_sink( sub { push @b, $_[0]; Future->done } );
    $server->add_notification_sink( sub { push @only_tools, $_[0] }, methods => ['notifications/tools/list_changed'] );
    is( $server->notification_sink_count, 3, 'three sinks' );

    my $n = $server->emit_notification( 'notifications/test', { x => 1 } )->get;
    is( $n, 3 - 1, 'offered to the sinks that want it' );
    is( \@a, [ { jsonrpc => '2.0', method => 'notifications/test', params => { x => 1 } } ], 'complete JSON-RPC notification' );
    is( scalar @b, 1, 'fan-out reached the second sink' );
    is( \@only_tools, [], 'the method filter held back the unrelated notification' );

    $server->emit_notification('notifications/tools/list_changed')->get;
    is( scalar @only_tools, 1, 'the filtered sink gets the one it asked for' );
    ok( !exists $only_tools[0]{params}, 'no params key when there are none' );

    ok( $server->remove_notification_sink($ta), 'remove returns true' );
    ok( !$server->remove_notification_sink($ta), 'and false the second time' );

    my $dying = $server->add_notification_sink( sub { die "gone\n" } );
    my $failing = $server->add_notification_sink( sub { Future->fail('closed') } );
    is( $server->notification_sink_count, 4, 'two more sinks' );
    ok( lives { $server->emit_notification('notifications/test')->get }, 'a broken sink does not fail the emit' );
    is( $server->notification_sink_count, 2, 'the dying and the failing sink were dropped' );

    is( Net::Async::MCP::Server->new->emit_notification('notifications/test')->get, 0, 'no sinks: resolves to 0' );
};

subtest 'list changed' => sub {
    my $server = Net::Async::MCP::Server->new( name => 'lc' );
    my @seen;
    $server->add_notification_sink( sub { push @seen, $_[0]{method} } );

    $server->register_tool( name => 't', description => 'd', inputSchema => { type => 'object' } );
    $server->register_resource( uri => 'file:///a', name => 'a' );
    $server->register_prompt( name => 'p' );
    is(
        \@seen,
        [ map { "notifications/$_/list_changed" } qw( tools resources prompts ) ],
        'registering notifies the listening clients',
    );

    my $caps = $server->handle( _request( 1, 'server/discover' ) )->{result}{capabilities};
    ok( $caps->{tools}{listChanged}, 'tools advertise listChanged' );
    ok( $caps->{resources}{listChanged}, 'resources advertise listChanged' );
    ok( $caps->{prompts}{listChanged}, 'prompts advertise listChanged' );
    is( $caps->{logging}, {}, 'logging is advertised' );
};

subtest 'logging' => sub {
    my $server = _server;
    my @seen;
    $server->add_notification_sink( sub { push @seen, $_[0] } );

    is( $server->log_level, 'info', 'default level' );
    $server->log( debug => 'quiet' )->get;
    $server->log( warning => { a => 1 }, 'mylogger' )->get;
    is( \@seen, [ { jsonrpc => '2.0', method => 'notifications/message', params => { level => 'warning', data => { a => 1 }, logger => 'mylogger' } } ], 'below the level is dropped, above is sent' );

    my $r = $server->handle( _request( 1, 'logging/setLevel', level => 'debug' ) );
    is( $r->{result}{resultType}, 'complete', 'setLevel answers' );
    is( $server->log_level, 'debug', 'and sets the level' );
    @seen = ();
    $server->log( debug => 'now loud' )->get;
    is( scalar @seen, 1, 'debug is delivered after setLevel debug' );

    my $bad = $server->handle( _request( 2, 'logging/setLevel', level => 'loud' ) );
    is( $bad->{error}{code}, -32602, 'unknown level is -32602' );
    is( $server->log_level, 'debug', 'and changes nothing' );
    like( dies { $server->log( loud => 'x' ) }, qr/unknown level/, 'log croaks on an unknown level' );
};

subtest 'progress' => sub {
    my $server = _server;
    $server->register_tool(
        name        => 'work',
        description => 'Reports progress',
        inputSchema => { type => 'object' },
        code        => sub {
            my ( $args, $ctx ) = @_;
            $ctx->{progress}->( 1, 3, 'one' );
            $ctx->{progress}->(2);
            return 'done';
        },
    );
    my $call = sub { _request( 7, 'tools/call', name => 'work', arguments => {}, @_ ) };

    my @own;
    my $r = $server->handle_f(
        $call->( _meta => { progressToken => 'tok' } ),
        { notify => sub { push @own, $_[0]; Future->done } },
    )->get;
    is( $r->{result}{content}[0]{text}, 'done', 'the call itself is unaffected' );
    is(
        [ map { $_->{params} } @own ],
        [
            { progressToken => 'tok', progress => 1, total => 3, message => 'one' },
            { progressToken => 'tok', progress => 2 },
        ],
        'progress goes to the request notify callback',
    );
    is( $own[0]{method}, 'notifications/progress', 'as notifications/progress' );

    my @sink;
    $server->add_notification_sink( sub { push @sink, $_[0] } );
    $server->handle_f( $call->( _meta => { progressToken => 0 } ) )->get;
    is( scalar @sink, 2, 'without a request callback it fans out to the sinks; token 0 counts' );

    @sink = ();
    @own  = ();
    $server->handle_f( $call->(), { notify => sub { push @own, $_[0] } } )->get;
    is( [ scalar @sink, scalar @own ], [ 0, 0 ], 'no progressToken: progress is a no-op' );
};

subtest 'subscriptions/listen is unknown without a stream' => sub {
    my $r = _server->handle( _request( 1, 'subscriptions/listen' ) );
    is( $r->{error}{code}, -32601, 'plain handle(): -32601, as before' );
};

# --- Stdio -------------------------------------------------------------------

sub _decode_lines { [ map { decode_json($_) } grep { length } split /\n/, ( $_[0] // '' ) ] }

subtest 'stdio: overlapping requests, notifications on stdout' => sub {
    my $loop   = IO::Async::Loop->new;
    my $server = _server;

    # Request A waits until request B has run: possible only if A does not
    # hold the dispatch while it waits.
    my $gate = $loop->new_future;
    $server->register_tool(
        name        => 'wait',
        description => 'Waits for release',
        inputSchema => { type => 'object' },
        code        => sub { return $gate->then( sub { Future->done('A released') } ) },
    );
    $server->register_tool(
        name        => 'release',
        description => 'Releases wait',
        inputSchema => { type => 'object' },
        code        => sub {
            my ( undef, $ctx ) = @_;
            $ctx->{progress}->( 1, 1, 'releasing' );
            $server->log( error => 'released' );
            $gate->done;
            return 'B done';
        },
    );

    pipe( my $rh, my $wh ) or die "pipe: $!";
    $wh->autoflush(1);
    open my $out_fh, '>', \my $out or die $!;
    $out_fh->autoflush(1);
    my $transport = Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server, read_handle => $rh, write_handle => $out_fh,
    );
    $loop->add($transport);

    my @lines = (
        encode_json( _request( 'A', 'tools/call', name => 'wait', arguments => {} ) ) . "\n",
        encode_json( _request( 'B', 'tools/call', name => 'release', arguments => {}, _meta => { progressToken => 'p1' } ) ) . "\n",
    );
    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay     => 0.05,
        on_expire => sub {
            if ( my $line = shift @lines ) { print {$wh} $line; $timer->start }
            else                           { close $wh }
        },
    );
    $loop->add($timer);
    $timer->start;

    $transport->handle_requests;

    my $msgs = _decode_lines($out);
    is(
        [ map { $_->{method} // "response:$_->{id}" } @$msgs ],
        [ 'notifications/progress', 'notifications/message', 'response:A', 'response:B' ],
        'progress, log record, then both answers: A was pending when B released it',
    );
    is( $msgs->[0]{params}{progressToken}, 'p1', 'progress token echoed' );
    is( $msgs->[2]{result}{content}[0]{text}, 'A released', 'A got its answer' );
    is( $server->notification_sink_count, 0, 'the transport removed its sink on the way out' );
};

# --- StreamableHTTP over a real socket ----------------------------------------

subtest 'http: listen stream, list changed, progress on a delayed answer' => sub {
    my $loop   = IO::Async::Loop->new;
    my $server = _server;

    my $gate = $loop->new_future;
    $server->register_tool(
        name        => 'slow',
        description => 'Progress, then waits',
        inputSchema => { type => 'object' },
        code        => sub {
            my ( undef, $ctx ) = @_;
            $ctx->{progress}->( 1, 2, 'half' );
            return $gate->then( sub { Future->done('slow done') } );
        },
    );

    my $http = Net::Async::MCP::Server::Transport::StreamableHTTP->new( server => $server, host => '127.0.0.1', port => 0 );
    $loop->add($http);
    my $port = $http->start->get->read_handle->sockport;

    my $open = sub {
        my ( $payload, $accept ) = @_;
        my $buf = '';
        my $stream = IO::Async::Stream->new(
            on_read => sub { $buf .= ${ $_[1] }; ${ $_[1]} = ''; 0 },
        );
        $loop->add($stream);
        $loop->connect( addr => { family => 'inet', socktype => 'stream', ip => '127.0.0.1', port => $port } )->then( sub {
            $stream->configure( handle => $_[0] );
            my $body = encode_json($payload);
            $stream->write(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: $accept\r\n"
                . "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: $payload->{method}\r\n"
                . ( $payload->{params}{name} ? "Mcp-Name: $payload->{params}{name}\r\n" : '' )
                . "Content-Length: " . length($body) . "\r\n\r\n$body"
            );
            Future->done;
        } )->get;
        return ( \$buf, $stream );
    };
    my $until = sub {
        my ( $buf, $re ) = @_;
        my $deadline = time + 5;
        $loop->loop_once(0.05) while $$buf !~ $re && time < $deadline;
        return $$buf =~ $re;
    };

    # subscriptions/listen
    my ( $lbuf, $lstream ) = $open->(
        _request( 'L', 'subscriptions/listen', notifications => { 'tools/list_changed' => {} } ),
        'text/event-stream',
    );
    ok( $until->( $lbuf, qr{\r\n\r\n} ), 'listen stream answered with headers' );
    like( $$lbuf, qr{\AHTTP/1\.1 200 .*Content-Type: text/event-stream}si, 'an SSE stream' );
    is( $server->notification_sink_count, 1, 'a sink is registered for the open stream' );

    $server->register_tool( name => 'late', description => 'registered late', inputSchema => { type => 'object' } );
    $server->emit_notification( 'notifications/message', { level => 'error', data => 'unrelated' } )->get;
    ok( $until->( $lbuf, qr{list_changed} ), 'list_changed arrives on the open stream' );
    like( $$lbuf, qr{data: \{[^\n]*"method":"notifications/tools/list_changed"}, 'as an SSE data event' );
    unlike( $$lbuf, qr{unrelated}, 'the method filter of the listen request holds' );

    # tools/call with progress: stream opens at the progress, response is last
    my ( $cbuf ) = $open->(
        _request( 'C', 'tools/call', name => 'slow', arguments => {}, _meta => { progressToken => 'tk' } ),
        'application/json, text/event-stream',
    );
    ok( $until->( $cbuf, qr{notifications/progress} ), 'progress streams while the tool still waits' );
    unlike( $$cbuf, qr{slow done}, 'and the answer is not there yet' );
    $gate->done;
    ok( $until->( $cbuf, qr{slow done} ), 'the answer follows when the tool finishes' );
    like( $$cbuf, qr{notifications/progress.*"id":"C"}s, 'progress comes before the response' );

    # Same call without SSE: plain JSON, no progress
    $gate = $loop->new_future;
    $gate->done;    # the tool above captured the old gate; the new call below reuses the done one
    $server->{tools} = [ grep { $_->{name} ne 'slow' } @{ $server->{tools} } ];
    $server->register_tool(
        name => 'slow', description => 'again', inputSchema => { type => 'object' },
        code => sub { $_[1]{progress}->(1); return 'plain' },
    );
    my ( $pbuf ) = $open->(
        _request( 'P', 'tools/call', name => 'slow', arguments => {}, _meta => { progressToken => 'tk2' } ),
        'application/json',
    );
    ok( $until->( $pbuf, qr{"plain"|plain} ), 'plain JSON answer' );
    unlike( $$pbuf, qr{notifications/progress}, 'no progress without SSE' );
    like( $$pbuf, qr{Content-Type: application/json}i, 'JSON content type' );

    $loop->remove($lstream);
    $loop->remove($http);
};

done_testing;
