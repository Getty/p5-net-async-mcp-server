use strict;
use warnings;

use Test2::V0;
use Net::Async::MCP::Server;

# Helper: build a fully-formed 2026-07-28 request envelope. Tests can override
# any field by passing args.
sub _req {
    my (%override) = @_;
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
    return { %base, %override };
}

subtest 'server/discover' => sub {
    my $server = Net::Async::MCP::Server->new(name => 'disc-server');

    my $response = $server->handle(_req(method => 'server/discover', id => 7));

    ok($response, 'got response');
    is($response->{id}, 7, 'response id matches');
    is($response->{jsonrpc}, '2.0', 'jsonrpc 2.0');

    my $r = $response->{result};
    is($r->{resultType}, 'complete', 'resultType complete');
    is($r->{supportedVersions}[0], '2026-07-28', 'supportedVersions[0]');
    ok(exists $r->{capabilities}, 'capabilities present');

    # Per-result _meta must carry serverInfo.
    is(
        $r->{_meta}{'io.modelcontextprotocol/serverInfo'}{name},
        'disc-server',
        'serverInfo.name in _meta',
    );
    ok(
        defined $r->{_meta}{'io.modelcontextprotocol/serverInfo'}{version},
        'serverInfo.version in _meta',
    );

    # Caching hints per the spec MUST be present on complete cacheable results.
    ok(defined $r->{ttlMs}, 'ttlMs present');
    ok($r->{ttlMs} >= 0, 'ttlMs is non-negative');
    is($r->{cacheScope}, 'public', 'cacheScope public');
};

subtest 'tools/list result shape' => sub {
    my $server = Net::Async::MCP::Server->new;
    $server->register_tool(
        name         => 'my_tool',
        description  => 'A tool',
        inputSchema  => { type => 'object' },
    );

    my $response = $server->handle(_req(method => 'tools/list', id => 2));

    ok($response, 'got response');
    my $r = $response->{result};
    is($r->{resultType}, 'complete', 'resultType complete');
    is(scalar @{$r->{tools}}, 1, 'one tool in tools[]');
    is($r->{tools}[0]{name}, 'my_tool', 'tool name');
    ok(exists $r->{tools}[0]{inputSchema}, 'tool has inputSchema');
    ok(!exists $r->{tools}[0]{input_schema}, 'tool has no snake_case input_schema');
    ok(defined $r->{ttlMs}, 'ttlMs present');
    is($r->{cacheScope}, 'public', 'cacheScope public');
    ok(
        exists $r->{_meta}{'io.modelcontextprotocol/serverInfo'},
        '_meta.serverInfo present',
    );
};

subtest 'tools/call wraps plain return in text content block' => sub {
    my $server = Net::Async::MCP::Server->new;
    $server->register_tool(
        name         => 'echo',
        description  => 'Echoes input',
        inputSchema  => { type => 'object' },
        code         => sub {
            my ($args) = @_;
            return { echoed => $args->{value} };
        },
    );

    my $response = $server->handle(_req(
        id     => 3,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'echo',
            arguments => { value => 'hello' },
        },
    ));

    ok($response, 'got response');
    is($response->{id}, 3, 'response id matches');

    my $r = $response->{result};
    is($r->{resultType}, 'complete', 'resultType complete');
    ok(ref $r->{content} eq 'ARRAY', 'content is arrayref');
    is($r->{content}[0]{type}, 'text', 'first content is text');
    like(
        $r->{content}[0]{text},
        qr/echoed/,
        'text content carries the tool return value',
    );
};

subtest 'tools/call tool error becomes isError result, not JSON-RPC error' => sub {
    my $server = Net::Async::MCP::Server->new;
    $server->register_tool(
        name         => 'boom',
        description  => 'Always throws',
        inputSchema  => { type => 'object' },
        code         => sub { die "boom!\n" },
    );

    my $response = $server->handle(_req(
        id     => 4,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'boom',
            arguments => {},
        },
    ));

    ok($response, 'got response');
    ok(!exists $response->{error}, 'no JSON-RPC error');
    my $r = $response->{result};
    is($r->{resultType}, 'complete', 'resultType complete');
    ok($r->{isError}, 'isError true');
    is($r->{content}[0]{type}, 'text', 'content is text');
    like($r->{content}[0]{text}, qr/boom/, 'error message in content text');
};

subtest 'tools/call unknown tool returns -32602' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle(_req(
        id     => 5,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'does_not_exist',
            arguments => {},
        },
    ));

    ok($response, 'got response');
    ok(exists $response->{error}, 'JSON-RPC error returned');
    is($response->{error}{code}, -32602, 'error code -32602 Invalid params');
    like(
        $response->{error}{message},
        qr/unknown tool/i,
        'message mentions unknown tool',
    );
};

