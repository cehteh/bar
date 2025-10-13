# Bar Test Suite

This directory contains automated tests for the bar build system.

## Running Tests

To run all tests:

```bash
TERM=dumb ./tests/test_shebang.sh
```

Note: `TERM=dumb` is required to prevent terminal control sequence issues when running in non-interactive environments.

## Tests

### test_shebang.sh

Tests the shebang functionality that allows Barf files to be executable with a `#!/path/to/bar` shebang.

**Test cases:**
1. Execute Barf file with shebang
2. Execute Barf file with shebang and explicit rule
3. Execute Barf file with rule and arguments
4. Normal bar execution with explicit Barf file
5. Normal bar execution with explicit rule
6. Bar finds and uses Barf in current directory

All tests use `TERM=dumb` to avoid terminal control sequence hangs in non-interactive environments.
