# Copilot Development Guidelines for Bar

This file contains development guidelines for GitHub Copilot when working on the Bar project.

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

### Tasks

- add tests for everything you do!

0. Describe the completer design in the `### Design` section right below here in COPILOT.md in
   a way you can use it for yourself later. commit this.
1. rename all global private functions and variables to have `_bar_complete_` as prefix
   - _bar_completion_registry to _bar_complete_protoregistry
   - _bar_extcomplete to _bar_complete_ext
   - _bar_parse_file to _bar_complete_parse_file
   - are there any more global private functions or variables that don't have _bar_complete as
     prefix? change those too.
2. Entries _bar_complete_protoregistry do not need "_bar_complete_comp_" as prefix anymore
   `_bar_complete_protoregistry[rulefile]="_bar_complete_comp_file rulefile"` becomes
   `_bar_complete_protoregistry[rulefile]="file rulefile"`
   the places where _bar_complete_protoregistry is used will expand it: "_bar_complete_comp_${...}"
3. Entries in _bar_complete_protoregistry will have the key syntax `prototype@module` where
   the `@module` part is optional for common/global completers set up in
   _bar_init_completion_registry. prototypes added when parsing modules (see below) should add
   the module name to resolve ambiguities.
4. When looking entries in _bar_complete_protoregistry the `proto@module` form is tried first.
   This means we need to keep track from which module the current completing item originates,
   implement that. When `proto@module` it falls back to just `proto`.
5. Add a prototype definiton syntax to Bar.d/help and implement parsing it in _bar_complete_parse_file:
   a single hash comment like
   `# prototype: "file" = "file"`
   or
   `# prototype: "rulefile" = "file rulefile"`
   will add these as _bar_complete_protoregistry[${module}@]rulefile]="file rulefile"
6. add simple caching back:
   add a `declare -a cache` this acts as cache for the current position completion only
7. Refine the `### Design` section right below here in COPILOT.md to include what you just
   changed.

### Design


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
