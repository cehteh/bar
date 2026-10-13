#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the merge helper (Bar.d/rad).
#
# No node, no network: a throw-away project, a fake 'rad' ('RAD_BIN') and a throw-away node
# storage whose COB refs are built here, op by op, with the payloads and the author mails 'rad'
# writes -- which is what the acceptance of a patch is read from.  The merge itself never runs here
# (it is a push into another repository's canonical branch); what does run is the decision in front
# of it, the refusal, and the abort note.
#
#   AC1  '-h' answers the usage on stdout, exit 0
#   AC2  usage errors exit 2 and say how to call it
#   AC3  not a git repository: the exit codes of the module
#   AC4  an identity which is not a delegate refuses (exit 1) before anything is read
#   AC5  the chain decides: no acceptance, an acceptance which a followup voided, one from an
#        identity which is not a delegate, and the one that counts
#   AC6  '--dry-run' reads the merge and writes nothing -- no comment, no push
#   AC7  a patch which does not merge cleanly is reported and gets the abort comment, once
#   AC8  '--json' is one object with the verdicts
#   AC9  the helper is registered ('bar helpers', 'bar helpers --check')
#
# usage: tests/test_rad_merge_accepted_prs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the helper
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules radicle_lib rad rad_rules"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

echo "=== Testing the merge helper (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

RID="rad:zTestMergeAcceptedPrs0000000000"
OURS="z6MkOurIdentity00000000000000000000000000"
DELEGATE="z6MkDelegate000000000000000000000000000"
STRANGER="z6MkStranger000000000000000000000000000"
RADHOME="$WORK/radhome"
STORE="$RADHOME/storage/${RID#rad:}"
FAKE_LOG="$WORK/rad.log"
FAKE_DELEGATES="$WORK/delegates"
FAKE_TABLE="$WORK/table"
FAKE_SHOW="$WORK/show"
FAKERAD="$WORK/rad"
: >"$FAKE_LOG"

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

# <subject> <payload> <author-mail> [<parent>] - one COB op: a commit whose tree carries the
# payload as the blob '0', exactly the shape the reader opens.  Prints its object name.
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
review_payload() { printf '{"revision":"%s","summary":"","type":"review","verdict":"%s"}' "$1" "$2"; }

# <id> <head-commit> - a patch which was never reviewed; an acceptance is what is missing
patch_unreviewed() {
    local rev
    rev="$(op 'Create patch' "$(revision_payload "$BASE" "$2")" "ct_vibes@$OURS")"
    put_patch "$1" "$rev"
}

# <id> <head-commit> <subject-after> - accepted by the delegate, then something happened; the
# followup is what voids the acceptance
patch_accepted_then() {
    local rev review after
    rev="$(op 'Create patch' "$(revision_payload "$BASE" "$2")" "ct_vibes@$OURS")"
    review="$(op 'Review' "$(review_payload "$rev" accept)" "cehteh@$DELEGATE" "$rev")"
    after="$(op "$3" "$4" "cehteh@$DELEGATE" "$review")"
    put_patch "$1" "$after"
}

# <id> <head-commit> <verdict-mail> - the acceptance is the newest op; the identity decides whether
# it counts
patch_accepted() {
    local rev review
    rev="$(op 'Create patch' "$(revision_payload "$BASE" "$2")" "ct_vibes@$OURS")"
    review="$(op 'Review' "$(review_payload "$rev" accept)" "$3" "$rev")"
    put_patch "$1" "$review"
}

# <id>.. - what 'rad patch list --open' answers with; the columns are padded so that the offsets of
# the header and of the rows are the same (which is what the reader cuts by)
table_open() {
    {
        printf '│ ●  %-7s  %-9s  %-7s │\n' ID Title Head
        printf '├──────────────────────────────────┤\n'
        local id
        for id in "$@"; do
            printf '│ ●  %-7s  %-9s  %-7s │\n' "$id" topic abcdefg
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
'inspect '*--delegates*) cat "$FAKE_DELEGATES" ;;
'patch list --open') cat "$FAKE_TABLE" ;;
'patch show '*) cat "$FAKE_SHOW" ;;
'patch comment '*) printf '✓ comment added\n' ;;
*)
    printf 'unexpected: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKERAD"
export FAKE_LOG FAKE_RID="$RID" FAKE_OURS="$OURS" FAKE_RADHOME="$RADHOME" FAKE_DELEGATES FAKE_TABLE FAKE_SHOW

# a project which carries bar's rules but is no git repository
NOPROJ="$WORK/not-a-repository"
mkdir -p "$NOPROJ/Bar.d"
for module in $FIXTURE_MODULES; do
    ln -s "$REPO_ROOT/Bar.d/$module" "$NOPROJ/Bar.d/$module"
done
printf 'rule MAIN: -- true\n' >"$NOPROJ/Barf"

