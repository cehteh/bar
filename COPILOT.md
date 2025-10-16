# Copilot Development Guidelines for Bar

This file contains development guidelines for GitHub Copilot when working on the Bar project.

## ⚠️ IMPORTANT REMINDERS - Read These First! ⚠️

**ALWAYS follow these guidelines before committing:**

1. **Run `./bar` to check the project and rebuild README**
   - This validates the project and regenerates documentation
   - **ALWAYS** do this before every commit
   - Fix any issues it shows before committing
   
2. **README commits**
   - Only commit README when there are significant additions
   - Or when you are finished with a task and want to push it for review
   - Don't commit trivial README updates
   
3. **Keep COPILOT.md updated**
   - Add things you recently learned and need to remember
   - Remove finished tasks and outdated items
   - Commit COPILOT.md when you change it
   
4. **Testing**
   - `./bar tests` runs all tests defined in Barf
   - All test files in `tests/*.sh` should be executable
   - Tests must pass before committing

---

## Code Quality

### Shellcheck
- **Always** run shellcheck on all shell scripts,
- Fix all shellcheck warnings and errors before committing
- Use `shellcheck <file>` to validate bash/shell code
- Use shellcheck on tests as well
- Location of shellcheck config: `shellcheckrc`
- Use `./bar lints` will run shellcheck on all sources

### Testing
- Create tests in the `tests/` directory for new functionality
- Always test good, bad and corner cases.
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
  - `<param..>` or `<param>..` for one or more occurrences
  - `[param..]` or `[param]..` for zero or more occurrences
  - `<>` and `[]` can be nested.
  - `word` anything that is not in `<>` or `[]` is a literal
  - `a|b` where `a` and `b` can be anything from above for alternatives, any number of
    alternatives is allowed (`a|b|c|d` etc).
    note that the placement of `..` becomes important here `<a..|b>` is at least one `a` or a
    single `b` whereas `<a|b>..` is at least one of a or b.
  - `param` are prototypes, they define what completer will be used

## Completion System

All core completion system tasks have been completed. The system now supports:
- Module tracking with hierarchical lookup
- Prototype definitions via comments
- Literal punctuation handling (e.g., `[+toolchain]`)
- Universal black-box completion forwarding via `extcomp`
- Variable expansion in prototypes (e.g., `${CARGO_TOOLCHAIN}`)
- Performance caching

### Design

The completion system works through multiple layers:

1. **Registry System**: The `_bar_complete_protoregistry` is an associative array that maps
   prototype names to completer specifications. Instead of storing full function names like
   `_bar_complete_comp_file`, it stores simplified specs like `"file"` or `"file existing"`.
   The `_bar_get_completer` function expands these specs when retrieving them.

2. **Prototype Syntax**: Documentation uses a formal parameter syntax:
   - `<param>` for mandatory parameters
   - `[param]` for optional parameters
   - `param..` for repeating parameters (one or more)
   - `<a|b>` for alternatives

3. **Module-Specific Completers**: 
   - Modules can define specialized completers following the pattern `<module>_<prototype>_complete`
   - These are automatically discovered when parsing module files and registered as `module@prototype`
   - Modules can also define prototypes via comments: `# prototype: "name" = "completer_spec"`
   - Example: `# prototype: "toolchain" = "ext cargo_toolchain_complete"`

4. **Module Tracking**:
   - Functions and rules are tracked to their source module via `_bar_completion_func_module`
     and `_bar_completion_rule_module` associative arrays
   - When parsing files in Bar.d/, the module name is automatically derived from the filename
   - This enables module-specific completion behavior

5. **Completion Flow**:
   - Parse command line to determine current completion position
   - Match previous words against parameter prototypes
   - Determine which prototype we're completing
   - Look up completer in registry with hierarchical fallback:
     1. Try `module@proto` (if module known for current rule/function)
     2. Try `func@proto` (for function/rule-specific completers)
     3. Fall back to `proto` (global completers)
   - Call completer with current prefix and any predicate filters
   - Cache results to avoid duplicate work within same completion session
   - Return filtered, sorted results

6. **Completer Specification Format**:
   - Registry stores simplified specs: `"file"`, `"file existing"`, `"ext funcname"`, `"extcomp command"`
   - When retrieved via `_bar_get_completer`, specs are expanded:
     - `"file"` → `_bar_complete_comp_file`
     - `"file existing"` → `_bar_complete_comp_file existing`
     - `"ext funcname"` → `_bar_complete_comp_ext funcname`
     - `"extcomp command args"` → `_bar_complete_comp_extcomp command args`
   - Variable expansion: `${VARIABLE}` in specs are expanded at completion time

7. **Predicate Filters**: Completers can be constrained by predicates (like "existing",
   "nonexisting", "local", "rulefile") that filter the completion results.

8. **Caching**: 
   - External completers (those that call `bar --bare`) cache their results in
     `_bar_completion_extcomplete_cache` to avoid repeated expensive calls
   - Position-level caching: Within a single completion session, completer results are cached
     by completer+prefix key in a local `cache` array to avoid redundant calls

9. **Naming Conventions**:
   - All completion-related global functions and variables use `_bar_complete` prefix
   - `_bar_complete_protoregistry` - the main registry
   - `_bar_complete_comp_ext` - external completer caller
   - `_bar_complete_comp_extcomp` - universal external command completion forwarder
   - `_bar_complete_parse_file` - file parser
   - `_bar_complete_comp_*` - built-in completers

10. **Literal Punctuation Handling**:
   - Parameters can have literal punctuation prefixes/suffixes: `<+toolchain>`, `<rule:>`
   - Exceptions: `--` and `-` are part of prototype, `..` is repetition marker
   - When user hasn't typed the literal yet, completer is called and results are prefixed
   - Example: `[+toolchain]` completes to `+stable`, `+nightly`, etc.


### Module-Specific Completers
- Pattern: `<module>_<prototype>_complete` in `Bar.d/` modules
- Module and prototype names must match: `^([a-z][a-z0-9]*)_([a-z][a-z0-9]*)_complete$`
- No underscores in module/prototype names (only alphanumeric)
- Register automatically in completion registry

### Completers
- Implement predicates as `_bar_complete_comp_<name>` functions
- they receive the current completion prefix as $1
- any more paramters are predicate filter names that connstrain the completions.

### Predicate Filters
- Implement predicates as `_bar_complete_pred_<name>` functions
- Predicates receive item to test as `$1`
- Return 0 (success) if item passes the predicate
- Return non-zero if item fails the predicate
- Common predicates: `existing`, `nonexisting`, `local`, `rulefile`
- Add more as neccessary

### Generic Completers
- Located in `contrib/bar_complete`
- Support predicate filtering via optional arguments
- Built-in types: file, directory, path, rule, command, command_or_rule
- Add more as neccessary

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
