#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the rebase sender (Bar.d/rad).
#
# No node, no network: a throw-away project, a fake 'rad' ('RAD_BIN') and a throw-away node
# storage whose patch COBs are built here, op by op.  The sender merges nothing and re-cuts
# nothing -- what is tested is the decision in front of the one comment it writes.
#
#   AC1  '-h' answers the usage on stdout, exit 0
#   AC2  usage errors exit 2 and say how to call it
#   AC3  not a git repository: the module's exit code for 'no data'
#   AC4  a patch which is not merged refuses: a sweep follows a merge that landed, nothing else
#   AC5  a merge which is not in the branch refuses, even when the patch says 'merged'
#   AC6  the sweep asks the stale member and skips: the one at the tip, another branch, another
#        author, and the one carrying a live '*trigger:rebase'; the write carries the full object
#        id, where the listing only prints seven hex
#   AC7  a directive that was consumed (redacted) does not count -- that patch is asked again
#   AC8  '--dry-run' writes nothing
#   AC9  '--json' is one object with the branch, the tip and one row per open patch
#   AC10 the helper is registered ('bar helpers --check')
#
# usage: tests/test_rad_rebase_ask.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the helper
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules radicle_lib rad rad_rules usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }
# the seven hex 'rad patch list' prints, where the object id is what the write needs
short() { printf '%s' "${1:0:7}"; }

echo "=== Testing the rebase sender (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

RID="rad:zTestRebaseAsk00000000000000000"
OURS="z6MkOurIdentity00000000000000000000000000"
STRANGER="z6MkStranger000000000000000000000000000"
RADHOME="$WORK/radhome"
STORE="$RADHOME/storage/${RID#rad:}"
FAKE_LOG="$WORK/rad.log"
FAKE_WRITES="$WORK/rad.writes"
FAKE_BODIES="$WORK/rad.bodies"
FAKE_TABLE="$WORK/table"
FAKE_SHOW_DIR="$WORK/show"
FAKERAD="$WORK/rad"
: >"$FAKE_LOG"
: >"$FAKE_WRITES"
: >"$FAKE_BODIES"
mkdir -p "$FAKE_SHOW_DIR"

# <dir> - a throw-away project: bar's modules, a Barf, a git repository and nothing else
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    printf 'rule MAIN: -- true\n' >"$1/Barf"
    git init -q "$1"
    git -C "$1" config user.name fixture
    git -C "$1" config user.email fixture@example.com
}

# <subject> <payload> <author-mail> [<parent>] - one COB op, exactly the shape the reader opens
op() {
    local subject="$1" payload="$2" mail="$3" parent="${4:-}"
    local blob tree commit
    local -a par=()
    blob="$(printf '%s' "$payload" | git --git-dir="$STORE" hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\t0\n' "$blob" | git --git-dir="$STORE" mktree)"
    if [[ -n "$parent" ]]; then par=( -p "$parent" ); fi
    commit="$(printf '%s\n' "$subject" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL="$mail" \
        GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL="$mail" \
        git --git-dir="$STORE" commit-tree "$tree" ${par[@]+"${par[@]}"} -F -)"
    [[ -n "$commit" ]] || fail "the fixture could not build the op '$subject'"
    printf '%s' "$commit"
}

# <id> <tip-op> - the patch COB under its own id (the ref name is the id 'rad' keys it by)
put_patch() {
    git --git-dir="$STORE" update-ref "refs/namespaces/$OURS/refs/cobs/xyz.radicle.patch/$1" "$2"
}

revision_payload() { printf '{"base":"%s","description":"fixture","oid":"%s","type":"revision"}' "$1" "$2"; }
comment_payload() { printf '{"body":"%s","revision":"","type":"comment"}' "$1"; }

# <id> <head-commit> <author-mail> [<comment-body>] [--redact] - one patch whose newest op is a
# comment (optionally redacted afterwards, which is what a consumed directive looks like)
patch_with() {
    local id="$1" head="$2" mail="$3" body="${4:-}" redact="${5:-}"
    local rev tip comment
    rev="$(op 'Create patch' "$(revision_payload "$BASE" "$head")" "$mail")"
    tip="$rev"
    if [[ -n "$body" ]]; then
        comment="$(op 'Comment' "$(comment_payload "$body")" "$mail" "$rev")"
        tip="$comment"
        if [[ "$redact" == --redact ]]; then
            tip="$(op 'Redact comment' "$(printf '{"comment":"%s","revision":"","type":"revision.comment.redact"}' "$comment")" \
                "$mail" "$comment")"
        fi
    fi
    put_patch "$id" "$tip"
}

