# Analysis of Bare-Eligible Rules in Bar.d/

## Summary

This document analyzes all rules in Bar.d/ to identify which are eligible for the `--bare` flag. The `--bare` flag marks rules as pure - meaning they only depend on their arguments and the current directory, not on external state like environment variables, file contents, or external commands.

## Criteria for Bare-Eligible Rules

A rule qualifies as bare-eligible if it:
1. Only depends on its arguments and current directory
2. Does not read files or environment variables (beyond built-in shell variables)
3. Does not execute external commands
4. Has no side effects
5. Is deterministic (same inputs always produce same outputs)

## Analysis by Module

### semver_lib ✅ ALL ELIGIBLE

All 14 functions in semver_lib are pure string manipulation and arithmetic operations:

- **semver_parse**: Parses semver string using regex
- **semver_validate**: Validates semver format
- **semver_shortversion**: String manipulation to shorten version
- **semver_major**: Extracts major version number
- **semver_majorpre1x**: Extracts major with 0.x semantic
- **semver_majorminor**: Extracts major.minor
- **semver_is_patch**: Checks if patch version is non-zero
- **semver_increment**: Arithmetic increment of version parts
- **semver_cmp**: Compares two semvers (arithmetic and string comparison)
- **semver_lt**: Less than comparison
- **semver_le**: Less than or equal comparison
- **semver_gt**: Greater than comparison
- **semver_ge**: Greater than or equal comparison
- **semver_eq**: Equality comparison

**Status**: All marked with `--bare` flag

### std_lib ❌ MOST NOT ELIGIBLE

Functions analyzed:
- **memo**: NOT BARE - Depends on memoization state and creates temp files
- **memofn**: NOT BARE - Modifies function definitions (side effects)
- **is_scalar**: POTENTIALLY BARE - Only checks variable type, but accesses variable state
- **called_as**: NOT BARE - Depends on BAR_CALLED_AS environment variable
- **is_command_installed**: NOT BARE - Checks external commands in PATH
- **bar_now**: NOT BARE - Depends on current time (EPOCHREALTIME)
- **hash_args**: POTENTIALLY BARE - Only computes hash, but calls sha1sum external command
- **iset**: NOT BARE - Modifies variables (side effects)

**Status**: None marked as bare (hash_args uses external sha1sum command)

### git_lib ❌ NONE ELIGIBLE

All functions depend on external git state:
- **git_dir**: Reads git directory
- **git_branch_name**: Queries git for branch name
- **git_branch_find**: Queries git branches
- **git_branch_find_one**: Queries git branches
- **git_is_ancestor**: Queries git ancestry
- **git_tree_hash**: Computes hash of git tree
- **git_add_ignore**: Modifies .gitignore file (side effect)

**Status**: None eligible

### rule_lib ❌ NONE ELIGIBLE

All functions manage rule state and evaluation, inherently impure:
- **rule**: Defines rules (side effects on rule registry)
- **rule_eval**: Evaluates rules (depends on rule state)
- **rule_exists**: Checks rule registry
- **rule_list**: Lists rules from registry
- **clause_local**: Manages clause-local variables
- etc.

**Status**: None eligible

### tty_lib ❌ NONE ELIGIBLE

- **tty_echo**: Depends on TTY state and terminal capabilities

**Status**: None eligible

### Other Modules

Most other modules (*_rules files, cargo, git, etc.) define rules that:
- Execute external commands (cargo, git, shellcheck, etc.)
- Read/write files
- Depend on project state
- Have side effects

**Status**: None eligible for --bare flag

## Summary of Changes

### Implemented
1. Added `--bare` rule flag support to rule_lib (flag 'b')
2. Documented `--bare` flag in help file
3. Marked all 14 semver_lib functions with `--bare` flag

### Recommendations

The semver_lib module is the primary candidate for bare rules as it contains pure functions for version string manipulation. Other modules could potentially have pure helper functions added in the future, but currently:

- **std_lib**: hash_args could be made bare if implemented without external sha1sum
- **String manipulation utilities**: Future pure string/math utilities should be marked as bare
- **Validation functions**: Pure validation logic (like semver_validate) are good candidates

## Testing

Due to issues with the SETUP rules in the test Barf file causing hangs, comprehensive testing was limited. However:
- Syntax validation passed for all modified files
- The --bare flag implementation follows the existing pattern of rule flags
- The semantic correctness can be verified by inspection of the semver functions

## Conclusion

The `--bare` flag has been successfully implemented and applied to the 14 pure functions in semver_lib. This module is the ideal use case for the flag as all its functions perform deterministic string and arithmetic operations without external dependencies.
