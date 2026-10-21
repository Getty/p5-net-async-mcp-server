---
name: mcp-server-core
description: Use when working on Net::Async::MCP::Server — its JSON-RPC dispatch, tool registry, Stdio and StreamableHTTP transports, the known gaps, and the test-gathering traps.
---

# Net::Async::MCP::Server core

An async MCP (Model Context Protocol) *server* base class for `IO::Async`, plus a
Stdio transport and a StreamableHTTP transport. The dispatch seam is
`Net::Async::MCP::Server::handle()` — a plain method that takes a request
hashref and returns a response hashref, which is what makes the whole
protocol surface testable in-process.

House conventions live in the shared skills and are not repeated here: module
loading, cpanfile pinning and house style in `getty-perl-core`; `Future`/
`IO::Async` idioms in `perl-io-async-future`; the MCP protocol surface in
`perl-mcp`; POD in `getty-perl-pod`; the release path in
`getty-perl-release-author-getty` and `perl-release-dist-ini`.

## The delegation model — why the main agent delegates

Four roles: `mcp-server-worker` (implement, refactor, debug),
`mcp-server-test-writer` (tests), `mcp-server-pod-writer` (POD + `README.md`),
`mcp-server-release-manager` (commit, `Changes`, card → done, pre-release
audit). All four get their skills force-loaded via `briefing.skills`. The
orchestrating main agent gets **no briefing** — it coordinates, inspects, plans,
reviews diffs, runs tests and edits non-behavioral docs, and delegates
anything behavior-relevant. Reason: only the briefed agents see the
protocol invariants and the known gaps below in context; an unbriefed hand
inside `lib/` would break exactly those. When in doubt, delegate.

Behavior-relevant = the JSON-RPC dispatch and error mapping in `handle()`, the
tool registry and `call_tool` semantics, `initialize` and capability
negotiation, the Stdio and StreamableHTTP transports, Future and error
semantics, tests, performance. Pure prose docs, POD wording and `Changes`
notes are not.

## Module map

- `Net::Async::MCP::Server` — the base class: `initialize`, `list_tools`,
  `call_tool`, `discover` and the rest are `async sub`s; `handle()` dispatches
  a JSON-RPC request and maps errors onto JSON-RPC error codes.
- `Net::Async::MCP::Server::Transport::Stdio` — line-oriented transport over
  `STDIN`/`STDOUT`.
- `Net::Async::MCP::Server::Transport::StreamableHTTP` — PSGI entry point
  (`to_app`) plus a blocking `listen` convenience wrapper.
- The tool registry is per-instance: tools are registered on the server object
  and read back by `list_tools` / dispatched by `call_tool`.

## Known gaps — scope decisions, not obvious bugs

These are decided by the maintainer. Name them, propose, wait — do not
silently "fix" them:

- **`StreamableHTTP->listen` blocks the event loop** (k17, k41). `to_app` is
  the async-friendly PSGI entry point; `listen` runs `HTTP::Server::PSGI`'s
  own accept loop. A native `IO::Async::Listener` bring-up is open as k41.
- **The Stdio response write is a blocking `print`** (k18). Reading is
  stream-based; the write side is not routed through the `IO::Async::Stream`.
- **`handle()` is synchronous and calls `->get` on the `async sub`s**
  (`discover`, `list_tools`, `call_tool`, ...). A `call_tool` that waits on I/O
  blocks the server, and there is no server→client push channel (k24): no
  subscriptions delivery, logging or progress notifications.
- **No pagination** (k25): list methods return one complete page, no
  `cursor`/`nextCursor`.
- **An empty `origin_allow` allows any Origin** (decided in k35: status quo,
  documented as a DNS-rebinding risk in the POD).

## Hazards — what actually goes wrong here

- **An untracked test file is silently skipped.** `[@Author::GETTY]` gathers via
  `Git::GatherDir`, so a new `t/*.t` that was never `git add`ed does not reach
  the build — `dzil test` then reports a green run that never executed it.
  `git add -N` the file as soon as it exists.
- **This dist implements MCP itself.** It does not use SRI's `MCP`/`MCP::Server`
  distribution; the `perl-mcp` skill describes that one and is protocol
  reference only. Don't "reuse" an API from it that this code has never
  called.
- **The sibling client dist is a separate repo.** `Net::Async::MCP`
  (`~/dev/p5-net-async-mcp`) is the client half these two are meant to
  interoperate with. Read it to check wire format; never edit it from here.
- **The dispatch path is not actually concurrent.** `handle()` calls `->get` on
  the `async sub`s and the Stdio response write is a blocking `print` (k18).
  Treat any claim of concurrency here as false until that changes.
- **Every `lib/*.pm` carries its own `our $VERSION`** and `dist.ini` sets no
  `version_finder`. That is correct for this dist: `version_finder` only
  defaults to `:MainModule` under `no_cpan`, and a file without `$VERSION`
  ships versionless. Don't "clean this up" into a single main-module version,
  and don't copy the sibling client dist's `version_finder = :MainModule` line
  over. A new `lib/*.pm` needs its own `$VERSION`, and one package per file —
  only the *first* `our $VERSION` in a file is rewritten at release.
- **`README.md` is hand-maintained, not generated.** The bundle excludes it
  from the tarball (`include_readme` is off) and generates a plain-text
  `README` from POD at build time instead, so it drifts silently. When POD
  changes, update `README.md` in the same pass or say explicitly that you
  left it.

## Tests

`prove -l t/` — the whole suite, no network and no spawned child process
needed. `dzil test` builds first and is the closer-to-release check.

A test drives `$server->handle($request)` on an in-memory request hashref plus
the tool registry — never a real MCP client on the other end of a pipe. The
Stdio transport cannot be driven in-process (it reads `STDIN` in a blocking
loop and prints to `STDOUT`); don't invent a harness for it on your own
initiative — say so and ask.