# <id> <head> <target> <author> <status> - what 'rad patch show' answers for that patch
patch_show() {
    {
        printf '│ Title     %s\n' "$1"
        printf '│ Patch     %s\n' "$1"
        printf '│ Author    %s\n' "$4"
        printf '│ Head      %s\n' "$2"
        printf '│ Target    %s\n' "$3"
        printf '│ Status    %s\n' "$5"
    } >"$FAKE_SHOW_DIR/$(short "$1")"
}

# <id>.. - what 'rad patch list --open' answers with, columns padded to the same offsets
table_open() {
    {
        printf '│ ●  %-7s  %-9s  %-7s │\n' ID Title Head
        printf '├──────────────────────────────────┤\n'
        local id
        for id in "$@"; do
            printf '│ ●  %-7s  %-9s  %-7s │\n' "$(short "$id")" topic "$(git -C "$PROJ" rev-parse --short=7 "$(table_head "$id")")"
        done
        printf '╰──────────────────────────────────╯\n'
    } >"$FAKE_TABLE"
}

cat >"$FAKERAD" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$*" in
path) printf '%s\n' "$FAKE_RADHOME" ;;
self) printf 'Alias        ct_vibes\nDID          did:key:%s\n' "$FAKE_OURS" ;;
'inspect --rid') printf '%s\n' "$FAKE_RID" ;;
'patch list --open') cat "$FAKE_TABLE" ;;
'patch show '*) cat "$FAKE_SHOW_DIR/${3:0:7}" ;;
*patch\ comment*-r*)
    ## 'rad patch comment' takes no '-r/--repo' (nor does 'rad issue comment'): the real binary
    ## answers 'unexpected argument' and exits 2.  A fake which tolerated it hid a sender whose
    ## every directive was refused -- a merge landed and asked nobody.
    printf "error: unexpected argument '-r' found\n" >&2
    exit 2
    ;;
'patch comment '*)
    if [[ "${PWD:-}" != "$FAKE_PROJ" ]]; then
        ## What the real binary needs: the write has to run in the checkout, since that is how 'rad'
        ## resolves the repository ('patch comment' has no repo selector of its own).
        printf 'the write ran outside the checkout: %s\n' "${PWD:-}" >&2
        exit 2
    fi
    printf '%s\n' "${3}" >>"$FAKE_WRITES"
    printf '%s\n' "${5}" >>"$FAKE_BODIES"
    ;;
*)
    printf 'unexpected: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKERAD"
export FAKE_LOG FAKE_RID="$RID" FAKE_OURS="$OURS" FAKE_RADHOME="$RADHOME"
export FAKE_TABLE FAKE_SHOW_DIR FAKE_WRITES FAKE_BODIES

# a project which carries bar's rules but is no git repository
NOPROJ="$WORK/not-a-repository"
mkdir -p "$NOPROJ/Bar.d"
for module in $FIXTURE_MODULES; do
    ln -s "$REPO_ROOT/Bar.d/$module" "$NOPROJ/Bar.d/$module"
done
printf 'rule MAIN: -- true\n' >"$NOPROJ/Barf"

PROJ="$WORK/project"
export FAKE_PROJ="$PROJ"
mkproject "$PROJ"
printf 'base\n' >"$PROJ/f"
git -C "$PROJ" add f
git -C "$PROJ" commit -qm base
BASE="$(git -C "$PROJ" rev-parse HEAD)"
printf 'theirs\n' >"$PROJ/g"
git -C "$PROJ" add g
git -C "$PROJ" commit -qm landed
TIPPED="$(git -C "$PROJ" rev-parse HEAD)"
# the member whose head is the tip is current; every other member sits on BASE

mkdir -p "$RADHOME/storage"
git init -q --bare "$STORE"
git --git-dir="$STORE" symbolic-ref HEAD refs/heads/main

# --------------------------------------------------------------------------------------------
# the patches
# --------------------------------------------------------------------------------------------

