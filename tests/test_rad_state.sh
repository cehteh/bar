#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the radicle state helper (Bar.d/rad).
#
# Everything runs against throw-away projects and a fake 'rad' ('RAD_BIN'), so no radicle
# installation, no node and no network are needed: the tables the fake answers with are built
# here, cell by cell, with the padding and the box drawing 'rad' prints.  Covered:
#
#   AC1  the digest: a counts line per section and one line per patch, issue and branch, exit 0
#   AC2  the classification: ours against others, open/draft/merged/archived, open/closed/solved
#   AC3  cells which are hard to cut: two spaces inside an author, a non ASCII title
#   AC4  the ages come from the node storage ('refs/cobs/...'); '-' without one
#   AC5  branches: the patch a branch carries is named, the ones without one are counted
#   AC6  '--json' is one complete object, 'bar --json rad_state' too
#   AC7  elision: at most '--max' items, the exact count and a file with the complete text
#   AC8  the filters of 'rad_patches' (state, author, --json)
#   AC9  usage errors exit 2 and say how to call it
#   AC10 no git repository and no radicle repository: exit 3 with a message on stderr
#   AC11 'rad' missing, failing or unreadable: exit 1 with a message on stderr
#   AC12 an empty repository is an answer, not a failure
#   AC13 the helper is registered ('bar helpers', 'bar helpers --check')
#   AC14 against the real 'rad' in this repository, when there is one (skipped loudly otherwise)
#   AC15 the guards and the 'activate' hook of Bar.d/rad_rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar, the repertoire and the helper
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules radicle_lib rad rad_rules usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
matches() { if [[ "$1" == *$2* ]]; then pass "$3"; else fail "$3 (got [$1], want the glob [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }
lines_of() { printf '%s\n' "$1" | wc -l; }

echo "=== Testing the radicle state helper (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
if [[ -n "${RAD_STATE_TEST_KEEP:-}" ]]; then
    trap 'echo "WORK kept: $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

# <dir> - a throw-away project: bar's modules, a Barf and nothing else
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    printf 'rule MAIN: -- true\n' >"$1/Barf"
}

