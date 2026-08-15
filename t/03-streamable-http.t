use strict;
use warnings;
use utf8;

use Test2::V0;
use JSON::MaybeXS qw( encode_json decode_json );
use MIME::Base64 qw( encode_base64 );
use Encode      qw( encode );

use HTTP::Request::Common qw( POST GET );
use Plack::Test();

use Net::Async::MCP::Server;
use Net::Async::MCP::Server::Transport::StreamableHTTP;

sub _decode_ok {
    my ($body) = @_;
    my $out = decode_json($body);
    ok( ref $out eq 'HASH', 'body decoded as hashref' );
    return $out;
}

# A handler that records what was written through the Plack writer and
# signals done, so streaming tests can inspect both the chunking and the
# eventual close without spinning a real HTTP server.
package _RecorderWriter {
    sub new {
        my ($class) = @_;
        return bless { chunks => [], closed => 0,}, $class;
    }
    sub write {
        my ($self, $chunk) = @_;
        push @{ $self->{chunks} }, $chunk;
        return length $chunk;
    }
    sub close {
        my ($self) = @_;
        $self->{closed} = 1;
        return;
    }
}

package _FakeWriter {
    sub new {
        my ($class, %opts) = @_;
        return bless {
            recorder  => $opts{recorder},
            on_close  => $opts{on_close} // sub {},
        }, $class;
    }
    sub write {
        my ($self, $chunk) = @_;
        return $self->{recorder}->write($chunk);
    }
    sub close {
        my ($self) = @_;
        return $self->{on_close}->();
    }
}

package main;

sub _build_envelope {
    my (%over) = @_;
    my %base = (
        jsonrpc => '2.0',
        id      => 1,
        method  => 'server/discover',
        params  => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
        },
    );
    return { %base, %over };
}

sub _make_server {
    my $server = Net::Async::MCP::Server->new(name => 'http-test');
    $server->register_tool(
        name        => 'echo',
        description => 'Echoes msg',
        inputSchema => {
            type       => 'object',
            properties => {
                msg => { type => 'string', 'x-mcp-header' => 'Msg' },
            },
        },
        code => sub {
            my ($args) = @_;
            return { echoed => $args->{msg} };
        },
    );
    return $server;
}

sub _make_call_envelope {
    my (%over) = @_;
    my $base = _build_envelope(
        id     => 7,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'echo',
            arguments => { msg => 'hello' },
        },
    );
    # Tunnel key-only overrides into params.arguments so the test can swap
    # the msg value without restating the whole envelope.
    if ( exists $over{arguments} ) {
        $base->{params}{arguments} = delete $over{arguments};
    }
    if ( exists $over{name} ) {
        $base->{params}{name} = delete $over{name};
    }
    return { %{ $base }, %over };
}

subtest 'POST application/json returns JSON-RPC response' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'           => 'application/json',
        'Accept'                 => 'application/json',
        'MCP-Protocol-Version'   => '2026-07-28',
        'Mcp-Method'             => 'server/discover',
        'Content'                => encode_json(_build_envelope(id => 1)),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK');
    is($res->content_type, 'application/json', 'JSON content-type');

    my $body = _decode_ok($res->content);
    is($body->{jsonrpc}, '2.0', 'jsonrpc 2.0');
    is($body->{id}, 1, 'id matches');
    is($body->{result}{resultType}, 'complete', 'resultType complete');
};

subtest 'POST text/event-stream wraps response in SSE' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'           => 'application/json',
        'Accept'                 => 'application/json, text/event-stream',
        'MCP-Protocol-Version'   => '2026-07-28',
        'Mcp-Method'             => 'server/discover',
        'Content'                => encode_json(_build_envelope(id => 42)),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK');
    is($res->content_type, 'text/event-stream', 'SSE content-type');

    my $body = $res->content;
    like($body, qr/^data: /m, 'body has data: prefix');
    like($body, qr/\n\n\z/, 'body ends with blank line');

    my ($data_line) = $body =~ m{^data: (.*)$}m;
    ok($data_line, 'captured data line');
    my $payload = _decode_ok($data_line);
    is($payload->{id}, 42, 'id in SSE payload');
    is($payload->{result}{resultType}, 'complete', 'resultType complete');
};

subtest 'notifications/initialized returns 202 with no body' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $notification = {
        jsonrpc => '2.0',
        method  => 'notifications/initialized',
        params  => {},
    };
    my $req = POST(
        '/mcp',
        'Content-Type' => 'application/json',
        'Accept'       => 'application/json',
        'Content'      => encode_json($notification),
    );
    my $res = $test->request($req);

    is($res->code, 202, '202 Accepted');
    is($res->content, '', 'empty body');
};

