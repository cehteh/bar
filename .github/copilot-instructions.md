# Bar - BAsh Rulez AI Coding Instructions

Bar is a rule-based command runner implementing a declarative workflow system for bash. It resembles make/just but adds rule caching, conditional evaluation, git hook integration, and background job scheduling.

## Immediate Checklist

- Run `./bar` before every commit; it validates lints, tests, docs, and rebuilds the README. Fix any reported issues first.
- Only commit the README when you meaningfully update documentation or finish a task for review.
- Keep `.github/copilot-instructions.md` current as new guardrails emerge; remove outdated guidance promptly.
- Ensure every `tests/test_*.sh` script is executable and that `./bar tests` passes cleanly.

## Development Workflow

- Clarify the requirement, then inspect existing modules for comparable patterns.
- Extend existing rules and hooks when possible instead of writing bespoke scripts.
- Run shellcheck on touched shell scripts (`shellcheck <file>` or `./bar lints`) and resolve findings.
- Add or update automated tests covering success, failure, and edge cases for new behaviour.
- Update `Bar.d/help` whenever behaviour or CLI contracts change, then run `./bar doc` to regenerate the README when appropriate.
- when changing something to figure out if it works/fixes something and this was not the case, then undo those changes before committing. 
- Stage work logically and write concise commit messages that capture rationale and testing.

## Code Quality and Testing

- `./bar` orchestrates the core pipeline; it must succeed prior to committing.
- `./bar tests` executes the full suite defined in Barf; run it before submission.
- The `shellcheckrc` configuration governs linting expectations; follow it for consistent shellcheck runs.
- New tests belong in `tests/` with the `test_*.sh` naming convention and executable bit set.
- Reuse existing helpers such as the `testdir` system for isolated environments instead of custom scaffolding.

## Documentation

- `Bar.d/help` is the single source of user-facing documentation; avoid ad-hoc docs elsewhere.
- Regenerate the README with `./bar doc` after material help changes and include it in commits when content meaningfully changes.
- Headings: use three leading hashes for file-level descriptions and two leading hashes for individual rules or functions inside help modules.
- Follow the documented parameter grammar: `<param>` for required values, `[param]` for optional, `..` for repetition, `a|b` for alternatives, and literal tokens for fixed strings. Prototypes bind specific completers.

## Completion System Reference

- `contrib/bar_complete` implements parameter-aware completion with module tracking, prototype registry, predicate filtering, and result caching.
- Register prototypes via `# prototype: "name" = "spec"` comments or `module_prototype_complete` functions; specs map to built-ins like `file`, `file existing`, `ext func`, or `extcomp command`.
- Resolver order prefers `module@proto`, then `func@proto`, falling back to global `proto` definitions.
- Literal punctuation in prototypes (such as `[+toolchain]` or `<rule:>`) is preserved; completions inject the literal when the user has not typed it yet.
- External completers reuse the invoking command (for example `./bar --bare ...`) and cache results in `_bar_completion_extcomplete_cache` for efficiency.

## Architecture Overview

- `bar` - main script handling module loading and rule evaluation.
- `Bar.d/` - module directory with rule libraries and tooling support.
- `Barf` - project rule file (Makefile analogue) defining orchestration.
- Rule engine provides dependency graphs, caching, conditional execution, and background scheduling.

## Rule System Essentials

- Rules use the syntax `rule [name:] [deps..] [-- body]` and behave as cached pure functions.
- Default rules are conjunctive; add `--disjunct` to stop at the first succeeding clause.
- Dependency modifiers: `dep?` skips if the dependency fails, `!dep` expects failure, and `dep~` forces execution.
- Lifecycle hooks include `SETUP`, `PREPROCESS`, `MAIN`, `POSTPROCESS`, and `CLEANUP`.

## Module System

- `*_lib` modules expose function libraries; load them explicitly with `require name_lib`.
- `*_rules` modules hook into standard targets and auto-load at startup.
- Single-word modules load lazily when their rule prefix is invoked.
- Completion helpers follow `module_prototype_complete` naming with lowercase alphanumeric segments.

## Standard Integration Points

- Standard targets in `std_rules`: `build` (via `build_libs` and `build_bins`), `tests` (`test_units`, `test_integrations`), `lints` (`lint_sources`, `lint_docs`), and `all` (`build`, `doc`).
- Git hook execution: `SETUP` → `PREPROCESS` → branch-specific main rule → `POSTPROCESS` → `CLEANUP`; enable hooks with `./bar activate`.
- Branch defaults (`Barf.default`): feature branches run fast checks, devel branches run full tests, main/release branches perform exhaustive validation.

## Development Commands

- `./bar` - run the full pipeline (lints, tests, docs, build).
- `./bar fastchk` - execute quick, branch-aware checks.
- `./bar watch` - start the file watcher for continuous testing.
- `./bar activate` - install configured git hooks.
- `./bar help <module>` - render module documentation.
- `./bar --debug <rule>` - run a rule with verbose diagnostics.
- `./bar testdir_enter` / `./bar test_staged` - set up isolated test directories.

## Testing Infrastructure

- `tests/test_*.sh` scripts validate functionality; ensure they use repository-relative sourcing via the `SCRIPT_DIR` and `REPO_ROOT` pattern.
- The `testdir` system creates clean environments from git trees for reproducible runs.
- `memodb` enables background job scheduling; pair `memodb_schedule` with `memodb_result` during async testing scenarios.
- Completion features have dedicated integration tests under `tests/`.

## Project Notes

- The project is self-hosting; Bar manages its own workflows through Bar rules.
- Production code must not contain `DBG` statements.
- The module system operates entirely within the repository without external path assumptions.
- Bash completion relies on parameter prototypes and should remain consistent across modules.
- `is_cargo_toolchain_available` must not depend on `rustup`; many environments ship only distro `cargo`.

## Key Patterns for Extension

- Add tool support by creating `<tool>_rules` modules that extend standard targets and paired `<tool>` modules containing implementations plus detection helpers (for example `is_tool_project`).
- Compose workflows with multi-clause rules or disjunctive fallbacks instead of large monolithic scripts.
- Encode branch-aware or conditional behaviour using built-in predicates within rule clauses.

## Patterns and Examples

```
function my_function ## <required> [optional] - Summary
{
    ## <required> - Required parameter description
    ## [optional] - Optional parameter description
}

## <arg> [options..] - Rule summary
rule my_rule:
    ## <arg> - Explanation
    ## [options..] - Option details

function mymodule_mytype_complete ## Emit completions for mytype
{
    echo "option1"
    echo "option2"
}
```

## Project Structure

- `bar` - entrypoint script.
- `Bar.d/` - modules for libraries, rules, and tooling.
- `Bar.d/help` - authoritative documentation source.
- `contrib/bar_complete` - bash completion implementation.
- `tests/` - integration and regression suite.

## Git History Guidance

- Store implementation notes and context in commit messages rather than standalone files.
- Keep messages brief but informative, describing behaviour changes, rationale, and tests executed.

## Configuration and References

- `Barf.default` - template showcasing branch-aware orchestration.
- `example/` - comprehensive syntax demonstrations and fixtures.
- `Pleasef.default` - please integration example.
- Use `./bar help` and module sources in `Bar.d/` as primary references when extending functionality.
