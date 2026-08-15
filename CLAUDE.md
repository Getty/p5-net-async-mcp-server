# CLAUDE.md

## Distribution

Net::Async::MCP::Server — async MCP (Model Context Protocol) **server** base class for
Perl, built on IO::Async and Future::AsyncAwait. Subclasses register tools; the base
class handles the protocol handshake and JSON-RPC request routing.

Uses Dist::Zilla with `[@Author::GETTY]`. Released: `0.001`; the tree carries `0.002`
(repo always runs one ahead of CPAN).

**This is a standalone implementation** — it does not build on SRI's `MCP` /
`MCP::Server` distribution. The sibling dist `Net::Async::MCP`
(`~/dev/perl/p5-net-async-mcp`) is the *client* half the two are meant to interoperate
with; it lives in its own repo and is never edited from here.

## Structure

- `lib/Net/Async/MCP/Server.pm` — the server (`IO::Async::Notifier`): `initialize` and
  capability negotiation, the tool registry (`register_tool` / `list_tools` /
  `call_tool`), and `handle()`, the JSON-RPC dispatch that maps
  `initialize` · `tools/list` · `tools/call` · `ping` · `notifications/initialized` to
  responses or errors.
- `lib/Net/Async/MCP/Server/Transport/Stdio.pm` — newline-delimited JSON-RPC over
  stdin/stdout.

Each `lib/*.pm` carries its own `our $VERSION`, and `dist.ini` sets no `version_finder`
— that is the house convention for a CPAN dist (`:MainModule` is the `no_cpan` default).
A new module needs its own `$VERSION`, and one package per file: only the first
`our $VERSION` in a file is rewritten at release time.

## Dependencies

**IO::Async** (base class / event loop) · **Future** + **Future::AsyncAwait** (the
`async sub` methods) · **JSON::MaybeXS** (wire encoding) · **Test2::V0** on test.

## Testing

```bash
prove -l t/     # whole suite — no network, no spawned process
dzil test       # builds first; the closer-to-release check
```

**A new test file must be `git add`ed before `dzil test` runs it.** The bundle gathers
via `Git::GatherDir`, so an untracked `t/*.t` is silently left out of the build —
`dzil test` then reports a green run that never executed the new file. Use
`git add -N t/NN-name.t` (intent-to-add, no commit) as soon as the file exists.

`README.md` is hand-maintained: `[@Author::GETTY]` excludes it from the tarball
(`include_readme` is off) and ships a POD-generated plain `README` instead. It drifts
silently — it currently still states version 0.001.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle and lane are in `.claude/rules/mcp-server-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-server-worker` (default) |
| Write/extend tests | `mcp-server-test-writer` |
| POD in the house format + README.md | `mcp-server-pod-writer` |
| Pre-release audit | `mcp-server-release-checker` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`,
hardlink-shared with the other Perl repos.

Known gaps in the current implementation — flag before "fixing" — are listed in
`.claude/agents/mcp-server-worker.md`.

## PodWeaver

`[@Author::GETTY]` conventions: inline `=method`, `=attr`, `=seealso`. No manual
NAME/VERSION/AUTHOR sections. Full rules: skill `perl-release-author-getty`.