subtest 'MCP-Protocol-Version mismatch returns 400 -32020' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $envelope = _build_envelope(
        id     => 1,
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
        },
    );
    $envelope->{params}{_meta}{'io.modelcontextprotocol/protocolVersion'} = '1999-01-01';

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => 'no-such-version',
        'Mcp-Method'           => 'server/discover',
        'Content'              => encode_json($envelope),
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32020, 'JSON-RPC error -32020');
    like(
        $body->{error}{message},
        qr/MCP-Protocol-Version/,
        'message names the header',
    );
};

subtest 'Mcp-Method mismatch returns 400 -32020' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Content'              => encode_json(_build_envelope(id => 1)),
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32020, 'JSON-RPC error -32020');
    like(
        $body->{error}{message},
        qr/Mcp-Method/,
        'message names the header',
    );
};

subtest 'Mcp-Name mismatch returns 400 -32020' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'wrong_tool',
        'Content'              => encode_json(_make_call_envelope(id => 5)),
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32020, 'JSON-RPC error -32020');
    like(
        $body->{error}{message},
        qr/Mcp-Name/,
        'message names the header',
    );
};

subtest 'Origin not in allowlist returns 403' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server              => $server,
        keepalive_interval  => 0,
        origin_allow        => ['https://trusted.example.com'],
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'Origin'               => 'https://evil.example.com',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'server/discover',
        'Content'              => encode_json(_build_envelope(id => 99)),
    );
    my $res = $test->request($req);

    is($res->code, 403, '403 Forbidden');
    my $body = _decode_ok($res->content);
    is($body->{id}, undef, 'id is null in JSON-RPC envelope');
    ok(exists $body->{error}, 'error field present');
    is($body->{error}{code}, -32600, 'JSON-RPC error code -32600');
    like(
        $body->{error}{message},
        qr/Origin/i,
        'message mentions Origin',
    );
};

subtest 'Origin in allowlist passes' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server              => $server,
        keepalive_interval  => 0,
        origin_allow        => ['https://trusted.example.com'],
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'Origin'               => 'https://trusted.example.com',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'server/discover',
        'Content'              => encode_json(_build_envelope(id => 1)),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK on allowed origin');
};

subtest 'empty origin_allow permits any origin' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'Origin'               => 'https://anywhere.example.com',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'server/discover',
        'Content'              => encode_json(_build_envelope(id => 1)),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK with empty allowlist');
};

subtest 'x-mcp-header parity passes when header matches body' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'echo',
        'Mcp-Param-Msg'        => 'hello',
        'Content'              => encode_json(
            _make_call_envelope(id => 6, arguments => { msg => 'hello' }),
        ),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK on matching header');
    my $body = _decode_ok($res->content);
    is($body->{result}{content}[0]{text}, '{"echoed":"hello"}', 'tool returned echoed value');
};

subtest 'x-mcp-header mismatch returns 400 -32020' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'echo',
        'Mcp-Param-Msg'        => 'wrong_value',
        'Content'              => encode_json(
            _make_call_envelope(id => 8, arguments => { msg => 'correct_value' }),
        ),
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32020, 'JSON-RPC error -32020');
    like(
        $body->{error}{message},
        qr/Mcp-Param/i,
        'message names the param header',
    );
};

subtest 'x-mcp-header parity with base64 UTF-8 value matches body' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $utf8_value = 'Hellö Wörld';
    my $b64 = encode_base64(encode('UTF-8', $utf8_value), '');

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'echo',
        'Mcp-Param-Msg'        => "=?base64?$b64?=",
        'Content'              => encode_json(
            _make_call_envelope(id => 9, arguments => { msg => $utf8_value }),
        ),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK on base64 UTF-8 match');
    my $body = _decode_ok($res->content);

    # The tool's return value is JSON-encoded into the text content block.
    # The exact byte form depends on the JSON encoder's UTF-8 handling, so
    # compare the inner JSON value rather than the textual representation.
    my $payload = decode_json( $body->{result}{content}[0]{text} );
    is(
        $payload->{echoed} . '',
        $utf8_value . '',
        'tool echoed decoded UTF-8 value',
    );
};

subtest 'x-mcp-header argument not in body returns 400 -32020' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'echo',
        'Mcp-Param-Msg'        => 'something',
        'Content'              => encode_json(
            _make_call_envelope(id => 10, arguments => {}),
        ),
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request when header refers to absent argument');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32020, 'JSON-RPC error -32020');
};