# <header> <row>.. - one of rad's tables; the cells of a header and of a row are '|' separated,
# the first cell of a row is its state marker.  Every column is padded to the widest cell, the
# cells are separated by two spaces and the whole is boxed, exactly like rad does it.
TABLE_WIDTHS=()
pad() { # <width> <text> - the text, padded with spaces to <width> characters
    ## not 'printf %-*s': that counts bytes and a cell with a non ASCII character would come out
    ## narrower than the column, while rad pads by character (which is what the helper cuts by)
    local width="$1" text="$2" spaces=""
    if (( ${#text} < width )); then
        printf -v spaces '%*s' "$(( width - ${#text} ))" ''
    fi
    printf '%s%s' "$text" "$spaces"
}

table_line() { # <cells..> - one line of a table, padded to 'TABLE_WIDTHS'
    local -a padded=()
    local cell content="" separator=""
    local i
    for i in "${!TABLE_WIDTHS[@]}"; do
        padded+=( "$(pad "${TABLE_WIDTHS[i]}" "$1")" )
        shift
    done
    for cell in "${padded[@]}"; do
        content+="${separator}${cell}"
        separator="  "
    done
    printf '│ %s │\n' "$content"
}

table() {
    local header="$1"
    shift
    local -a names=() cells=()
    local row
    local i
    IFS='|' read -r -a names <<<"$header"
    TABLE_WIDTHS=()
    for i in "${!names[@]}"; do TABLE_WIDTHS[i]=${#names[i]}; done
    for row in "$@"; do
        IFS='|' read -r -a cells <<<"$row"
        while (( ${#cells[@]} < ${#names[@]} )); do cells+=( "" ); done
        for i in "${!names[@]}"; do
            (( ${#cells[i]} > TABLE_WIDTHS[i] )) && TABLE_WIDTHS[i]=${#cells[i]}
        done
    done

    local width=$(( 4 + 2 * (${#TABLE_WIDTHS[@]} - 1) ))
    for i in "${!TABLE_WIDTHS[@]}"; do width=$(( width + TABLE_WIDTHS[i] )); done
    local dashes
    printf -v dashes '%*s' "$width" ''
    dashes="${dashes// /─}"

    printf '╭%s╮\n' "$dashes"
    table_line "${names[@]}"
    printf '├%s┤\n' "$dashes"
    for row in "$@"; do
        IFS='|' read -r -a cells <<<"$row"
        while (( ${#cells[@]} < ${#names[@]} )); do cells+=( "" ); done
        table_line "${cells[@]}"
    done
    printf '╰%s╯\n' "$dashes"
}

# <repo> <message> - an empty commit, prints its short object name
commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
    git -C "$1" rev-parse --short HEAD
}

FIX="$WORK/fixture"
FAKERAD="$WORK/bin/rad"
RID="rad:zRadstateTest000000000000000000000"
RIDSUFFIX="${RID#rad:}"
NID="z6MkRadstateTestRadstateTestRadstateTest"
NOW="$(date +%s)"

mkdir -p "$FIX" "$WORK/bin"
printf '%s\n' "$RID" >"$FIX/rid"
cat >"$FIX/self" <<'SELF'
Alias        testuser
DID          did:key:z6MkRadstateTestRadstateTestRadstateTest
Node         running (test)
SSH          not running
SELF

cat >"$FAKERAD" <<'FAKE'
#!/usr/bin/env bash
# a fake 'rad' for tests/test_rad_state.sh: answers from the tables below $RAD_STATE_TEST_FIXTURE
set -uo pipefail
fixture="${RAD_STATE_TEST_FIXTURE:?}"
[[ -f "$fixture/failing" ]] && {
    printf '✗ Error: the node is not running\n' >&2
    exit 1
}
case "${1:-}" in
inspect)
    if [[ -f "$fixture/not-a-radicle-repo" ]]; then
        printf '✗ Error: Current directory is not a Radicle repository\n' >&2
        exit 1
    fi
    cat "$fixture/rid"
    ;;
self)
    cat "$fixture/self"
    ;;
path)
    printf '%s\n' "$fixture/radicle-home"
    ;;
patch | issue)
    command="$1"
    [[ "${2:-}" == list ]] || {
        printf 'error: unknown %s command %s\n' "$command" "${2:-}" >&2
        exit 2
    }
    if [[ -f "$fixture/broken" ]]; then
        printf '╭──────╮\n│ ●  ID  │\n├──────╯\n│ ●  1  │\n╰───────╯\n'
        exit 0
    fi
    shift 2
    state="open"
    flavour=""
    while (( $# )); do
        case "$1" in
        --all) state="all" ;;
        --open) state="open" ;;
        --draft) state="draft" ;;
        --merged) state="merged" ;;
        --archived) state="archived" ;;
        --closed) state="closed" ;;
        --solved) state="solved" ;;
        --authored) flavour="-ours" ;;
        --repo)
            shift
            ;;
        *)
            printf 'error: unexpected argument %s\n' "$1" >&2
            exit 2
            ;;
        esac
        shift
    done
    file="$fixture/$command-$state$flavour.txt"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        printf 'Nothing to show.\n'
    fi
    ;;
*)
    printf 'error: unknown command %s\n' "${1:-}" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$FAKERAD"

# the repository the helper reports on
REPO="$WORK/repo"
mkproject "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email rad_state@example.invalid
git -C "$REPO" config user.name rad_state-test
C1="$(commit "$REPO" one)"
C2="$(commit "$REPO" two)"
C3="$(commit "$REPO" three)"
git -C "$REPO" update-ref refs/remotes/rad/main "$C1"
git -C "$REPO" branch topic "$C2"
git -C "$REPO" branch work "$C3"
git -C "$REPO" checkout -q work

# the tables 'rad' answers with; the heads are the commits above, so that the branch which
# carries a patch can be named, and one head is a commit this checkout does not have
PATCH_HEADER='●|ID|Title|Author|Reviews|Head|+|-|Updated|Labels'
PATCH_ALL_ROWS=(
    "●|a1bd13a|find the frobs|testuser  (you)|-|$C2|+12|-3|10 minutes ago|"
    "●|3ff91cb|fix the naïve parser|z6MksP7…ZpYZJTo|✓|$C1|+8|-6|1 year ago|"
    "◌|c0ffee1|a draft of a rewrite|testuser  (you)|-|1234567|+1|-0|2 hours ago|wip"
    "✓|deadbe1|merge the frobs|cehteh|-|1234567|+21|-4|3 days ago|"
    "✓|beef001|an archived thing|testuser  (you)|✓|1234567|+2|-2|1 month ago|archived"
)
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[@]}" >"$FIX/patch-all.txt"
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[0]}" "${PATCH_ALL_ROWS[2]}" "${PATCH_ALL_ROWS[4]}" >"$FIX/patch-all-ours.txt"
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[2]}" >"$FIX/patch-draft.txt"
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[3]}" >"$FIX/patch-merged.txt"
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[4]}" >"$FIX/patch-archived.txt"
table "$PATCH_HEADER" "${PATCH_ALL_ROWS[0]}" "${PATCH_ALL_ROWS[1]}" >"$FIX/patch-open.txt"

