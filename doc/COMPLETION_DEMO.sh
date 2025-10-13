#!/bin/bash
# Visual demonstration of parameter completion

echo "=================================================="
echo "Bar Parameter Completion - Visual Demonstration"
echo "=================================================="
echo

cat << 'EOF'
Example 1: Function with Generic Parameters
--------------------------------------------
function process_file ## <input> [output] - Process a file
{
    ## <input>  - Input file to process
    ## [output] - Optional output file
    cat "$1" > "${2:-/dev/stdout}"
}

Completion behavior:
$ bar process_file <TAB>
  → Shows all files in current directory
  → Because <input> maps to generic "file" completer

----

Example 2: Module-Specific Completion (Cargo)
----------------------------------------------
function cargo_toolchain_complete ## List available toolchains
{
    rustup toolchain list 2>/dev/null | sed 's/^/+/'
}

function build_with_toolchain ## <toolchain> - Build with toolchain
{
    ## <toolchain> - Rust toolchain (e.g., +stable, +nightly)
    cargo "$1" build
}

Completion behavior:
$ bar build_with_toolchain <TAB>
  → Shows: +stable, +nightly, +beta, etc.
  → Because <toolchain> maps to cargo@toolchain completer

----

Example 3: Git Branch Completion
---------------------------------
function git_branch_complete ## List git branches
{
    git branch --list --format="%(refname:short)" 2>/dev/null
}

function checkout_branch ## <branch> - Checkout a branch
{
    ## <branch> - Git branch name
    git checkout "$1"
}

Completion behavior:
$ bar checkout_branch <TAB>
  → Shows: main, develop, feature/xyz, etc.
  → Because <branch> maps to git@branch completer

----

Example 4: Rule with Parameters
--------------------------------
## <target> [options..] - Build a target
rule build:
    ## <target>    - Build target name
    ## [options..] - Additional build options
    echo "Building $1 with options: ${@:2}"

Completion behavior:
$ bar build <TAB>
  → Shows files/directories (default completion for unspecified prototype)

----

How It Works Internally
-----------------------

1. Parser Phase (on first completion):
   - Scans Barf files and Bar.d/* modules
   - Extracts documentation: ## <params> - description
   - Stores in _bar_completion_func_params["function"]="<params>"

2. Registry Initialization:
   - Maps generic types: registry["file"]="_bar_complete_file"
   - Discovers module completers: registry["cargo@toolchain"]="_bar_extcomplete ..."
   - Caches results for performance

3. Completion Phase (on TAB press):
   - Determines context: which function/rule is being called
   - Looks up parameters for that function/rule
   - For each parameter prototype:
     a. Try function-specific: foo@input
     b. Try module-specific: module@input
     c. Try generic: input
     d. Default to text
   - Calls appropriate completer and returns results

4. Caching:
   - File mtimes tracked, only reparsed when changed
   - External completer results cached
   - Directory mtimes monitored for incremental updates

----

Testing the System
------------------

$ cd tests
$ ./test_completion.sh      # Unit tests
$ ./test_integration.sh     # Integration tests

Both test suites validate:
- Parameter parsing from documentation
- Registry initialization and lookups
- Generic completer functionality
- Module-specific completer discovery
- Context-aware completion behavior

----

Adding Your Own Completers
---------------------------

1. For generic types, add to _bar_init_completion_registry():
   _bar_completion_registry[mytype]="_bar_complete_mytype"

2. For module-specific types, create in your module:
   function mymodule_mytype_complete ## Description
   {
       # Output one completion per line
       echo "option1"
       echo "option2"
   }
   # Automatically registered as mymodule@mytype

3. Use in documentation:
   function myfunc ## <mytype> - Description
   {
       ## <mytype> - Maps to mymodule@mytype completer
       ...
   }

EOF

echo
echo "=================================================="
echo "See doc/COMPLETION.md for complete documentation"
echo "=================================================="