subtest 'GET on /mcp returns 405' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = GET('/mcp');
    my $res = $test->request($req);

    is($res->code, 405, '405 Method Not Allowed');
    is($res->header('Allow'), 'POST', 'Allow: POST');
};

subtest 'POST with wrong Content-Type returns -32700' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type' => 'text/plain',
        'Content'      => 'not json',
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32700, 'JSON-RPC error -32700 Parse error');
    like(
        $body->{error}{message},
        qr/Content-Type/i,
        'message explains the Content-Type requirement',
    );
};

subtest 'POST with invalid JSON body returns -32700' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST(
        '/mcp',
        'Content-Type' => 'application/json',
        'Content'      => '{not valid json',
    );
    my $res = $test->request($req);

    is($res->code, 400, '400 Bad Request');
    my $body = _decode_ok($res->content);
    is($body->{error}{code}, -32700, 'JSON-RPC error -32700');
};

subtest 'POST to unknown path returns 404' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    my $req = POST('/other',
        'Content-Type' => 'application/json',
        'Content'      => '{}',
    );
    my $res = $test->request($req);

    is($res->code, 404, '404 Not Found');
};

subtest 'subscriptions/listen emits SSE acknowledgement event' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $envelope = _build_envelope(
        id     => 'sub-1',
        method => 'subscriptions/listen',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            notifications => {
                'tools/list_changed' => {},
            },
        },
    );

    my $responder = $t->_handle_subscriptions_listen({}, $envelope);
    ok($responder, 'responder returned');

    my $state = { status => undef, headers => undef, };
    my $recorder = _RecorderWriter->new;
    my $close_called = 0;
    my $returned = $responder->(sub {
        my ($writer_cb) = @_;
        $state->{status}  = $writer_cb->[0];
        $state->{headers} = $writer_cb->[1];
        return _FakeWriter->new(
            recorder => $recorder,
            on_close => sub {
                $close_called = 1;
                $recorder->close;
                return;
            },
        );
    });
    is($state->{status}, 200, 'status 200');
    is($state->{headers}[0], 'Content-Type', 'Content-Type header');
    is($state->{headers}[1], 'text/event-stream', 'sse content-type');
    is($state->{headers}[2], 'X-Accel-Buffering', 'X-Accel-Buffering header');
    is($state->{headers}[3], 'no', 'X-Accel-Buffering: no');

    my $joined = join '', @{ $recorder->{chunks} };
    like($joined, qr/^data: \{/m, 'starts with data: payload');
    like($joined, qr/\n\n\z/, 'event terminated with blank line');

    my ($data_line) = $joined =~ m{^data: (.*)$}m;
    my $payload = _decode_ok($data_line);
    is(
        $payload->{method},
        'notifications/subscriptions/acknowledged',
        'ack notification method',
    );
    is(
        $payload->{params}{_meta}{'io.modelcontextprotocol/subscriptionId'},
        'sub-1',
        'subscriptionId in _meta',
    );
    is($close_called, 1, 'writer closed by keepalive_interval=0 (no keepalive loop)');
};

subtest 'configure defaults are loopback + 8080 + /mcp' => sub {
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new;
    is($t->host, '127.0.0.1', 'default host loopback');
    is($t->port, 8080, 'default port 8080');
    is($t->path, '/mcp', 'default path /mcp');
    is($t->keepalive_interval, 15, 'default keepalive 15s');
    is(scalar @{ $t->origin_allow }, 0, 'empty origin_allow');
};

subtest 'non-loopback host warns (does not error)' => sub {
    my $server = _make_server;
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, shift };
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        host               => '0.0.0.0',
        keepalive_interval => 0,
    );
    is($t->host, '0.0.0.0', 'host retained');
    ok(1, 'no exception during construction');
};

subtest 'x-mcp-header argument lookup is case-insensitive' => sub {
    my $server = _make_server;
    my $t = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server             => $server,
        keepalive_interval => 0,
    );
    my $test = Plack::Test->create( $t->to_app );

    # Mcp-Param-Msg header references the lowercased `msg` argument. The
    # CGIs env folds the header suffix to uppercase, but the lookup is
    # case-insensitive on the body side.
    my $req = POST(
        '/mcp',
        'Content-Type'         => 'application/json',
        'Accept'               => 'application/json',
        'MCP-Protocol-Version' => '2026-07-28',
        'Mcp-Method'           => 'tools/call',
        'Mcp-Name'             => 'echo',
        'Mcp-Param-Msg'        => 'hello',
        'Content'              => encode_json(
            _make_call_envelope(id => 11, arguments => { msg => 'hello' }),
        ),
    );
    my $res = $test->request($req);

    is($res->code, 200, '200 OK on case-insensitive lookup');
};

done_testing;