PROJ="$WORK/project"
mkproject "$PROJ"
printf 'base\n' >"$PROJ/f"
git -C "$PROJ" add f
git -C "$PROJ" commit -qm base
BASE="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" checkout -qb topic-clean "$BASE"
printf 'clean\n' >"$PROJ/g"
git -C "$PROJ" add g
git -C "$PROJ" commit -qm clean
CLEAN_HEAD="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" checkout -q main
printf 'theirs\n' >>"$PROJ/f"
git -C "$PROJ" commit -qam theirs
UPSTREAM="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" checkout -qb topic-conflict "$BASE"
printf 'patch\n' >>"$PROJ/f"
git -C "$PROJ" commit -qam patch
CONFLICT_HEAD="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" checkout -q main

mkdir -p "$RADHOME/storage"
git init -q --bare "$STORE"
printf '│ Target    main                                              │\n' >"$FAKE_SHOW"
printf 'did:key:%s (cehteh)\ndid:key:%s (ct_vibes)\n' "$DELEGATE" "$OURS" >"$FAKE_DELEGATES"

patch_unreviewed aaaaaaa000000000000000000000000000000000 "$CLEAN_HEAD"
patch_accepted_then bbbbbbb000000000000000000000000000000000 "$CLEAN_HEAD" \
    Comment '{"body":"wait","type":"comment"}'
patch_accepted ccccccc000000000000000000000000000000000 "$CLEAN_HEAD" "stranger@$STRANGER"
patch_accepted ddddddd000000000000000000000000000000000 "$CLEAN_HEAD" "cehteh@$DELEGATE"
patch_accepted eeeeeee000000000000000000000000000000000 "$CONFLICT_HEAD" "cehteh@$DELEGATE"

OUT=""
ERR=""
RC=0
run() {
    RC=0
    OUT="$(cd "$PROJ" && RAD_BIN="$FAKERAD" "$BAR" rad_merge_accepted_prs "$@" 2>"$WORK/err")" || RC=$?
    ERR="$(cat "$WORK/err")"
}
run_elsewhere() { # <dir> <args..>
    local dir="$1"
    shift
    RC=0
    OUT="$(cd "$dir" && RAD_BIN="$FAKERAD" "$BAR" rad_merge_accepted_prs "$@" 2>"$WORK/err")" || RC=$?
    ERR="$(cat "$WORK/err")"
}
log_has() { if grep -q -- "$1" "$FAKE_LOG"; then pass "$2"; else fail "$2 (no [$1] in the fake rad log)"; fi; }
log_not() { if ! grep -q -- "$1" "$FAKE_LOG"; then pass "$2"; else fail "$2 ([$1] reached the fake rad)"; fi; }

table_open ddddddd ccccccc bbbbbbb aaaaaaa

# --------------------------------------------------------------------------------------------
# AC1  '-h' answers the usage on stdout, exit 0
# --------------------------------------------------------------------------------------------
run -h
check "$RC" 0 "AC1: '-h' exits 0"
contains "$OUT" "usage: rad_merge_accepted_prs" "AC1: the usage goes to stdout"
absent "$ERR" "usage:" "AC1: and nothing goes to stderr"
run --help
check "$RC" 0 "AC1: '--help' exits 0 too"

# --------------------------------------------------------------------------------------------
# AC2  usage errors exit 2
# --------------------------------------------------------------------------------------------
run --nope
check "$RC" 2 "AC2: an unknown flag is a usage error"
contains "$ERR" "unknown argument '--nope'" "AC2: and the flag is named"
run --repo .
check "$RC" 2 "AC2: '--repo' is not an option of this helper"
contains "$ERR" "unknown argument '--repo'" "AC2: the option is rejected as unknown"
run --max x
check "$RC" 2 "AC2: '--max' without a number is a usage error"
run extra
check "$RC" 2 "AC2: a positional argument is a usage error"

# --------------------------------------------------------------------------------------------
# AC3  no checkout here: the helper merges in the checkout it is run from
# --------------------------------------------------------------------------------------------
run_elsewhere "$NOPROJ" --dry-run
check "$RC" 3 "AC3: outside a git repository the answer is 3"
contains "$ERR" "not a git repository" "AC3: and it says what is missing"

# --------------------------------------------------------------------------------------------
# AC4  an identity which is not a delegate refuses before it reads anything
# --------------------------------------------------------------------------------------------
printf 'did:key:%s (cehteh)\n' "$DELEGATE" >"$FAKE_DELEGATES"
: >"$FAKE_LOG"
run
check "$RC" 1 "AC4: a non-delegate invocation refuses"
contains "$ERR" "is not a delegate of $RID" "AC4: and names the repository"
contains "$ERR" "--dry-run" "AC4: and points at the way to read without writing"
log_not "patch list" "AC4: nothing was read after the refusal"
run --dry-run
check "$RC" 0 "AC4: '--dry-run' is allowed for any identity"
contains "$OUT" "mergeable patch=ddddddd " "AC4: the dry run reads the patch the delegate accepted"
printf 'did:key:%s (cehteh)\ndid:key:%s (ct_vibes)\n' "$DELEGATE" "$OURS" >"$FAKE_DELEGATES"

