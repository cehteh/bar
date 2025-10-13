# Analysis of Bare-Eligible Rules in Bar.d/

## Summary

This document analyzes all rules in Bar.d/ to identify which are eligible for the `--bare` flag. The `--bare` flag marks rules that are safe to call as initial rules without SETUP, PREPROCESS, POSTPROCESS, and CLEANUP.

## Criteria for Bare-Eligible Rules

A rule qualifies as bare-eligible if it:
1. Does NOT depend on anything set up in SETUP/PREPROCESS
2. Does NOT require CLEANUP to run
3. Can depend on constant environment variables (BAR_CALLED_AS, PATH, BAR_DIR, etc.)
4. Can read existing files that are known to exist (not generated during SETUP/PREPROCESS)
5. Can write files (informal side effects are acceptable)
6. Can execute external commands that are pure on their inputs (sha1sum, grep, etc.)
7. All dependencies must also be --bare rules

The key distinction is that --bare rules are intended to be called as initial rules, so we can assume that the environment is in its initial state and won't be changed by prior SETUP/PREPROCESS steps.

## Analysis by Module

### semver_lib ✅ ALL ELIGIBLE

All 14 functions in semver_lib are pure string manipulation and arithmetic operations that don't depend on any setup:

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

**Status**: All marked with `--bare` flag ✅

### std_lib - SEVERAL ELIGIBLE

Functions analyzed:
- **memo**: NOT BARE - Depends on memoization state
- **memofn**: NOT BARE - Modifies function definitions
- **is_scalar**: ✅ BARE - Only checks variable type
- **called_as**: ✅ BARE - Depends on BAR_CALLED_AS which is constant for the run
- **is_command_installed**: ✅ BARE - Checks PATH which is quasi-constant for the run
- **bar_now**: NOT BARE - Depends on current time (not deterministic)
- **hash_args**: ✅ BARE - Computes hash using sha1sum (pure external command)
- **iset**: NOT BARE - Modifies variables (not suitable as initial rule)

**Status**: is_scalar, called_as, is_command_installed, hash_args should be marked as bare

### git_lib - SEVERAL ELIGIBLE

Read-only git functions are eligible since they read existing files and don't require setup:
- **git_dir**: ✅ BARE - Reads existing git directory
- **git_branch_name**: ✅ BARE - Queries git for branch name (read-only)
- **git_branch_find**: ✅ BARE - Queries git branches (read-only)
- **git_branch_find_one**: ✅ BARE - Queries git branches (read-only)
- **git_is_ancestor**: ✅ BARE - Queries git ancestry (read-only)
- **git_tree_hash**: ✅ BARE - Computes hash of git tree (read-only)
- **git_add_ignore**: NOT BARE - Modifies .gitignore file, but more importantly this is typically done in SETUP

**Status**: All read-only git query functions are eligible

### rule_lib - SOME ELIGIBLE

Some query functions that don't modify state are eligible:
- **rule**: NOT BARE - Defines rules (modifies registry)
- **rule_eval**: NOT BARE - Complex evaluation, typically called after setup
- **rule_exists**: ✅ BARE - Only checks if rule is defined (read-only query)
- **rule_list**: ✅ BARE - Lists rules from registry (read-only query)
- **clause_local**: NOT BARE - Manages clause-local variables

**Status**: rule_exists and rule_list are eligible

### tty_lib - ELIGIBLE

- **tty_echo**: ✅ BARE - Depends on TTY state which is constant for the run

**Status**: tty_echo is eligible

### help module - ELIGIBLE

The help module reads existing module files and displays documentation. This is a perfect example of an informal side effect (reads files) that doesn't depend on setup.

**Status**: help rule should be marked as bare

## Summary of Changes

### Implemented
1. Added `--bare` rule flag support to rule_lib (flag 'b')
2. Added bare dependency checking in rule_eval (bare rules must only depend on bare rules)
3. Documented `--bare` flag in help file
4. Marked all 14 semver_lib functions with `--bare` flag

### To Be Implemented
1. Mark additional std_lib functions as bare: is_scalar, called_as, is_command_installed, hash_args
2. Mark git_lib read-only functions as bare
3. Mark rule_lib query functions as bare: rule_exists, rule_list
4. Mark tty_echo as bare
5. Mark help rule as bare

## Testing

The bare dependency checking ensures that any bare rule can only depend on other bare rules, preventing accidental dependencies on rules that require setup. This check runs recursively during rule evaluation.

## Conclusion

The `--bare` flag is not about functional purity, but about whether a rule can safely run as an initial rule without SETUP/PREPROCESS. Many more rules qualify than initially thought, including:
- Rules that read existing files
- Rules that query constant environment state
- Rules that execute pure external commands
- Rules with informal side effects (like writing files)

The key requirement is that all dependencies must also be bare, which is now enforced at runtime.
