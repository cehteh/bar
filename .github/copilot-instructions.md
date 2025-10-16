# Bar - BAsh Rulez AI Coding Instructions

Bar is a rule-based command runner implementing a declarative workflow system for bash. It's similar to make/just but with unique features like rule caching, conditional evaluation, git hook integration, and background job scheduling.

## Architecture Overview

**Core Components:**
- `bar` - Main script with module loading and rule evaluation
- `Bar.d/` - Module directory containing rule libraries and tools support
- `Barf` - Project rule file (like Makefile but for bash rules)
- Rule engine with dependency resolution, caching, and conditional execution

**Key Modules:**
- `rule_lib` - Core rule definition and evaluation engine
- `std_lib` - General utility functions (always loaded)
- `*_rules` modules - Auto-loaded rule hooks for tools (cargo, git, etc.)
- Tool modules (`cargo`, `git`, `shellcheck`) - Tool-specific functionality

## Rule System Architecture

Rules are cached, pure functions with dependencies. The syntax: `rule [name:] [deps..] [-- body]`

**Rule Types:**
- Conjunctive (default): All clauses must succeed
- Disjunctive (`--disjunct`): First successful clause wins
- Conditional deps: `dep?` (skip if fails), `!dep` (expect failure), `dep~` (unconditional)

**Special Rules:** `SETUP`, `PREPROCESS`, `MAIN`, `POSTPROCESS`, `CLEANUP`

## Development Workflows

**Testing:**
```bash
./bar tests                    # Run all tests in tests/
./bar testdir_enter           # Create isolated test environment  
./bar test_staged             # Test staged changes in testdir
```

**Key Commands:**
```bash
./bar                         # Run MAIN rule (lints tests doc build)
./bar fastchk                 # Fast checks based on git branch
./bar activate                # Install git hooks
./bar help <module>           # Module documentation
./bar --debug <rule>          # Debug rule execution
```

**Module Loading:**
- `*_lib` - Manual load with `require modulename_lib`
- `*_rules` - Auto-loaded at startup to hook into std rules
- Simple names (no underscore) - Lazy loaded by rule name prefix

## Key Patterns

**Hook Pattern:** Tool-specific `*_rules` modules add clauses to standard rules:
```bash
# In cargo_rules
rule build_libs: is_cargo_project? 'cargo build --lib'
rule lint_sources: is_cargo_project? cargo_lint??
```

**Conditional Rules:** Use branch-specific logic:
```bash
rule fastchk: --conclusive is_git_release_branch? lints tests doc
rule fastchk: --conclusive is_git_feature_branch? lint_sources
```

**Background Jobs:** Use memodb for expensive operations:
```bash
rule main_commit: 'memodb_schedule audit' 'memodb_schedule tests'
rule main_commit_results: 'memodb_result audit' 'memodb_result tests'
```

## Documentation Convention

Use `##` for user-facing docs, `###` for file headers:
```bash
function name ## [--opt] <required> [optional..] - Description
## [--opt] - Option description
## <required> - Required parameter
```

**Completion Prototypes:** Define at column 0:
```bash
# prototype: "toolchain" = "ext cargo_toolchain_complete"
# prototype: "gitargs" = "extcomp git"
```

## Integration Points

**Git Hooks:** Rules triggered by git operations (pre-commit, etc.)
**Tool Integration:** Modules detect and integrate with cargo, git, shellcheck, etc.
**Completion System:** `contrib/bar_complete` provides bash completion with parameter-aware completion

## Testing Infrastructure

- Tests in `tests/test_*.sh` - Run with `./bar tests`
- Isolated testdir system - Creates clean environments from git trees
- Background job testing via memodb
- Integration tests for completion system

## Project-Specific Notes

- Self-hosting: Bar maintains itself using Bar (see `Barf` vs `Barf.default`)
- License checking: No DBG statements allowed in production
- Module system is self-contained (no external paths)
- Extensive bash completion with parameter introspection

## Module System

### Module Types & Loading

1. **`*_lib`** - Function libraries, manually loaded with `require name_lib`
2. **`*_rules`** - Rule definitions that hook into standard targets, auto-loaded at startup  
3. **Single-word modules** - Lazy-loaded on demand when rules like `module_action` are called

### Module Conventions

- **std_lib, rule_lib** - Always loaded, provide core functionality
- **std_rules** - Defines extensible standard targets (`build`, `test`, `lints`, etc.)
- **Tool-specific modules** - e.g., `cargo_rules` hooks Rust support into standard targets
- **Feature modules** - e.g., `git_rules` provides git hook integration, `release` handles versioning

### Auto-loading Pattern

Rule names trigger module loading: `try_cargo_check` → loads `cargo` module by stripping `try_` prefix and taking first word before `_`.

## Standard Workflow Integration

### Standard Rule Targets

All modules hook into these extensible targets in `std_rules`:
- **`build`** → `build_libs` + `build_bins`  
- **`tests`** → `test_units` + `test_integrations`
- **`lints`** → `lint_sources` + `lint_docs`
- **`all`** → `build` + `doc`

### Git Hook Integration

Execution flow for git hooks:
1. `SETUP` - Creates isolated testdir from git index
2. `PREPROCESS` - Prepares environment  
3. **Main rule** - Branch-specific logic (see `Barf.default` branch patterns)
4. `POSTPROCESS` - Cleanup tasks
5. `CLEANUP` - Always runs (in reverse order)

Enable with: `./bar activate` (runs `githook_enable` for configured hooks)

## Development Workflows

### Essential Commands

```bash
./bar                    # Run MAIN rule (typically lints + tests + build)
./bar fastchk           # Branch-aware quick checks
./bar watch             # Continuous testing with file watcher
./bar activate          # Enable git hooks
./bar help              # Extract documentation from modules
./bar --debug rule      # Run with verbose debugging
```

### Testing & Background Processing

- **testdir system** - Creates isolated test directories from git trees
- **memodb** - Persistent memoization allowing background command execution
- **Background processing** - `memodb_schedule cmd` + later `memodb_result cmd`

### Branch-aware Development (Barf.default)

Different rules fire based on git branch patterns:
- **feature branches** - Fast lints + unit tests
- **devel branches** - Full test suite  
- **main/release** - Complete validation including audit, docs, benchmarks

## Key Patterns for Extension

### Adding Tool Support

1. Create `tool_rules` module hooking into std_rules:
```bash
rule lint_sources: is_tool_project? tool_lint
rule build_libs: is_tool_project? tool_build  
```

2. Create `tool` module with implementation functions
3. Add detection function `is_tool_project` checking for tool manifest files

### Rule Definition Patterns

```bash
# Multi-clause rule (all must pass)
rule complex_task: prep_step
rule complex_task: actual_work  
rule complex_task: cleanup_step

# Disjunctive rule (first success wins)
rule --disjunct fallback_task: preferred_method
rule fallback_task: fallback_method

# Branch-conditional rules
rule pre-commit: is_git_feature_branch? quick_checks
rule pre-commit: is_git_main_branch? full_validation
```

### Module Documentation

Use `##` comments for auto-extracted documentation:

```bash
function my_function ## <arg> - Description
{
    ## Additional documentation lines
    ## More details about usage
}

## Rule documentation  
rule my_rule: deps -- body
```

## Configuration Files

- **`Barf.default`** - Template showing branch-aware git hook integration
- **`example`** - Comprehensive syntax examples and test cases  
- **Project `Barf`** - Customize by extending/overriding standard rules

The architecture prioritizes composability - most functionality comes from modules hooking into standard extension points rather than monolithic implementations.