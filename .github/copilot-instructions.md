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
- Study `README` when you are tasked to write bar rules.

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

# Tasks

## Rewrite the completion engine in contrib/bar_complete 

The new implementation should be more streamlined and regular.

general instructions:
- Focus on rewriting the engine, but if necessary you can touch all other functions and refine them for the tasks.
- make a plan for the rewrite, write that to a file, execute it step by step, confirm every step is working with tests
- in the current engine we implemented some caching. the rewrite needs that too, but it should be readded as the last step.
- When any existing test/completion breaks, consider the lack of a prototype definiton, predicate, completer (in that order). If neceessary implement those (also consider that order, new completers should be only implemented when the completion cant be composed by existing ones) 

observations:
- parameter specifications have the following syntax
    - literal
        - anything not inside `<>` or `[]` is considered literal, when one wants to have literals inside <> or [] one has to define a literal prototype for that `# prototype: "lit" = "literal lit"`, exception here is that `--` and `-` prefixes make the parameter literal even inside <> and []
        - punctuation is literal except prefix `--` and `-` and the suffix `..` used for repetions and '|' which is the alternatives operator
    - <proto>
        - Mandatory parameter (prototype)
        - the proto may be prefixed or suffixed by literal punctuation which then has a higher precedence than | or ..  ( [foo:..]  is many 'foo:' not foo with many colons) 
            - this can should be implented by some hidden grouping.
    - [proto]
        - Optional parameter (prototype)
    - group
        - anything inside <> or [] or a hidden group
            - groups can be nested ([foo [[bar] baz]])
    - param
        - is either a literal, proto or group
    - proto.. or group..
        - a `..` suffix means multiple occurences
            - <proto..> or <proto>..
                - One or more occurrences
            - [proto..] or [proto]..
                - Zero or more occurrences
    - param|param
        - the `|` is used for alternatives, can be used multiple times `--foo|--bar|--baz`
        - can be outside groups (--foo|--bar) or inside ([this|that])
        - has a lower precedence than `..` (<foo|bar..> is either one foo or many bar)
    - --flag or -f
        - Literal flag / short flag
        - stays literal even inside <> and []
- The engine has the protos array which can be an aribitrary list of parameters specs.



Completion process:
I sketch here a completion algorithm. before you start, check it for correctness and soundness. ask back if anything is not clear, correct any mistakes. Are there any corner cases and unclear specifications?

- make a detailed plan on how you implement this algorithm
- if possiblle and sound try to make it as minimal as possible, dont add things that are not necessary.

- collect all prototypes for the current position. This means all alternative prototypes in the protos array up to the first non alternative part
    - since each entry in the protos array can be a nested group, this needs to be handled as well:
        `protos=("[[--verbose] foo [bar|baz]]" "--flag|--other" "<later>")` (proto_idx=0)
        will collect '--verbose', foo, '--flag', '--other'
        - remember somewhere (another array) for each collected item from what proto position it came: (0 0 1 1)
        - the --flags are literal
        - foo is a prototype and eventually resolves to a completer which returns a list of possible completions.
        - [bar|baz] won't be reached because the foo before it is mandatory.
        - <later> won't be reached because "--flag|--other" are non optional alternatives
        - write a test for this, testing the good case, failures and corner cases
    - once the completion is done, we need to calculate how to proceed:
        - set proto_idx to the the index from what the completion came from, then refine that entry:
            - backup the current entry (stack)
            - remove the completed part eg:
                - when the user completed `--verbose` then protos[0] becomes `[foo [bar]]` 
                - when the user completed `foo` then protos[0] becomes `[[bar|baz]]` (or simplified to `[bar|baz]`)
            - when the refined entry becomes empty then we increment proto_idx
            - when the user stepped back we need to restore from the backup we made earlier
                - when that stack becomes empty then decrement proto_pos

- proto lookup rules
    - every prototype eventually calls a completer
    - prototyoes have a 1 level module "module:proto"
    - lookup rules:
        1. prototype for the current module
        2. global prototype
        3. completer function

    example: when a module 'foo' has a `function bar ## <file> - foo:bar`
    then it searches "foo:bar" and then "bar" in the prototype registry,
    when that is not found it checks if a `_bar_complete_comp_file` function exists.
                                                
# COPILOT PLAN AND COMMENTS

- Rewriting `contrib/bar_complete` will require a full grammar-driven parser for parameter specs so we can expand nested groups, repetitions, and literals deterministically before dispatching to completers.
- We must stage the work: (1) design and document the parser/state machine in a plan file, (2) implement the new engine without caching, validating via existing completion tests plus new coverage for nested alternatives, (3) reintroduce caching and ensure no regressions.
- Critical risks: faithfully handling hidden grouping precedence (`..` vs `|`), backward navigation stack mechanics, and ensuring prototype lookup order (`module@proto` → global → function) still works for legacy modules.
- Extra test investments: targeted cases for mixed literal/prototype alternations, nested optional groups, and regression tests for cargo build/test args to prove the new traversal logic is sound.
