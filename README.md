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

Subclasses register tools, resources, and prompts; the base class handles
JSON-RPC 2.0 dispatch and the per-request validation the spec mandates. Two
transports are included:

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
  object. Only presence of the key is checked, not its contents — missing
  the key returns `-32602`.

The methods this server implements:

- **server/discover** — pre-flight discovery. Returns `supportedVersions`,
  `capabilities`, caching hints (`ttlMs`, `cacheScope`), and the server
  identity in `_meta.io.modelcontextprotocol/serverInfo`. No prior
  handshake required.
- **tools/list** — list registered tools. Returns `resultType "complete"`,
  the `tools` array (each with `inputSchema` in wire shape), and the same
  caching hints as above.
- **tools/call** — invoke a tool by name. A tool's plain return value is
  wrapped in a `text` content block; a tool may instead return a hashref
  carrying its own `content` array and/or `structuredContent` (images,
  multiple text blocks, structured data), which is passed through verbatim;
  a hashref with `resultType` set (e.g. `"input_required"` for MRTR) is
  passed through unchanged so multi round-trip requests work without
  further changes.
- **resources/list** — list registered resources. Returns `resultType
  "complete"` and the `resources` array (`uri`, `name`, and the optional
  `mimeType`, `description`, `title`).
- **resources/read** — read a resource by URI (`params.uri`; unregistered
  URI returns `-32602`). Returns `{ contents => [ { uri, mimeType?, text }
  ] }`.
- **prompts/list** — list registered prompts. Returns `resultType
  "complete"` and the `prompts` array (`name`, `arguments`, and the
  optional `title`, `description`).
- **prompts/get** — fetch a prompt by name (`params.name`; unregistered
  name returns `-32602`). Returns `{ description?, messages => [ { role,
  content => { type => "text", text } } ] }`.

The methods the previous revision exposed — `initialize`,
`notifications/initialized`, `ping` — are no longer recognised and return
`-32601 Method not found`.

Every successful result carries `resultType` (defaults to `"complete"`) and
an `_meta.io.modelcontextprotocol/serverInfo` block injected by the dispatch
layer; callers do not have to add it themselves.

## Error Codes

- `-32700 Parse error` — `handle()` was given something other than a
  hashref (a transport failed to decode the wire message into one).
- `-32600 Invalid Request` — the hashref has no defined `method`.
- `-32601 Method not found` — unimplemented method (e.g. `initialize`,
  `ping` from the previous revision).
- `-32602 Invalid params` — missing or malformed `_meta`, `tools/call`
  with an unknown tool name, `resources/read` with an unknown URI, or
  `prompts/get` with an unknown name.
- `-32020 HeaderMismatch` — Streamable HTTP only: an MCP request-metadata
  header disagrees with the matching field in the JSON-RPC body. Not
  raised by `Net::Async::MCP::Server::handle` itself.
- `-32022 UnsupportedProtocolVersion` — the request's
  `io.modelcontextprotocol/protocolVersion` is not in this server's
  `supportedVersions`; the error `data` lists the supported ones.

## Architecture

