# NAME

Net::Async::MCP::Server — Async MCP (Model Context Protocol) server base class

# VERSION

0.002

# SYNOPSIS

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

# DESCRIPTION

**Net::Async::MCP::Server** is an asynchronous MCP (Model Context Protocol)
server built on [IO::Async](https://metacpan.org/pod/IO::Async). It implements
MCP 2026-07-28, the stateless, per-request metadata revision of the spec.
There is no `initialize` handshake and no shared session — every request
carries its protocol version, client capabilities, and identity inline in the
`_meta` field, and every successful result carries a `resultType` and a
`_meta.io.modelcontextprotocol/serverInfo` entry.

Subclasses register tools; the base class handles JSON-RPC 2.0 dispatch and
the per-request validation the spec mandates. Two transports are included:

- [Net::Async::MCP::Server::Transport::Stdio](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::Stdio) —
  newline-delimited JSON-RPC over stdin/stdout.
- [Net::Async::MCP::Server::Transport::StreamableHTTP](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::StreamableHTTP) —
  the Streamable HTTP transport from MCP 2026-07-28: one POST endpoint,
  request-metadata headers, optional SSE.

## MCP Protocol

MCP 2026-07-28 is a JSON-RPC 2.0 protocol with no handshake. Every
request must carry two keys in `params._meta`:

- `io.modelcontextprotocol/protocolVersion` — the protocol version the
  client speaks. Missing returns JSON-RPC `-32602`; unsupported returns
  `-32022` with the server's `supported` list in `data`.
- `io.modelcontextprotocol/clientCapabilities` — the client's capabilities
  object. Missing returns `-32602`; any required capability that is not
  present returns `-32021`.

The methods this server implements:

- **server/discover** — pre-flight discovery. Returns `supportedVersions`,
  `capabilities`, caching hints (`ttlMs`, `cacheScope`), and the server
  identity in `_meta.io.modelcontextprotocol/serverInfo`. No prior
  handshake required.
- **tools/list** — list registered tools. Returns `resultType "complete"`,
  the `tools` array (each with `inputSchema` in wire shape), and the same
  caching hints as above.
- **tools/call** — invoke a tool by name. A tool's plain return value is
  wrapped in a `text` content block; a tool that returns a hashref with
  `resultType` set (e.g. `"input_required"` for MRTR) is passed through
  unchanged so multi round-trip requests work without further changes.

The methods the previous revision exposed — `initialize`,
`notifications/initialized`, `ping` — are no longer recognised and return
`-32601 Method not found`.

Every successful result carries `resultType` (defaults to `"complete"`) and
an `_meta.io.modelcontextprotocol/serverInfo` block injected by the dispatch
layer; callers do not have to add it themselves.

## Error Codes

- `-32601 Method not found` — unimplemented method (e.g. `initialize`,
  `ping` from the previous revision).
- `-32602 Invalid params` — missing or malformed `_meta`, or `tools/call`
  with an unknown tool name.
- `-32020 HeaderMismatch` — Streamable HTTP only: an MCP request-metadata
  header disagrees with the matching field in the JSON-RPC body.
- `-32021 MissingRequiredClientCapability` — the client did not declare a
  capability the server requires.
- `-32022 UnsupportedProtocolVersion` — the request's
  `io.modelcontextprotocol/protocolVersion` is not in this server's
  `supportedVersions`; the error `data` lists the supported ones.

## Architecture

The server is built on
[IO::Async::Notifier](https://metacpan.org/pod/IO::Async::Notifier) for
non-blocking I/O and uses
[Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) for clean
`async sub` methods. Methods that return a `Future` (`discover`,
`list_tools`, `call_tool`) are explicitly marked in the POD.

# METHODS

## name

    my $name = $server->name;

Returns the server name exposed via MCP protocol. Default is
`'NetAsyncMCPServer'`.

## server_info

    my $info = $server->server_info;
    # { name => 'my-server', version => '0.002' }

Returns a hashref with `name` and `version` keys for the MCP protocol.

## server_capabilities

    my $caps = $server->server_capabilities;

Returns the server capabilities hashref.

## supported_versions

    my $versions = $server->supported_versions;
    # [ '2026-07-28' ]

Returns an ArrayRef of protocol version strings this server accepts. The
2026-07-28 revision is not backwards-compatible with the previous
handshake-based one, so this list is a single entry by design.

## discover

    my $result = $server->discover->get;

Handles the JSON-RPC `server/discover` request. Returns a `Future` that
resolves to the discovery result: `resultType`, `supportedVersions`,
`capabilities`, caching hints, and `_meta.io.modelcontextprotocol/serverInfo`.
On the wire this is invoked as `server/discover`; the Perl method is named
`discover` because it is what `handle()` calls.

## register_tool

    $server->register_tool(
        name        => 'echo',
        description => 'Echoes the input back',
        input_schema => {                  # legacy alias accepted
            type       => 'object',
            properties => {
                value => { type => 'string' },
            },
            required   => ['value'],
        },
        code => sub {
            my ($args) = @_;
            return { echoed => $args->{value} };
        },
    );

Registers a tool. Expects `name`, `description`, `inputSchema` (or the
legacy `input_schema` alias), and an optional `code` reference. The
`inputSchema` is required — tools without a parameter schema are
non-conformant under MCP 2026-07-28.

## tools

    my $tools = $server->tools;

Returns the ArrayRef of registered tool definitions (internal storage shape).

## list_tools

    my $tools = $server->list_tools->get;

Returns a `Future` that resolves to the ArrayRef of tool definitions in
wire shape (`inputSchema`, not `input_schema`).

## call_tool

    my $result = $server->call_tool($name, $arguments)->get;

Returns a `Future` that resolves to one of:

- a plain value (string, number, hashref, arrayref) — the dispatch layer
  wraps it in a `text` content block inside a `complete` result;
- a hashref carrying `resultType` — the dispatch layer passes it through
  unchanged, so a tool can signal
  `{ resultType => 'input_required', inputRequests => {...} }` for MRTR;
- an exception — the dispatch layer catches it and surfaces it as an
  `isError: true` content block (recoverable), not a JSON-RPC error
  (which would abort the call).

# TRANSPORTS

## Net::Async::MCP::Server::Transport::Stdio

    use Net::Async::MCP::Server::Transport::Stdio;

    my $transport = Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    );
    $transport->handle_requests;

Newline-delimited JSON-RPC over stdin/stdout. The transport is stateless
— there is no session, no handshake, and no shared state between
requests. The protocol version, client capabilities, and identity are
carried inline in each request's `_meta` field. A complete request looks
like:

    {"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}}

`handle_requests` blocks reading `<STDIN>` line by line until EOF, which
is the spec's graceful-shutdown signal. See
[Net::Async::MCP::Server::Transport::Stdio](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::Stdio).

## Net::Async::MCP::Server::Transport::StreamableHTTP

    use IO::Async::Loop;
    use Net::Async::MCP::Server;
    use Net::Async::MCP::Server::Transport::StreamableHTTP;

    my $loop = IO::Async::Loop->new;

    my $server = Net::Async::MCP::Server->new(name => 'my-server');
    $loop->add($server);

    my $http = Net::Async::MCP::Server::Transport::StreamableHTTP->new(
        server => $server,
        host   => '127.0.0.1',
        port   => 8080,
        path   => '/mcp',
    );
    $loop->add($http);
    $http->listen;

The Streamable HTTP transport from MCP 2026-07-28. A conforming client
POSTs every JSON-RPC request or notification to a single endpoint (the
MCP endpoint, by default `/mcp`) and sets the request-metadata headers
the spec defines: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` (for
`tools/call`), and `Mcp-Param-{Name}` for any tool argument annotated
with `x-mcp-header: "{Name}"` in its `inputSchema`. Any header/body
divergence returns JSON-RPC `-32020 HeaderMismatch`. The transport answers
each request as `application/json` (default) or as `text/event-stream`
when the client's `Accept` header asks for it; `subscriptions/listen`
keeps the SSE stream open with periodic `:keepalive` comments.

The transport is a thin wrapper around `Net::Async::MCP::Server::handle`;
method implementations live in
[Net::Async::MCP::Server](https://metacpan.org/pod/Net::Async::MCP::Server).
For `Plack::Test`-driven testing or any other PSGI host, use
`$http->to_app`. See
[Net::Async::MCP::Server::Transport::StreamableHTTP](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::StreamableHTTP)
for the full list of options.

# SEE ALSO

- [Net::Async::MCP::Server::Transport::Stdio](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::Stdio)
- [Net::Async::MCP::Server::Transport::StreamableHTTP](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::StreamableHTTP)
- [IO::Async::Notifier](https://metacpan.org/pod/IO::Async::Notifier)
- [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait)
- [Plack](https://metacpan.org/pod/Plack) — runtime dep of the Streamable
  HTTP transport.

# AUTHOR

Torsten Raudssus `<getty@cpan.org>`

# COPYRIGHT & LICENSE

Copyright 2026 Torsten Raudssus.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License version 2.0.

See [https://raudss.us.devel](https://raudss.us.devel) for the full license text.