ISSUE_HEADER='●|ID|Title|Author|Labels|Assignees|Opened'
ISSUE_ROWS=(
    "●|a967c0c|a smoke test|testuser   (you)|bug, p1|testuser|7 hours ago"
    "●|b0b0b0b|another issue|cehteh|||2 days ago"
    "●|abcdef0|a closed one|cehteh|||1 day ago"
    "✓|c0de001|a solved one|testuser  (you)|done||2 days ago"
)
table "$ISSUE_HEADER" "${ISSUE_ROWS[@]}" >"$FIX/issue-all.txt"
table "$ISSUE_HEADER" "${ISSUE_ROWS[0]}" "${ISSUE_ROWS[1]}" >"$FIX/issue-open.txt"
table "$ISSUE_HEADER" "${ISSUE_ROWS[2]}" >"$FIX/issue-closed.txt"
table "$ISSUE_HEADER" "${ISSUE_ROWS[3]}" >"$FIX/issue-solved.txt"

# the node storage: a copy of the COBs of one patch and one issue, which is what the ages and
# the kind of the last event are read from.  It is a bare git directory, like the one radicle
# keeps below '$(rad path)/storage/<RID>', and the commits are written with plumbing so that
# their dates are fixed.
STORAGE="$FIX/radicle-home/storage/$RIDSUFFIX"
mkdir -p "$STORAGE"
git init -q --bare "$STORAGE"
git --git-dir="$STORAGE" config user.email rad_state@example.invalid
git --git-dir="$STORAGE" config user.name rad_state-test
EMPTY_TREE="$(git --git-dir="$STORAGE" mktree </dev/null)"

# <epoch> <message> [<parent>] - an empty commit in the storage, prints its object name
cob_commit() {
    local epoch="$1" message="$2" parent="${3:-}"
    local -a parent_arg=()
    [[ -n "$parent" ]] && parent_arg=( -p "$parent" )
    GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
        git --git-dir="$STORAGE" commit-tree "$EMPTY_TREE" "${parent_arg[@]}" -m "$message"
}

PATCH_CREATED=$(( NOW - 200000 ))
PATCH_UPDATED=$(( NOW - 10000 ))
COB="$(cob_commit "$PATCH_CREATED" 'Create patch')"
COB="$(cob_commit "$PATCH_UPDATED" 'Comment' "$COB")"
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID/refs/cobs/xyz.radicle.patch/a1bd13a0000000000000000000000000000000" "$COB"

ISSUE_CREATED=$(( NOW - 700000 ))
ISSUE_UPDATED=$(( NOW - 600000 ))
COB="$(cob_commit "$ISSUE_CREATED" 'Create')"
COB="$(cob_commit "$ISSUE_UPDATED" 'Label' "$COB")"
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID/refs/cobs/xyz.radicle.issue/a967c0c0000000000000000000000000000000" "$COB"

# an empty fixture: every list answers 'Nothing to show.'
EMPTY="$WORK/fixture-empty"
mkdir -p "$EMPTY"
cp "$FIX/rid" "$FIX/self" "$EMPTY/"
ln -s "$FIX/radicle-home" "$EMPTY/radicle-home"