subtest 'MRTR input_required passes through unchanged' => sub {
    my $server = Net::Async::MCP::Server->new;
    $server->register_tool(
        name         => 'needs_input',
        description  => 'Needs more info',
        inputSchema  => { type => 'object' },
        code         => sub {
            return {
                resultType    => 'input_required',
                inputRequests => {
                    github_login => {
                        method => 'elicitation/create',
                        params => {
                            message         => 'Please provide your GitHub username',
                            requestedSchema => {
                                type       => 'object',
                                properties => { name => { type => 'string' } },
                                required   => ['name'],
                            },
                        },
                    },
                },
                requestState => 'opaque-blob',
            };
        },
    );

    my $response = $server->handle(_req(
        id     => 6,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'needs_input',
            arguments => {},
        },
    ));

    ok($response, 'got response');
    my $r = $response->{result};
    is($r->{resultType}, 'input_required', 'resultType input_required');
    ok(exists $r->{inputRequests}, 'inputRequests present');
    ok(exists $r->{inputRequests}{github_login}, 'inputRequests.github_login present');
    is(
        $r->{inputRequests}{github_login}{method},
        'elicitation/create',
        'elicitation/create method',
    );
    is($r->{requestState}, 'opaque-blob', 'requestState preserved');

    # Even MRTR results carry _meta.serverInfo — every successful result
    # does, per the spec.
    ok(
        exists $r->{_meta}{'io.modelcontextprotocol/serverInfo'},
        '_meta.serverInfo injected on MRTR result',
    );
};

subtest 'every successful result carries _meta.serverInfo' => sub {
    my $server = Net::Async::MCP::Server->new(name => 'meta-server');

    for my $method (qw(server/discover tools/list)) {
        my $response = $server->handle(_req(method => $method, id => 100));

        ok($response, "got response for $method");
        my $r = $response->{result};
        is(
            $r->{_meta}{'io.modelcontextprotocol/serverInfo'}{name},
            'meta-server',
            "serverInfo.name injected for $method",
        );
    }
};

subtest '_meta validation - missing protocolVersion returns -32602' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 10,
        method  => 'server/discover',
        params  => {
            _meta => {
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
        },
    });

    ok($response, 'got response');
    is($response->{error}{code}, -32602, 'error code -32602');
    like(
        $response->{error}{message},
        qr/protocolVersion/i,
        'message mentions protocolVersion',
    );
};

subtest '_meta validation - missing clientCapabilities returns -32602' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 11,
        method  => 'server/discover',
        params  => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
            },
        },
    });

    ok($response, 'got response');
    is($response->{error}{code}, -32602, 'error code -32602');
    like(
        $response->{error}{message},
        qr/clientCapabilities/i,
        'message mentions clientCapabilities',
    );
};

subtest '_meta validation - missing _meta entirely returns -32602' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 12,
        method  => 'server/discover',
        params  => {},
    });

    ok($response, 'got response');
    is($response->{error}{code}, -32602, 'error code -32602');
};

subtest 'unsupported protocol version returns -32022 with supported list' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 13,
        method  => 'server/discover',
        params  => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '1999-01-01',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
        },
    });

    ok($response, 'got response');
    is($response->{error}{code}, -32022, 'error code -32022');
    is(
        $response->{error}{message},
        'Unsupported protocol version',
        'message text',
    );
    ok(ref $response->{error}{data}{supported} eq 'ARRAY', 'data.supported arrayref');
    is(
        $response->{error}{data}{supported}[0],
        '2026-07-28',
        'data.supported[0]',
    );
    is(
        $response->{error}{data}{requested},
        '1999-01-01',
        'data.requested',
    );
};

subtest 'legacy 2025-11-25 version returns -32022' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 14,
        method  => 'server/discover',
        params  => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2025-11-25',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
        },
    });

    is($response->{error}{code}, -32022, 'legacy version rejected with -32022');
};

subtest 'initialize is rejected with -32601' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle(_req(id => 20, method => 'initialize'));

    ok($response, 'got response');
    is($response->{error}{code}, -32601, 'error code -32601 Method not found');
    like(
        $response->{error}{message},
        qr/initialize/,
        'message mentions initialize',
    );
};

subtest 'ping is rejected with -32601' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle(_req(id => 21, method => 'ping'));

    ok($response, 'got response');
    is($response->{error}{code}, -32601, 'error code -32601 Method not found');
};

subtest 'notifications/initialized is a no-op' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        method  => 'notifications/initialized',
        params  => {},
    });

    is($response, undef, 'notification returns undef (no response on wire)');
};

subtest 'notifications/tools/list_changed is a no-op' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        method  => 'notifications/tools/list_changed',
    });

    is($response, undef, 'notification returns undef');
};

subtest 'unknown method returns -32601' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle(_req(id => 30, method => 'unknown/method'));

    is($response->{error}{code}, -32601, 'error code -32601');
};

subtest 'missing method returns -32600' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle({
        jsonrpc => '2.0',
        id      => 31,
    });

    is($response->{error}{code}, -32600, 'error code -32600');
};

subtest 'non-hash request returns -32700' => sub {
    my $server = Net::Async::MCP::Server->new;

    my $response = $server->handle('not a hash');

    ok($response, 'got response');
    is($response->{error}{code}, -32700, 'error code -32700 Parse error');
};

subtest 'call_tool gets full arguments ref and additional context-free path' => sub {
    my $server = Net::Async::MCP::Server->new;
    $server->register_tool(
        name         => 'arith',
        description  => 'Sum',
        inputSchema  => { type => 'object' },
        code         => sub {
            my ($args) = @_;
            return $args->{a} + $args->{b};
        },
    );

    my $response = $server->handle(_req(
        id     => 40,
        method => 'tools/call',
        params => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            name      => 'arith',
            arguments => { a => 2, b => 3 },
        },
    ));

    my $r = $response->{result};
    is($r->{content}[0]{text}, '5', 'plain return stringified into text content');
};

done_testing;
