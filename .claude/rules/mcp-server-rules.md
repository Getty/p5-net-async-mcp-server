# Net::Async::MCP::Server House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Async MCP server base class, with Stdio and Streamable HTTP transports. Read first: the seam
you're touching — the JSON-RPC dispatch in `handle()`, the tool registry, the Stdio transport
loop.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-server-worker` (default) |
| Write/extend tests | `mcp-server-test-writer` |
| POD in the house format (`=method`/`=attr`) + README.md | `mcp-server-pod-writer` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-server-release-manager` |
| Read-only research, audit, gap analysis | `mcp-server-worker` ("read-only, change nothing") |

Behavior-relevant = the JSON-RPC dispatch and error mapping in `handle()`, the tool registry
and `call_tool` semantics, `initialize` / capability negotiation, the Stdio transport loop,
Future and error semantics, tests, performance. Pure prose docs, POD wording, and `Changes`
notes are not. Why the lock bites here: only the `mcp-server-*` agents see the protocol
internals and the known gaps — an unbriefed hand inside `lib/` breaks exactly the invariants
they must hold.

## Hazards

Short form; the full traps and their reasons live in skill `mcp-server-core`.

- **An untracked test file is silently skipped** — `Git::GatherDir` leaves it out of the
  build, so `dzil test` reports a false green; "tests pass" is wrong if a new test file was
  never gathered. `git add -N` it as soon as it exists.
- **This dist implements MCP itself** — it does not use SRI's `MCP`/`MCP::Server` dist; the
  `perl-mcp` skill is protocol reference only. Don't "reuse" an API from it that this code
  never called.
- **The sibling client dist is a separate repo** — `Net::Async::MCP` (`~/dev/p5-net-async-mcp`)
  is the client half; read it to check the wire format, never edit it from here.
- **The dispatch path is not actually concurrent** — `handle()` calls `->get` on the
  `async sub`s and the Stdio response write is a blocking `print` (k18). Treat any claim of
  concurrency here as false until that changes.

## Perl / async / MCP specifics — reference, don't restate

The architecture, known gaps and protocol invariants live in skill `mcp-server-core`; module
loading, cpanfile pinning and house style in `getty-perl-core`; Async/Future lifecycle in
`perl-io-async-future`; the MCP protocol surface in `perl-mcp`; release conventions in
`getty-perl-release-author-getty` + `perl-release-dist-ini` (all force-loaded for
`mcp-server-*` agents).