# a fixture which is not a radicle repository
NORAD="$WORK/fixture-norad"
mkdir -p "$NORAD"
cp "$FIX/rid" "$FIX/self" "$NORAD/"
touch "$NORAD/not-a-radicle-repo"

# a project which is not a git repository at all
NOGIT="$WORK/project-nogit"
mkproject "$NOGIT"

# --------------------------------------------------------------------------------------------
# runners
# --------------------------------------------------------------------------------------------

OUT=""
RC=0
run_command() { # <dir> <rad_state-rad> <rad_state-test-fixture> <args..>
    local dir="$1" radcmd="$2" statefixture="$3"
    shift 3
    OUT=""
    RC=0
    OUT="$(cd "$dir" && RAD_BIN="$radcmd" RAD_STATE_TEST_FIXTURE="$statefixture" "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_command_err() { # same, but capture stderr and drop stdout
    local dir="$1" radcmd="$2" statefixture="$3"
    shift 3
    OUT=""
    RC=0
    OUT="$(cd "$dir" && RAD_BIN="$radcmd" RAD_STATE_TEST_FIXTURE="$statefixture" "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}
run_bar() { run_command "$REPO" "$FAKERAD" "$FIX" "$@"; }
run_bar_err() { run_command_err "$REPO" "$FAKERAD" "$FIX" "$@"; }
line_of() { printf '%s\n' "$OUT" | grep -m1 "^  $1  "; }

# --------------------------------------------------------------------------------------------
# AC1  the digest
# --------------------------------------------------------------------------------------------
run_bar rad_state
check "$RC" "0" "AC1: 'bar rad_state' exits 0"
check "$(lines_of "$OUT")" "18" "AC1: three header lines, five patches, four issues, three branches"
REPO_PATH_DISPLAY="${REPO/"$HOME"/\~}"
check "$(sed -n 1p <<<"$OUT")" "repo      repo  $RID  $REPO_PATH_DISPLAY" \
    "AC1: the repository line names RID, name and path"
check "$(sed -n 2p <<<"$OUT")" "ident     testuser  did:key:$NID" "AC1: the identity line carries alias and DID"
check "$(sed -n 3p <<<"$OUT")" \
    "head      work $C3   rad/main $C1   ahead 2  behind 0  (as of the last fetch)" \
    "AC1: the head line carries the branch, the canonical ref and the divergence"
check "$(sed -n 4p <<<"$OUT")" \
    "patches   5   ours 3  others 2   open 2  draft 1  merged 1  archived 1" \
    "AC1: the patch counts are theirs, split by state"
check "$(sed -n 10p <<<"$OUT")" \
    "issues    4   ours 2  others 2   open 2  closed 1  solved 1" \
    "AC1: the issue counts are theirs, split by state"
check "$(sed -n 15p <<<"$OUT")" \
    "branches  3   no patch 2   2 commits not in rad/main" \
    "AC1: the branch counts name what carries no patch"
check "$(printf '%s\n' "$OUT" | grep -c '^  [0-9a-f]\{7\}  ')" "9" \
    "AC1: five patches and four issues are listed"
if (( $(printf '%s' "$OUT" | wc -c) > 0 )); then pass "AC1: the digest is $(printf '%s' "$OUT" | wc -c) bytes"; else fail "AC1: empty digest"; fi

# --------------------------------------------------------------------------------------------
# AC2  the classification
# --------------------------------------------------------------------------------------------
matches "$(line_of a1bd13a)" "  a1bd13a  open*ours*$C2*3h*find the frobs" \
    "AC2: an open patch of ours, with head, age and title"
matches "$(line_of 3ff91cb)" "  3ff91cb  open*other*$C1*fix the naïve parser" \
    "AC2: an open patch of someone else"
matches "$(line_of c0ffee1)" "  c0ffee1  draft*ours*a draft of a rewrite" \
    "AC2: a draft of ours"
matches "$(line_of deadbe1)" "  deadbe1  merged*other*merge the frobs" \
    "AC2: a merged patch of someone else"
matches "$(line_of beef001)" "  beef001  archived*ours*an archived thing" \
    "AC2: an archived patch of ours"
matches "$(line_of a967c0c)" "  a967c0c  open*ours*a smoke test" "AC2: an open issue of ours"
matches "$(line_of c0de001)" "  c0de001  solved*ours*a solved one" "AC2: a solved issue of ours"
matches "$(line_of abcdef0)" "  abcdef0  closed*other*a closed one" "AC2: a closed issue of someone else"
contains "$OUT" "[bug, p1]" "AC2: the labels of an issue are printed"
contains "$OUT" "[@testuser]" "AC2: the assignees of an issue are printed"
absent "$(line_of b0b0b0b)" "[" "AC2: an issue without labels and assignees carries no bracket"
absent "$OUT" "(you)" "AC2: the author of a patch is the name, not rad's '(you)' marker"
absent "$(line_of a1bd13a)" "[testuser]" "AC2: our own patches carry no author bracket"
contains "$(line_of deadbe1)" "[cehteh]" "AC2: the patch of someone else names its author"

# --------------------------------------------------------------------------------------------
# AC3  cells which are hard to cut
# --------------------------------------------------------------------------------------------
contains "$OUT" "naïve parser" "AC3: a title with a non ASCII character survives"
contains "$OUT" "z6MksP7…ZpYZJTo" "AC3: rad's truncated author with an ellipsis survives"
matches "$(line_of 3ff91cb)" "  3ff91cb  open     other  $C1" \
    "AC3: the columns behind a non ASCII cell are still cut right"
absent "$(line_of a1bd13a)" "+12" "AC3: a cell is cut at the column, not at the end of the row"
absent "$(line_of a1bd13a)" "10 minutes ago" "AC3: rad's own Updated column is not taken over"

# --------------------------------------------------------------------------------------------
# AC4  the ages come from the node storage
# --------------------------------------------------------------------------------------------
contains "$(line_of a1bd13a)" "3h" "AC4: the last event of a patch is its age"
contains "$(line_of a967c0c)" "7d" "AC4: the last event of an issue is its age"
matches "$(line_of c0ffee1)" "*  1234567 -    a draft of a rewrite" "AC4: a patch without a stored COB has no age"
matches "$(line_of 3ff91cb)" "*  $C1 -    fix the naïve parser" \
    "AC4: and rad's own Updated column is not taken for the age"

# --------------------------------------------------------------------------------------------
# AC5  the branches
# --------------------------------------------------------------------------------------------
matches "$(printf '%s\n' "$OUT" | grep -m1 '^  topic ')" "  topic *patch a1bd13a" \
    "AC5: the branch carrying a patch names it"
matches "$(printf '%s\n' "$OUT" | grep -m1 '^  work ')" "  work *no patch" \
    "AC5: the branch of this checkout carries no patch"
contains "$(printf '%s\n' "$OUT" | grep -m1 '^  work ')" "ahead 2" \
    "AC5: and is counted against rad/main"

# --------------------------------------------------------------------------------------------
# AC6  --json
# --------------------------------------------------------------------------------------------
run_bar rad_state --json
check "$RC" "0" "AC6: '--json' exits 0"
check "$(lines_of "$OUT")" "1" "AC6: '--json' is one line"
contains "$OUT" '"bar_rad":1,"repo":{"rid":"'"$RID"'"' "AC6: it names itself and the repository"
contains "$OUT" '"updated":'"$PATCH_UPDATED"',' "AC6: the last event of a patch is a timestamp"
contains "$OUT" '"last":"Comment"' "AC6: and the kind of the last event is named"
contains "$OUT" '"age":"3h"' "AC6: with the age of that event"
contains "$OUT" '"updated":null,"age":"-"' "AC6: a patch without a stored COB has neither"
if command -v jq >/dev/null; then
    if jq -e . >/dev/null 2>&1 <<<"$OUT"; then pass "AC6: jq reads the object"; else fail "AC6: jq does not read it"; fi
    check "$(jq -r '.patches.count' <<<"$OUT")" "5" "AC6: the patch count"
    check "$(jq -r '.patches.ours' <<<"$OUT")" "3" "AC6: the patches of ours"
    check "$(jq -r '.patches.items | length' <<<"$OUT")" "5" "AC6: every patch is an item"
    check "$(jq -r '.patches.items[] | select(.id=="a1bd13a") | .state' <<<"$OUT")" "open" "AC6: the state of a patch"
    check "$(jq -r '.patches.items[] | select(.id=="a1bd13a") | .ours' <<<"$OUT")" "true" "AC6: ours is a boolean"
    check "$(jq -r '.patches.items[] | select(.id=="deadbe1") | .author' <<<"$OUT")" "cehteh" "AC6: the author of someone else's patch"
    check "$(jq -r '.issues.count' <<<"$OUT")" "4" "AC6: the issue count"
    check "$(jq -r '.issues.items[] | select(.id=="a967c0c") | .labels | join(",")' <<<"$OUT")" "bug,p1" \
        "AC6: the labels are an array"
    check "$(jq -r '.issues.items[] | select(.id=="a967c0c") | .last' <<<"$OUT")" "Label" \
        "AC6: the kind of the last event of an issue"
    check "$(jq -r '.head.ahead' <<<"$OUT")" "2" "AC6: the divergence"
    check "$(jq -r '.identity.alias' <<<"$OUT")" "testuser" "AC6: the identity"
    check "$(jq -r '.branches.without_patch' <<<"$OUT")" "2" "AC6: the branches without a patch"
    check "$(jq -r '.branches.not_in_canonical' <<<"$OUT")" "2" "AC6: the commits which are not in rad/main"
    check "$(jq -r '.branches.items[] | select(.name=="topic") | .patch' <<<"$OUT")" "a1bd13a" \
        "AC6: the patch of a branch"
    check "$(jq -r '.branches.items[] | select(.name=="work") | .patch' <<<"$OUT")" "null" \
        "AC6: no patch is null"
    check "$(jq -r '.patches.items | map(.age) | join(",")' <<<"$OUT")" "3h,-,-,-,-" "AC6: the ages"
else
    echo "  - AC6: jq is not installed, the fields are not checked"
fi
run_bar --json rad_state
check "$RC" "0" "AC6: 'bar --json rad_state' exits 0"
contains "$OUT" '"bar_rad":1' "AC6: and prints the same object"

# --------------------------------------------------------------------------------------------
# AC7  elision
# --------------------------------------------------------------------------------------------
run_bar rad_state --max 1
check "$RC" "0" "AC7: '--max 1' exits 0"
contains "$OUT" "4 of 5 elided" "AC7: the elision of the patches is counted"
contains "$OUT" "3 of 4 elided" "AC7: so is the elision of the issues"
check "$(printf '%s\n' "$OUT" | grep -c '^  [0-9a-f]\{7\}  ')" "2" "AC7: one patch and one issue are printed"
contains "$OUT" "complete  " "AC7: the complete text is named"
FILE="$(printf '%s\n' "$OUT" | sed -n 's/^complete  \([^ ]*\) .*/\1/p')"
if [[ -f "$FILE" ]]; then pass "AC7: the file exists"; else fail "AC7: no file at [$FILE]"; fi
if [[ -f "$FILE" ]]; then
    check "$(lines_of "$(cat "$FILE")")" "18" "AC7: it holds the whole digest"
    check "$(grep -c '^  [0-9a-f]\{7\}  ' "$FILE")" "9" "AC7: with every patch and issue"
    absent "$(cat "$FILE")" "elided" "AC7: and nothing elided"
fi
run_bar rad_state --max 0
check "$(lines_of "$OUT")" "18" "AC7: '--max 0' lists everything"

# --------------------------------------------------------------------------------------------
# AC8  the filters
# --------------------------------------------------------------------------------------------
run_bar rad_patches --state open
check "$RC" "0" "AC8: a filtered patch list exits 0"
contains "$OUT" "patches   2 of 5   ours 3  others 2" "AC8: it counts the filter against the total"
contains "$OUT" "(state open, author all)" "AC8: and names the filter"
check "$(printf '%s\n' "$OUT" | grep -c '^  [0-9a-f]\{7\}  ')" "2" "AC8: two patches are open"
absent "$OUT" "issues" "AC8: and it prints no other section"
run_bar rad_patches --author ours
contains "$OUT" "patches   3 of 5" "AC8: ours are three"
run_bar rad_patches --state merged --author ours
contains "$OUT" "patches   0 of 5" "AC8: ours and merged are none -- an answer, not a failure"
check "$RC" "0" "AC8: an empty filter exits 0"
run_bar rad_patches --json --state draft
check "$(jq -r '.patches.count' <<<"$OUT")" "5" "AC8: --json counts the total"
check "$(jq -r '.patches.items | length' <<<"$OUT")" "1" "AC8: and itemises the filter"
check "$(jq -r '.select.state' <<<"$OUT")" "draft" "AC8: and names it"

# --------------------------------------------------------------------------------------------
# AC9  usage errors
# --------------------------------------------------------------------------------------------
run_bar_err rad_state --nonsense
check "$RC" "2" "AC9: an unknown argument is a usage error"
contains "$OUT" "rad_state: invalid arguments" "AC9: which says what was wrong"
contains "$OUT" "try 'bar usage rad_state'" "AC9: and where the help is"
run_bar_err rad_state --max notanumber
check "$RC" "2" "AC9: '--max' wants a number"
run_bar_err rad_patches --state nonsense
check "$RC" "2" "AC9: so does '--state'"
run_bar_err rad_patches --author nonsense
check "$RC" "2" "AC9: and '--author'"
run_bar rad_state --help
check "$RC" "0" "AC9: '--help' is not an error"
contains "$OUT" "rad_state [--json] [--max <n>]" "AC9: and the builtin help is the answer, on stdout"
run_bar rad_patches --help
check "$RC" "0" "AC9: 'rad_patches --help' too"
contains "$OUT" "rad_patches [--json] [--max <n>] [--state <open|draft|merged|archived|all>]" "AC9: with the patches form of the help"

# --------------------------------------------------------------------------------------------
# AC10  no git repository, no radicle repository
# --------------------------------------------------------------------------------------------
run_command_err "$NOGIT" "$FAKERAD" "$FIX" rad_state
check "$RC" "3" "AC10: a project which is no git repository is no data"
contains "$OUT" "not a git repository" "AC10: and says so"
run_command_err "$REPO" "$FAKERAD" "$NORAD" rad_state
check "$RC" "3" "AC10: a repository without a radicle identity is no data"
contains "$OUT" "no radicle repository" "AC10: and says so"

# --------------------------------------------------------------------------------------------
# AC11  rad missing, failing or unreadable
# --------------------------------------------------------------------------------------------
run_command_err "$REPO" "$WORK/bin/nonexistent" "$FIX" rad_state
check "$RC" "1" "AC11: a missing rad could not answer"
contains "$OUT" "not installed" "AC11: and says so"
touch "$FIX/failing"
run_bar_err rad_state
check "$RC" "1" "AC11: a failing rad could not answer"
contains "$OUT" "failed" "AC11: and passes its message on"
rm "$FIX/failing"
touch "$FIX/broken"
run_bar_err rad_state
check "$RC" "1" "AC11: a table without the expected columns is not understood"
contains "$OUT" "cannot read what" "AC11: and says which call it was"
rm "$FIX/broken"

# --------------------------------------------------------------------------------------------
# AC12  an empty repository
# --------------------------------------------------------------------------------------------
run_command "$REPO" "$FAKERAD" "$EMPTY" rad_state
check "$RC" "0" "AC12: an empty repository is an answer"
check "$(sed -n 4p <<<"$OUT")" "patches   0   ours 0  others 0   open 0  draft 0  merged 0  archived 0" \
    "AC12: the patch counts are zero"
check "$(sed -n 5p <<<"$OUT")" "issues    0   ours 0  others 0   open 0  closed 0  solved 0" \
    "AC12: the issue counts are zero"
absent "$OUT" "(you)" "AC12: and nothing is listed"

# --------------------------------------------------------------------------------------------
# AC13  the registration
# --------------------------------------------------------------------------------------------
run_bar helpers
check "$RC" "0" "AC13: the repertoire lists the helper"
contains "$OUT" "rad_state " "AC13: 'rad_state' is registered"
contains "$OUT" "rad_patches" "AC13: so is 'rad_patches'"
contains "$OUT" "(12 helpers)" "AC13: and the twelve helpers of the module are the whole repertoire"
contains "$OUT" "rad_import" "AC13: including the way in, 'rad_import'"
contains "$OUT" "rad_comment_metadata" "AC13: and the proposal reader the module grew"
contains "$OUT" "rad_rm_label" "AC13: and the label removal the write layer grew"
contains "$OUT" "rad_cob" "AC13: and the COB store interface the reader grew"
contains "$OUT" "rad_rebase_ask" "AC13: and the sweep sender the merge round grew"
run_bar helpers --check
check "$RC" "0" "AC13: the registration guard passes"
check "$OUT" "" "AC13: and prints nothing for a complete repertoire"

# --------------------------------------------------------------------------------------------
# AC14  against the real rad, when there is one
# --------------------------------------------------------------------------------------------
if command -v rad >/dev/null 2>&1 && (cd "$REPO_ROOT" && rad inspect --rid >/dev/null 2>&1); then
    REAL_RC=0
    REAL_OUT="$(cd "$REPO_ROOT" && "$BAR" rad_state 2>/dev/null)" || REAL_RC=$?
    matches "$REAL_OUT" "repo      *  rad:*  *" "AC14: the real repository is reported"
    if (( REAL_RC == 0 )); then pass "AC14: the real invocation exits 0"; else fail "AC14: the real invocation exits $REAL_RC"; fi
    if (( $(printf '%s\n' "$REAL_OUT" | wc -l) <= 40 )); then
        pass "AC14: $(printf '%s\n' "$REAL_OUT" | wc -l) lines, $(printf '%s' "$REAL_OUT" | wc -c) bytes for one screen"
    else
        fail "AC14: $(printf '%s\n' "$REAL_OUT" | wc -l) lines is more than one screen"
    fi
    REAL_JSON="$(cd "$REPO_ROOT" && "$BAR" rad_state --json 2>/dev/null)" || REAL_JSON=""
    contains "$REAL_JSON" '"bar_rad":1' "AC14: the real '--json' is the object"
    if command -v jq >/dev/null; then
        if jq -e . >/dev/null 2>&1 <<<"$REAL_JSON"; then pass "AC14: jq reads it"; else fail "AC14: jq does not read it"; fi
    fi
else
    echo "  - AC14 skipped: no rad and no radicle repository here"
fi

# --------------------------------------------------------------------------------------------
# AC15  the guards and the hook of Bar.d/rad_rules
# --------------------------------------------------------------------------------------------
echo "--- AC15 the guards and the 'activate' hook ---"
run_bar is_rad_repository
check "$RC" "0" "AC15: 'is_rad_repository' answers for a radicle repository"
check "$OUT" "" "AC15: a predicate prints nothing"
run_bar is_rad_available
check "$RC" "0" "AC15: 'is_rad_available' finds the command bar runs"
run_bar is_rad_toplevel
check "$RC" "0" "AC15: and we are at its toplevel"
run_command "$REPO" "$WORK/bin/nonexistent-rad" "$FIX" is_rad_available
check "$RC" "1" "AC15: a missing command is refused"
run_command "$REPO" "$WORK/bin/nonexistent-rad" "$FIX" is_rad_repository
check "$RC" "1" "AC15: and nothing answers for the checkout then"
run_command "$REPO" "$FAKERAD" "$NORAD" is_rad_repository
check "$RC" "1" "AC15: a checkout without a radicle identity is refused"
run_command "$NOGIT" "$FAKERAD" "$FIX" is_rad_toplevel
check "$RC" "1" "AC15: so is 'is_rad_toplevel' outside a repository"
run_command "$REPO/.git" "$FAKERAD" "$FIX" is_rad_toplevel
check "$RC" "1" "AC15: and below the toplevel"
run_bar activate
check "$RC" "0" "AC15: 'activate' sets a radicle checkout up for bar"
check "$(grep -cxF '.worktrees/' "$REPO/.git/info/exclude")" "1" \
    "AC15: '.worktrees/' is in .git/info/exclude"
run_bar activate
check "$RC" "0" "AC15: running it again answers"
check "$(grep -cxF '.worktrees/' "$REPO/.git/info/exclude")" "1" \
    "AC15: and writes the line exactly once"

echo
if (( failures )); then
    echo "==== $failures FAILURE(S) ===="
    exit 1
fi
echo "==== all rad_state tests passed ===="
