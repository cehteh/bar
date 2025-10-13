# Bar Parameter Completion

This document describes the parameter completion system for Bar.

## Overview

Bar supports intelligent bash completion for rules, functions, and their parameters. The completion system automatically discovers documented rules and functions, extracts their parameter prototypes, and provides context-aware completions.

## Documentation Format

Functions and rules should be documented using a formal parameter syntax:

```bash
function process_file ## <input> [output] - Process a file
{
    ## <input>  - Input file to process
    ## [output] - Optional output file (defaults to stdout)
    ...
}

## <target> [options..] - Build a target
rule build:
```

### Parameter Syntax

- `<param>` - Mandatory parameter
- `[param]` - Optional parameter
- `param..` - One or more occurrences
- `[param..]` - Zero or more occurrences
- `--flag` - Flag option (e.g., `--verbose`)
- `-f` - Short flag option
- `foo|bar` - Alternatives (foo or bar)
- `--` - Standalone delimiter for literal parameters

Parameter identifiers start with an alphabetic character followed by `[[:alnum:]-_]`.

## Generic Completers

The following generic parameter prototypes are supported out of the box:

- `<file>` - File path completion
- `<directory>` - Directory path completion
- `<path>` - Any filesystem path
- `<text>` - Free text (no completions)
- `<number>` - Numeric input (no completions)
- `<rule>` - Existing rule names
- `<command>` - Commands and functions

## Module-Specific Completers

Modules can provide specialized completers using the pattern `<module>_<prototype>_complete`:

```bash
# In Bar.d/cargo
function cargo_toolchain_complete ## List available cargo toolchains
{
    if command -v rustup &>/dev/null; then
        rustup toolchain list 2>/dev/null | sed 's/^/+/'
    fi
}
```

The system automatically discovers and registers these as `module@prototype` completers.

## Registry System

The completion registry maps parameter prototypes to completion functions:

- `registry["file"]` → `_bar_complete_file`
- `registry["cargo@toolchain"]` → `_bar_extcomplete cargo_toolchain_complete`

### Hierarchical Lookup

When completing, the system tries:
1. Function-specific: `foo@input`
2. Global: `input`
3. Default: text completion

## Examples

See `tests/test_barf` and Bar.d modules for examples.

Run tests: `cd tests && ./test_completion.sh`
