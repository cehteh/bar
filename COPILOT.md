# Copilot Development Guidelines for Bar

This file contains development guidelines for GitHub Copilot when working on the Bar project.

## Code Quality

### Shellcheck
- **Always** run shellcheck on all shell scripts,
- Fix all shellcheck warnings and errors before committing
- Use `shellcheck <file>` to validate bash/shell code
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

### General instructions:
- keep and use the alloc_slot/free_slot functionality we need it later
- keep the completers and predicates, but need to be renamed s. below

### Tasks

- add literals to the parameter specifications in Bar.d/help:
   eg: `function rename ## <this> as|into <that> - requires a literal *as* or *into* at the
   2nd place` note that punctuation is are already literal: `<rulename>:` is a rulename
   prototype completer followed with a colon.
- `--` and `-` are not special anymore, `--flag` is a literal flag `<--flag>` takes '--flag'
  as prototype and calls its completer.
- `Bar.d/help` 'WRITING DOCUMENTATION' section does not comply fully with the documentation
  format described above. Fix that in `Bar.d/help`.
- rename all actual completers and predicates for better coding style in par with the predicate nameing. eg.
  - completers are renamed like: `_bar_complete_file` becomes `_bar_complete_comp_file`
  - predicates are renamed like: `_bar_complete_predicate_existing` becomes `_bar_complete_pred_existing`
  do that for all completers and predicates
- remove the caching and file timestamp bits this is just too complex for now
- rewrite the completion engine in _bar_complete in a more generic way:
   Study and analyze this appoach, and fix/improve it when you find problems. this is work in progress and only a rough sketch!
   - rename 'words' to protos, it becomes a dynamic array of prototype specs as defined
      eg `protos=("[--flags..]" "<inputs..>" "<output>")`
   - keep a proto_idx pointing to the current index where to complete
   - the protos array is dynamic completion will modify the prototype specs after the current index as we work along.
   - the protos array also terminates with an empty string, we do not need to clear all positions in the dynamic case below
   - the completion engine collects possible completers by evaluating the current index. this
     is all all alternative prototypes and if optional then from the following protos as well
     until the first non optional element is hit.
   - A prototype may hint (implement this somehow, you are free to choose how to.) that it has some additional
     completion. For simplicity we constrain this only to the prototype that is last in the
     protos array. if and only if this prototype got completed (out of other alternatives) then
     its additional completion prototype become dynamically appended to the protos array. eg:
     (do not actually implement this, this just illustrates the semantics)
     `function foo ## <input> <processor> - fooify <input> through <processor>`
     Then once the processor completer successfully completes itself (the first word for a
     processor) it append the possible completion prototype defined by that processor prototype.


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
