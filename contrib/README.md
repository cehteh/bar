# Bar Completion Script

This directory contains utilities and extensions for the bar command runner.

## bar_completion

Bash completion script for bar/please commands that provides intelligent tab completion.

### Features

- **First argument completion**: Completes with:
  - Text files in the current directory
  - Any shell command (including defined functions)
  - Existing rules from the default Barf file
  - Autoloadable modules from Bar.d/ directory

- **Second argument completion**: When the first argument is a file:
  - Completes with rules and functions defined in that file
  - Also includes commands, rules, and functions from the default Barf

- **Argument hints**: For third and subsequent arguments:
  - Parses `##` comments from functions and rules to suggest arguments
  - Falls back to file completion when no hints are found

### Installation

#### User Installation

Add to your `~/.bashrc`:

```bash
source /path/to/bar/contrib/bar_completion
```

#### System-wide Installation

```bash
sudo cp contrib/bar_completion /etc/bash_completion.d/bar
```

#### Project-specific Installation

If bar is versioned in your project:

```bash
# Add to your shell rc file
[[ -f /path/to/project/contrib/bar_completion ]] && source /path/to/project/contrib/bar_completion
```

### Usage Examples

```bash
# Complete rules and commands
$ bar <TAB>
activate  build  lints  test  ...

# Complete with git module detection
$ bar gi<TAB>
git  githook

# Complete rules from specific Barf file
$ bar Barf <TAB>
activate  lints  build_docs  ...

# Complete with argument hints
$ bar require <TAB>
--opt  modules
```

### How It Works

1. **Rule extraction**: Scans files for `rule <name>:` patterns
2. **Function extraction**: Scans files for `function <name>` patterns
3. **Module autoloading**: Lists single-word files in Bar.d/ without underscores
4. **Argument parsing**: Extracts hints from `## [arg] - description` comment patterns
5. **Default Barf detection**: Searches upward for Barf/Pleasef files and Bar.d directories

### Supported Commands

- `bar` - The main bar command
- `please` - The please variant of bar
- `./bar` - Local bar executable
- `./please` - Local please executable