## Full object ids, as the store keys them and as 'rad patch comment' resolves them: the listing
## prints the first seven, so a fixture that made the ids seven hex long could not tell the two
## apart -- and a write under the short form is refused by rad for every member.
STALE=1111111111111111111111111111111111111111
CURRENT=2222222222222222222222222222222222222222
OTHER=3333333333333333333333333333333333333333
FOREIGN=4444444444444444444444444444444444444444
LIVE=5555555555555555555555555555555555555555
SPENT=6666666666666666666666666666666666666666
MERGED=7777777777777777777777777777777777777777

patch_with "$STALE" "$BASE" "ct_vibes@$OURS"
patch_with "$CURRENT" "$TIPPED" "ct_vibes@$OURS"
patch_with "$OTHER" "$BASE" "ct_vibes@$OURS"
patch_with "$FOREIGN" "$BASE" "cehteh@$STRANGER"
patch_with "$LIVE" "$BASE" "ct_vibes@$OURS" '*trigger:rebase'
patch_with "$SPENT" "$BASE" "ct_vibes@$OURS" '*trigger:rebase' --redact
patch_with "$MERGED" "$BASE" "ct_vibes@$OURS"

# a commit outside the branch: what a merge into another branch, or a failed push, looks like
ORPHAN="$(printf 'nobody\n' | git -C "$PROJ" commit-tree "$(git -C "$PROJ" mktree </dev/null)")"

patch_show "$STALE"   "$BASE"   main "ct_vibes (you)" open
patch_show "$CURRENT" "$TIPPED" main "ct_vibes (you)" open
patch_show "$OTHER"   "$BASE"   next "ct_vibes (you)" open
patch_show "$FOREIGN" "$BASE"   main "cehteh"         open
patch_show "$LIVE"    "$BASE"   main "ct_vibes (you)" open
patch_show "$SPENT"   "$BASE"   main "ct_vibes (you)" open
patch_show "$MERGED"  "$BASE"   main "ct_vibes (you)" merged

table_head() {
    case "$1" in
    "$CURRENT") printf '%s' "$TIPPED" ;;
    *) printf '%s' "$BASE" ;;
    esac
}
table_open "$STALE" "$CURRENT" "$OTHER" "$FOREIGN" "$LIVE" "$SPENT" "$MERGED"

run() { ( cd "$1" && RAD_BIN="$FAKERAD" "$BAR" rad_rebase_ask "${@:2}" ); }

# --------------------------------------------------------------------------------------------
# AC1 -- the usage
# --------------------------------------------------------------------------------------------

echo "AC1 the usage"
out="$(run "$PROJ" -h 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "-h exits 0"
contains "$out" "usage: rad_rebase_ask" "-h answers the usage on stdout"
contains "$out" "--after <patch>" "the usage names '--after'"

# --------------------------------------------------------------------------------------------
# AC2 -- usage errors
# --------------------------------------------------------------------------------------------

echo
echo "AC2 usage errors"
out="$(run "$PROJ" --after 2>&1)" && rc=0 || rc=$?
check "$rc" 2 "'--after' without a value exits 2"
contains "$out" "needs a value" "and says what is missing"
out="$(run "$PROJ" --nonsense 2>&1)" && rc=0 || rc=$?
check "$rc" 2 "an unknown argument exits 2"
contains "$out" "unknown argument" "and names it"

# --------------------------------------------------------------------------------------------
# AC3 -- not a repository
# --------------------------------------------------------------------------------------------

echo
echo "AC3 not a repository"
out="$(run "$NOPROJ" --branch main --dry-run 2>&1)" && rc=0 || rc=$?
check "$rc" 3 "a checkout which is no git repository exits 3"
contains "$out" "not a git repository" "and says so"

# --------------------------------------------------------------------------------------------
# AC4 -- a patch which is not merged is not swept for
# --------------------------------------------------------------------------------------------

echo
echo "AC4 a merge that did not happen"
: >"$FAKE_WRITES"
: >"$FAKE_BODIES"
out="$(run "$PROJ" --after "$STALE" 2>&1)" && rc=0 || rc=$?
check "$rc" 1 "an open patch as '--after' exits 1"
contains "$out" "not merged" "and says the patch is not merged"
check "$(wc -l <"$FAKE_WRITES")" 0 "nothing was written"

# --------------------------------------------------------------------------------------------
# AC5 -- 'merged' is not enough: the commit has to be in the branch
# --------------------------------------------------------------------------------------------

