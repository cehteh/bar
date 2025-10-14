# Copilot Development Guidelines for Bar

This file contains development guidelines for GitHub Copilot when working on the Bar project.

## Code Quality

### Shellcheck
- **Always** run shellcheck on all shell scripts
- Fix all shellcheck warnings and errors before committing
- Use `shellcheck <file>` to validate bash/shell code
- Location of shellcheck config: `shellcheckrc`

### Testing
- Create tests in the `tests/` directory for new functionality
- Test files should be executable and named `test_*.sh`
- Run tests before committing changes
- All tests must pass before code is merged

## Documentation

### Documentation Source
- **Only** document in `Bar.d/help` - this is the single source of truth
- Do **NOT** create separate documentation files in `doc/` or elsewhere
- The README is auto-generated from `Bar.d/help`

### Generating README
- Regenerate README after help changes with: `./bar doc`
- Add the regenerated README to your commit

### Documentation Format
- Use `###` for file-level documentation
- Use `##` for function/rule documentation
- Follow the formal parameter syntax documented in `Bar.d/help`:
  - `<param>` for mandatory parameters
  - `[param]` for optional parameters
  - `param..` for one or more occurrences
  - `[param..]` for zero or more occurrences
  - `--flag` for flag options
  - `foo|bar` for alternatives

## Completion System

### Module-Specific Completers
- Pattern: `<module>_<prototype>_complete`
- Module and prototype names must match: `^([a-z][a-z0-9]*)_([a-z][a-z0-9]*)_complete$`
- No underscores in module/prototype names (only alphanumeric)
- Register automatically in completion registry

### Predicate Filters
- Implement predicates as `_bar_complete_predicate_<name>` functions
- Predicates receive item to test as `$1`
- Return 0 (success) if item passes the predicate
- Return non-zero if item fails the predicate
- Common predicates: `existing`, `nonexisting`, `local`, `rulefile`

### Generic Completers
- Located in `contrib/bar_complete`
- Support predicate filtering via optional arguments
- Built-in types: file, directory, path, rule, command, command_or_rule

## Git Commit Messages

### Storing Implementation Notes
- If you need to keep implementation notes or summaries for reference
- Put them in **git commit messages**, not in separate files
- This keeps the repository clean while preserving historical context

## Project Structure

### Key Files
- `bar` - Main executable
- `Bar.d/` - Modules directory
- `Bar.d/help` - Documentation source
- `contrib/bar_complete` - Bash completion script
- `tests/` - Test suite

### Naming Conventions
- Module files: lowercase, no underscores for completion modules
- Test files: `test_*.sh` in `tests/` directory
- Functions: lowercase with underscores
- Rules: lowercase with underscores or hyphens

## Development Workflow

1. Understand the requirements fully before coding
2. Check existing code patterns and conventions
3. Run shellcheck on all changes
4. Create/update tests for new functionality
5. Run all tests to verify changes
6. Update Bar.d/help if adding/changing documented features
7. Regenerate README with `./bar doc` if help changed
8. Commit changes with clear, concise messages

## Common Patterns

### Function Documentation
```bash
function my_function ## <required> [optional] - Brief description
{
    ## <required> - Description of required parameter
    ## [optional] - Description of optional parameter
    ...
}
```

### Rule Documentation
```bash
## <param> [options..] - Brief description of rule
rule my_rule:
    ## <param> - Description
    ## [options..] - Description
    ...
```

### Module Completer
```bash
function mymodule_mytype_complete ## Brief description
{
    # Output one completion per line to stdout
    echo "option1"
    echo "option2"
}
# Automatically registered as mymodule@mytype
```

## References

- Main documentation: `Bar.d/help` (view with `./bar help`)
- Completion guide: See WRITING DOCUMENTATION section in `Bar.d/help`
- Examples: Check existing modules in `Bar.d/` for patterns
