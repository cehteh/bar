# AGENTS.md

Bar is a rule-based command runner written in bash: a declarative workflow system that resembles
make/just and adds rule caching, conditional evaluation, git hooks and background job scheduling.

This file is the repository's agent instruction and its only copy — there is no `.github/` and no
tool-specific variant to keep in sync. Keep it current as guardrails emerge, and keep it short: it
is read on every turn. Architecture, examples and the full command reference are in `README`, which
`Bar.d/help` generates.

## The gate

- `./bar` before every commit: build, lints, docs and the `README` rebuild. A red gate is never
  committed.
- `./bar tests` for the full suite, before handing work over. `./bar agent` runs lints and tests.
- `./bar check <target>..` prints the verdict with bounded, line-numbered evidence and the log path;
  `./bar log <target>` reads that log back. Prefer them over a full run.
- `./bar lints` alone when only shellcheck and the repository checks are in question; `shellcheckrc`
  is the configuration they follow.
- A change made to find out whether it fixes something, which did not, is reverted before the commit.

## Tests

- `tests/test_*.sh`, executable, sourcing the repository through the `SCRIPT_DIR`/`REPO_ROOT` pair.
- New behaviour gets a test; **every bug gets a reproducer in `tests/` before the fix**, and the
  reproducer must fail without the fix.
- Use the `testdir` system for an isolated environment instead of bespoke scaffolding.
- A new test is registered in `Barf`: `rule tests: test_<name>` and
  `rule test_<name>: -- tests/test_<name>.sh`.

## Documentation

- `Bar.d/help` is the single source of user-facing documentation; `./bar doc` renders `README` from
  it. Do not write prose docs elsewhere — implementation notes belong in the commit message.
- Three leading hashes for a file-level description, two for a rule or function inside a help module.
- Parameter grammar: `<param>` required, `[param]` optional, `..` repetition, `a|b` alternatives,
  everything else literal. A prototype binds a completer; the description follows ` - ` on the same
  `##` line, never inside the prototype slot.
- Read `Bar.d/help` (or the generated `README`) before writing a rule.

## Rules and modules

- `rule [name:] [deps..] -- body`; a rule is a cached pure function of its inputs.
- Default rules are conjunctive; `--disjunct` stops at the first succeeding clause.
- Dependency modifiers: `dep?` skips a dependency that fails, `!dep` expects it to fail, `dep~`
  forces execution.
- Lifecycle hooks: `SETUP`, `PREPROCESS`, `MAIN`, `POSTPROCESS`, `CLEANUP`.
- `*_lib` modules are libraries and load explicitly (`require name_lib`); `*_rules` modules hook the
  standard targets and load at startup; a single-word module loads lazily when its rule prefix is
  invoked.
- Extend an existing rule or hook before writing a bespoke script, and compose multi-clause rules
  instead of one large script.
- A helper carries `# helper: <name> | <purpose> | <invocation> | <output shape>` above it; `lints`
  runs `helpers_check`, and a helper without its declaration fails the gate.

## Layout

`bar` entrypoint · `Bar.d/` modules · `Barf` project rules · `tests/` · `contrib/bar_complete` ·
`example/` fixtures · `Barf.default` a template. Production code carries no `DBG` statements, and no
tracked file carries host-local detail (paths, identities, aliases, hostnames).

## Radicle: merge and close without asking again

The default for an agent is "prepare the change, then ask". The three rules below override it; they
are standing instructions for this repository, not a permission for one turn.

1. **Accepted patch, and you are a delegate.** A delegate accepted the *head* revision of a patch
   and the identity you act as is a delegate of the repository: run `./bar rad_merge_accepted_prs`.
   It fetches `rad`, merges every accepted head into its target branch and pushes that branch to
   canonical itself. Do not ask for confirmation, and do not merge by hand.
2. **Accepted patch that a trusted identity assigned to you.** The same: the assignment is the
   mandate for that patch. Canonical writes are delegate-only, so where the identity is not a
   delegate the helper refuses — run it with `--dry-run`, report the readiness, and say the push is
   not ours.
3. **Rejected patch.** A delegate rejected the head revision: close the linked issue —
   `rad issue state --closed <issue>`, and the label `rejected` where the identity may write labels
   (propose it as `*label:rejected` otherwise, and say it is the maintainer's to set) — then post
   one comment on the patch saying the review closed it. Leave the patch itself as it stands: an
   agent never archives or deletes one, and never reopens the issue on its own.

An acceptance counts only for the revision it names, and only while it is the newest op of the
chain: a review list cannot say which revision a verdict belongs to, and an acceptance posted before
a later comment or revision is stale. `rad_merge_accepted_prs` reads that off the patch's own chain
and reports the reason instead of acting on a stale acceptance.