echo
echo "AC5 a merge which is not in the branch"
out="$(run "$PROJ" --after "$MERGED" --onto "$ORPHAN" 2>&1)" && rc=0 || rc=$?
check "$rc" 1 "'--onto' a tip the merge is not in exits 1"
contains "$out" "nothing was asked" "and says nothing was asked"

# --------------------------------------------------------------------------------------------
# AC6/AC7 -- the sweep: who is asked, who is skipped
# --------------------------------------------------------------------------------------------

echo
echo "AC6 the sweep"
: >"$FAKE_WRITES"
: >"$FAKE_BODIES"
out="$(run "$PROJ" --after "$MERGED" 2>&1)" && rc=0 || rc=$?
check "$rc" 0 "the sweep exits 0"
check "$(sort "$FAKE_WRITES" | tr '\n' ' ')" "$(printf '%s\n' "$SPENT" "$STALE" | sort | tr '\n' ' ')" \
    "the stale member and the one whose directive was consumed are asked, once each"
contains "$out" "current patch=$(short "$CURRENT")" "the member at the tip is current"
contains "$out" "skipped patch=$(short "$OTHER") target=next" "another branch is skipped"
contains "$out" "skipped patch=$(short "$FOREIGN")" "another author's patch is skipped"
contains "$out" "not-ours:cehteh" "and the reason names the author"
contains "$out" "already-asked" "the live directive is not sent twice"
contains "$out" "asked patch=$(short "$SPENT")" "a consumed directive does not count (redaction is read)"
check "$(awk 'length($0) != 40' "$FAKE_WRITES" | wc -l)" 0 \
    "every id handed to 'rad patch comment' is the full 40 hex, never the listing's seven"
absent "$out" "asked patch=$(short "$MERGED")" "the landed patch is not asked, full id against listed"

echo
echo "AC7 the directive body"
check "$(head -1 "$FAKE_BODIES")" "*trigger:rebase" "the sole line is what is posted"

# --------------------------------------------------------------------------------------------
# AC8 -- '--dry-run' writes nothing
# --------------------------------------------------------------------------------------------

echo
echo "AC8 '--dry-run'"
: >"$FAKE_WRITES"
: >"$FAKE_BODIES"
out="$(run "$PROJ" --after "$MERGED" --dry-run 2>&1)" && rc=0 || rc=$?
check "$rc" 0 "'--dry-run' exits 0"
check "$(wc -l <"$FAKE_WRITES")" 0 "'--dry-run' writes nothing"
contains "$out" "asked patch=$(short "$STALE")" "and still answers who would be asked"

# --------------------------------------------------------------------------------------------
# AC9 -- '--json'
# --------------------------------------------------------------------------------------------

echo
echo "AC9 '--json'"
out="$(run "$PROJ" --after "$MERGED" --dry-run --json 2>/dev/null)"
check "$(printf '%s' "$out" | jq -r '.bar_rad')" 1 "it is one bar_rad object"
check "$(printf '%s' "$out" | jq -r '.branch')" main "the branch is the merged patch's Target"
check "$(printf '%s' "$out" | jq -r '.branch_tip')" "$TIPPED" "the tip is the canonical branch"
check "$(printf '%s' "$out" | jq -r '[.patches[].patch] | length')" 6 "one row per open patch, minus the merged one"
check "$(printf '%s' "$out" | jq -r '[.patches[].patch] | index("'"$(short "$MERGED")"'") | tostring')" null \
    "the patch that landed is no member"
check "$(printf '%s' "$out" | jq -r '[.patches[] | select(.verdict == "asked") | .patch] | sort | join(",")')" \
    "$(printf '%s\n' "$(short "$SPENT")" "$(short "$STALE")" | sort | tr '\n' ',' | sed 's/,$//')" \
    "the asked rows are the two"

# --------------------------------------------------------------------------------------------
# AC10 -- registered
# --------------------------------------------------------------------------------------------

echo
echo "AC10 registration"
out="$( cd "$REPO_ROOT" && ./bar helpers --check 2>&1 )" && rc=0 || rc=$?
check "$rc" 0 "'bar helpers --check' passes"
contains "$( cd "$REPO_ROOT" && ./bar helpers 2>&1 )" "rad_rebase_ask" "the helper is listed"

echo
if (( failures )); then
    echo "  $failures check(s) failed"
    exit 1
fi
echo "  all checks passed"