The server is built on
[IO::Async::Notifier](https://metacpan.org/pod/IO::Async::Notifier) for
non-blocking I/O and uses
[Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) for clean
`async sub` methods. Methods that return a `Future` (`discover`,
`list_tools`, `call_tool`, `list_resources`, `read_resource`,
`list_prompts`, `get_prompt`) are explicitly marked in the POD.

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

## resources

    my $resources = $server->resources;

Returns the ArrayRef of registered resource definitions (internal storage
shape).

## register_resource

    $server->register_resource(
        uri      => 'file:///notes.txt',
        name     => 'notes',
        mimeType => 'text/plain',
        code     => sub {
            my ($uri) = @_;
            return "some notes";
        },
    );

Registers a resource. Expects `uri` and `name`, an optional `mimeType`,
`description` and `title`, and a `code` reference invoked with the
resource URI when the resource is read.

## list_resources

    my $resources = $server->list_resources->get;

Returns a `Future` that resolves to the ArrayRef of resource definitions
in wire shape (`uri`, `name`, and the optional `mimeType`, `description`,
`title`).

## read_resource

    my $result = $server->read_resource($uri)->get;
    # { contents => [ { uri => $uri, text => '...' } ] }

Returns a `Future` that resolves to a hashref of the shape `{ contents =>
[ { uri, mimeType?, text } ] }`. Looks up `$uri` in the resource registry
and invokes its `code` reference with the URI. A resource whose `code`
returns a hashref already carrying a `contents` arrayref is passed through
verbatim; any other return value is stringified into a single text
content block tagged with the resource's `mimeType`.

## prompts

    my $prompts = $server->prompts;

Returns the ArrayRef of registered prompt definitions (internal storage
shape).

## register_prompt

    $server->register_prompt(
        name => 'greeting',
        code => sub {
            my ($arguments) = @_;
            return "Hello, $arguments->{name}!";
        },
    );

Registers a prompt. Expects `name`, optional `title`, `description` and an
`arguments` ArrayRef, and a `code` reference invoked with the request
arguments when the prompt is fetched.

## list_prompts

    my $prompts = $server->list_prompts->get;

Returns a `Future` that resolves to the ArrayRef of prompt definitions in
wire shape (`name`, `arguments`, and the optional `title`, `description`).

## get_prompt

    my $result = $server->get_prompt($name, $arguments)->get;

Returns a `Future` that resolves to a hashref of the shape `{
description?, messages => [ { role, content => { type => "text", text }
} ] }`. Looks up `$name` in the prompt registry and invokes its `code`
reference with `$arguments`. A prompt whose `code` returns a hashref
already carrying a `messages` arrayref is passed through verbatim; any
other return value is stringified into a single `user` text message.

## handle

    my $response = $server->handle($request);

The JSON-RPC dispatch entry point. `$request` is a single decoded
JSON-RPC request or notification hashref (`jsonrpc`, `method`, and
optionally `id` and `params`); transports decode wire JSON before calling
this and encode whatever it returns.

`handle` is synchronous, not a `Future`-returning method: it calls `->get`
internally on the `Future`s from `discover`, `list_tools`, `call_tool`,
`list_resources`, `read_resource`, `list_prompts` and `get_prompt`, and
hands back a plain result.

If `$request` has a defined `id` key (`0` or `''` counts; only an absent
key or a JSON `null` id does not), `handle` returns a JSON-RPC response or
error hashref. Otherwise `$request` is treated as a notification: `_meta`
is never validated, nothing is dispatched, and `handle` returns `undef`
(the Stdio transport writes nothing back for `undef`).

Malformed input is rejected before any of that, regardless of `id`: a
`$request` that is not a hashref returns `-32700`; a hashref with no
defined `method` returns `-32600`.

For every request that does carry an `id`, the per-request `_meta`
contract described above is validated before dispatch, then `method` is
mapped to `server/discover` → `discover`, `tools/list` → `list_tools`,
`tools/call` → `call_tool` (unregistered tool name: `-32602`),
`resources/list` → `list_resources`, `resources/read` → `read_resource`
(unregistered URI: `-32602`), `prompts/list` → `list_prompts`, or
`prompts/get` → `get_prompt` (unregistered name: `-32602`). Any other
method — including the previous revision's `initialize`, `ping` and
`notifications/initialized` — returns `-32601`, but only when sent with
an `id`; the same method names sent as notifications (no `id`) are
silently no-op'd like any other notification and never reach the dispatch
or the `-32601` check.

The full set of JSON-RPC error codes `handle` itself can produce:
`-32700`, `-32600`, `-32601`, `-32602`, `-32022`. `-32020` is raised by
`Net::Async::MCP::Server::Transport::StreamableHTTP`, not by `handle`.

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

`handle_requests` reads through an `IO::Async::Stream` registered as a
child of the transport and waits on a `Future` for EOF, the spec's
graceful-shutdown signal. It blocks the caller, but not the event loop:
other notifiers in the same loop — timers, other transports — keep
running while requests are being read. If the transport isn't a member of
a loop yet, one is created and the transport added to it. Requests are
read from `read_handle` and responses written to `write_handle`,
defaulting to `\*STDIN` and `\*STDOUT`. See
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
`tools/call`, `resources/read`, `prompts/get`), and `Mcp-Param-{Name}`
for any tool argument annotated with `x-mcp-header: "{Name}"` in its
`inputSchema`. These header checks apply only to requests that carry an
`id` — a notification skips them and goes straight to `handle()`. Any
header/body divergence returns JSON-RPC `-32020 HeaderMismatch`. The
transport answers each request as `application/json` (default) or as
`text/event-stream` when the client's `Accept` header asks for it: the
JSON-RPC response is emitted as a single SSE event and the stream is then
closed.

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

This is free software; you can redistribute it and/or modify it under the
same terms as the Perl 5 programming language system itself — the GNU
General Public License, Version 1 (or, at your option, any later version),
or the Artistic License.

See [https://raudssus.de/](https://raudssus.de/) for more about the author.