# --------------------------------------------------------------------------------------------
# AC5  the chain decides
# --------------------------------------------------------------------------------------------
: >"$FAKE_LOG"
run --dry-run
check "$RC" 0 "AC5: the dry run exits 0"
check "$(grep -c . <<<"$OUT")" 4 "AC5: one line per open patch"
check "$(grep '^blocked patch=aaaaaaa ' <<<"$OUT" | sed 's/.*reason=//')" "no-accept" \
    "AC5: without an acceptance nothing is merged"
check "$(grep '^blocked patch=bbbbbbb ' <<<"$OUT" | sed 's/.*reason=//')" "followup:comment" \
    "AC5: a comment after the acceptance voids it"
check "$(grep '^blocked patch=ccccccc ' <<<"$OUT" | sed 's/.*reason=//')" "not-a-delegate" \
    "AC5: an acceptance from an identity which is not a delegate does not count"
check "$(grep '^mergeable patch=ddddddd ' <<<"$OUT" | sed 's/.*reason=//')" "dry-run" \
    "AC5: the acceptance which is the newest op carries the patch"
contains "$(grep '^mergeable patch=ddddddd ' <<<"$OUT")" "revision=" "AC5: and the line names the revision"
check "$(grep '^mergeable patch=ddddddd ' <<<"$OUT" | sed 's/.*target=\([^ ]*\).*/\1/')" "main" \
    "AC5: and the branch it would be merged into"
absent "$OUT" "patch=eeeeeeee" "AC5: (the conflicting patch is not in this listing)"

# --------------------------------------------------------------------------------------------
# AC6  '--dry-run' writes nothing
# --------------------------------------------------------------------------------------------
log_not "patch comment" "AC6: a dry run posts no comment"
check "$(git -C "$PROJ" rev-parse main)" "$UPSTREAM" "AC6: and the branch it would merge into is untouched"

# --------------------------------------------------------------------------------------------
# AC7  a patch which does not merge cleanly is reported and gets the abort comment
# --------------------------------------------------------------------------------------------
table_open eeeeeee
: >"$FAKE_LOG"
run --dry-run
check "$RC" 0 "AC7: a conflicting patch is an answer, not a failure"
check "$(sed 's/.*reason=//' <<<"$OUT")" "does-not-merge" "AC7: the verdict says it does not merge"
contains "$OUT" "upstream=$UPSTREAM" "AC7: and the upstream it would have landed on is named"
log_not "patch comment" "AC7: the dry run still posts nothing"

: >"$FAKE_LOG"
run
check "$RC" 0 "AC7: the run over it answers too"
check "$(grep -c '^conflict patch=eeeeeee ' <<<"$OUT")" "1" "AC7: one conflict line, for that patch"
check "${OUT%% *}" "conflict" "AC7: the verdict is a conflict"
log_has "patch comment" "AC7: the abort comments on the patch"
log_has "does not merge at upstream $UPSTREAM" "AC7: with the upstream it does not merge at"
log_not "push" "AC7: and nothing is pushed"

# --------------------------------------------------------------------------------------------
# AC8  '--json' is one object with the verdicts
# --------------------------------------------------------------------------------------------
table_open aaaaaaa ddddddd
run --dry-run --json
check "$RC" 0 "AC8: '--json' exits 0"
check "$(jq -r '.bar_rad' <<<"$OUT" 2>/dev/null)" "1" "AC8: the object is marked"
check "$(jq -r '.delegate' <<<"$OUT" 2>/dev/null)" "true" "AC8: our identity is a delegate here"
check "$(jq -r '.patches | length' <<<"$OUT" 2>/dev/null)" "2" "AC8: one entry per open patch"
check "$(jq -r '[.patches[].reason] | sort | join(",")' <<<"$OUT" 2>/dev/null)" "dry-run,no-accept" \
    "AC8: with the reasons the text lines carry"

# --------------------------------------------------------------------------------------------
# AC9  the helper is registered
# --------------------------------------------------------------------------------------------
RC=0
OUT="$("$BAR" helpers --check 2>&1)" || RC=$?
check "$RC" 0 "AC9: 'bar helpers --check' passes"
contains "$OUT" "OK" "AC9: and reports OK"
RC=0
OUT="$("$BAR" helpers 2>&1)" || RC=$?
check "$RC" 0 "AC9: 'bar helpers' answers"
contains "$OUT" "rad_merge_accepted_prs" "AC9: the index names rad_merge_accepted_prs"
contains "$OUT" "merge the patches a delegate accepted" "AC9: with its declaration's description"
contains "$OUT" "rad_merge_accepted_prs [--dry-run] [--no-fetch] [--max <n>] [--json]" \
    "AC9: and its usage"

if (( failures )); then
    echo "FAILED: $failures"
    exit 1
fi
echo "OK: rad_merge_accepted_prs"
