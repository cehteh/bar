#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'rad_cob state' (Bar.d/rad): the state a reactive consumer derives from
# every chain of one repository, in one read.
#
# The node's storage is a real git repository, so the reduction is answered by git and not by a
# mock: an op is a commit whose tree carries that op's actions as the files 0, 1, ... plus the
# manifest, and the op is recognized by the 'Rad-Resource:' trailer the store writes.  'rad' is a
# script which answers 'path' and records every invocation, which is how the call count is read.
#
#   AC1  one op carrying a transition (to live, from taken back) yields exactly one marker
#   AC2  two markers of one author on one target are both reported, each with its own op
#   AC3  the call count does not grow with the number of COBs, and no 'rad cob' is invoked
#   AC4  '--since <cob>:<op>' skips a COB whose head still starts with that op, prefixes included
#   AC5  one shape for an issue and for a patch: the same keys, both marker levels, the indexes
#   AC6  a withdrawal removes its author's entry and is never reported as a second state
#   AC7  a redaction takes its markers with it and leaves the comment in the index
#   AC8  '--type' takes a list and 'all', '--json' is accepted, every record has one key set
#   AC9  usage errors exit 2, an unknown repository 3, an unreadable node 5, empty means no line
#   AC10 the helper is registered ('bar helpers --check') and the usage names the state verb
#
# usage: tests/test_rad_cob_state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (found [$2])"; fi; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RID="rad:z3StateTestRepository"
NID="z6MkAlice"

ISSUE_A="aaaa000011112222333344445555666677778888"
ISSUE_B="bbbb000011112222333344445555666677778888"
PATCH_A="cccc000011112222333344445555666677778888"

RADHOME="$WORKDIR/radhome"
FIXTURES="$WORKDIR/fixtures"
CALLS="$WORKDIR/calls"
STORAGE="$RADHOME/storage/z3StateTestRepository"
mkdir -p "$STORAGE" "$FIXTURES/bin"
: >"$CALLS"
git init -q --bare "$STORAGE"

TAB=$'\t'

commit_raw() { # <date> <message> - a commit on an empty tree, its id on stdout
    local date="$1" message="$2" empty
    empty="$(git --git-dir="$STORAGE" mktree </dev/null)"
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@$NID" \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL="t@$NID" \
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git --git-dir="$STORAGE" commit-tree "$empty" -m "$message"
}

blob_of() { # <text> - the blob id of one action, on stdout
    printf '%s' "$1" | git --git-dir="$STORAGE" hash-object -w --stdin
}

manifest_of() { # <type> - the manifest blob of one COB type
    blob_of "{\"typeName\":\"xyz.radicle.$1\",\"version\":1}"
}

op_commit() { # <date> <manifest> <parent|-> <action>.. - one op of the store, its id on stdout
    local date="$1" manifest="$2" parent="$3"
    shift 3
    local -a entries=() args=()
    local i=0 action tree
    for action in "$@"; do
        entries+=("100644 blob $(blob_of "$action")${TAB}$i")
        i=$(( i + 1 ))
    done
    entries+=("100644 blob $manifest${TAB}manifest")
    tree="$(printf '%s\n' "${entries[@]}" | git --git-dir="$STORAGE" mktree)"
    args=(-m 'op' -m "Rad-Resource: $AUTHORITY")
    if [[ -n "$parent" && "$parent" != - ]]; then
        args+=(-p "$parent")
    else
        args+=(-p "$AUTHORITY")
    fi
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@$NID" \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL="t@$NID" \
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git --git-dir="$STORAGE" commit-tree "$tree" "${args[@]}"
}

ref_cob() { # <type> <cob-id> <tip>
    git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID/refs/cobs/xyz.radicle.$1/$2" "$3"
}

AUTHORITY="$(commit_raw '2026-01-01T00:00:00+00:00' 'Initialize identity')"
ISSUE_MANIFEST="$(manifest_of issue)"
PATCH_MANIFEST="$(manifest_of patch)"

# ISSUE_A: a marker superseded inside one op, a withdrawal, two markers on one comment
A1="$(op_commit '2026-02-01T00:00:00+00:00' "$ISSUE_MANIFEST" - '{"type":"comment","body":"the root comment"}')"
A2="$(op_commit '2026-02-01T01:00:00+00:00' "$ISSUE_MANIFEST" "$A1" "{\"type\":\"comment\",\"body\":\"a second one\",\"replyTo\":\"$A1\"}")"
A3="$(op_commit '2026-02-01T02:00:00+00:00' "$ISSUE_MANIFEST" "$A2" "{\"type\":\"comment.react\",\"id\":\"$A1\",\"reaction\":\"👀\",\"active\":true}")"
A4="$(op_commit '2026-02-01T03:00:00+00:00' "$ISSUE_MANIFEST" "$A3" \
    "{\"type\":\"comment.react\",\"id\":\"$A1\",\"reaction\":\"✅\",\"active\":true}" \
    "{\"type\":\"comment.react\",\"id\":\"$A1\",\"reaction\":\"👀\",\"active\":false}")"
A5="$(op_commit '2026-02-01T04:00:00+00:00' "$ISSUE_MANIFEST" "$A4" "{\"type\":\"comment.react\",\"id\":\"$A2\",\"reaction\":\"➖\",\"active\":true}")"
A6="$(op_commit '2026-02-01T05:00:00+00:00' "$ISSUE_MANIFEST" "$A5" "{\"type\":\"comment.react\",\"id\":\"$A2\",\"reaction\":\"🔧\",\"active\":true}")"
ref_cob issue "$A1" "$A6"

# ISSUE_B: a comment taken back
B1="$(op_commit '2026-02-02T00:00:00+00:00' "$ISSUE_MANIFEST" - '{"type":"comment","body":"another root"}')"
B2="$(op_commit '2026-02-02T01:00:00+00:00' "$ISSUE_MANIFEST" "$B1" "{\"type\":\"comment\",\"body\":\"this one is taken back\",\"replyTo\":\"$B1\"}")"
B3="$(op_commit '2026-02-02T02:00:00+00:00' "$ISSUE_MANIFEST" "$B2" "{\"type\":\"comment.react\",\"id\":\"$B2\",\"reaction\":\"✅\",\"active\":true}")"
B4="$(op_commit '2026-02-02T03:00:00+00:00' "$ISSUE_MANIFEST" "$B3" "{\"type\":\"comment.redact\",\"id\":\"$B2\"}")"
ref_cob issue "$B1" "$B4"

# PATCH_A: a revision, a revision comment, a review, and a marker on each
P1="$(op_commit '2026-02-04T00:00:00+00:00' "$PATCH_MANIFEST" - '{"type":"revision","oid":"1111111111111111111111111111111111111111","base":"2222222222222222222222222222222222222222","description":"the work"}')"
P2="$(op_commit '2026-02-04T01:00:00+00:00' "$PATCH_MANIFEST" "$P1" "{\"type\":\"revision.comment\",\"revision\":\"$P1\",\"body\":\"a remark\"}")"
P3="$(op_commit '2026-02-04T02:00:00+00:00' "$PATCH_MANIFEST" "$P2" "{\"type\":\"review\",\"revision\":\"$P1\",\"verdict\":\"accept\",\"summary\":\"\"}")"
P4="$(op_commit '2026-02-04T03:00:00+00:00' "$PATCH_MANIFEST" "$P3" "{\"type\":\"review.react\",\"review\":\"$P3\",\"reaction\":\"✅\",\"active\":true}")"
P5="$(op_commit '2026-02-04T04:00:00+00:00' "$PATCH_MANIFEST" "$P4" "{\"type\":\"revision.comment.react\",\"revision\":\"$P1\",\"comment\":\"$P2\",\"reaction\":\"➖\",\"active\":true}")"
ref_cob patch "$P1" "$P5"

# the fixture rad: answers path, and records every invocation
cat >"$FIXTURES/bin/rad" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$CALLS"
case "${1:-}" in
path)
    if [[ -n "${FAIL_PATH:-}" ]]; then
        printf 'Error: failed to connect to node\n'
        exit 1
    fi
    printf '%s\n' "$RADHOME"
    ;;
self)
    if [[ -n "${FAIL_SELF:-}" ]]; then
        printf 'Error: failed to connect to node\n'
        exit 1
    fi
    printf 'Alias fake\nDID did:key:z6MkFake\n'
    ;;
*)
    printf 'Error: the fake rad was asked for %s\n' "$*"
    exit 1
    ;;
esac
FAKE
chmod +x "$FIXTURES/bin/rad"

export RADHOME CALLS
export RAD_BIN="$FIXTURES/bin/rad"

state() { ( cd "$REPO_ROOT" && "$BAR" rad_cob state --repo "$RID" "$@" 2>/dev/null ); }
rc_of() { ( cd "$REPO_ROOT" && "$BAR" rad_cob state "$@" >/dev/null 2>&1 ) && echo 0 || echo $?; }

jf() { jq -r "$2" <<<"$1"; }
nonempty() { printf '%s' "$1" | grep -c . || true; }

F_KEYS='keys | join(",")'
F_MARKERS='[.markers[] | "\(.level) \(.target) \(.emoji)"] | join(";")'
F_COMMENTS='[.comments[].id] | join(",")'

OUT="$(state)"
REC_A="$(jq -c --arg c "$A1" 'select(.cob == $c)' <<<"$OUT")"
REC_B="$(jq -c --arg c "$B1" 'select(.cob == $c)' <<<"$OUT")"
REC_P="$(jq -c --arg c "$P1" 'select(.cob == $c)' <<<"$OUT")"

# --- AC1 / AC2 / AC6 ---------------------------------------------------------------------------
check "$(jf "$REC_A" .kind)" "issue" "AC1 the record names its kind"
check "$(jf "$REC_A" .head)" "$A6" "AC1 the head is the newest op"
check "$(jf "$REC_A" "$F_MARKERS")" "root $A1 ✅;comment $A2 ➖;comment $A2 🔧" \
    "AC1/AC2/AC6 one marker per state, the superseded one never reported, oldest first"
absent "$(jf "$REC_A" "$F_MARKERS")" "👀" "AC1 the marker withdrawn in the same op is not live"
check "$(jf "$REC_A" '.markers[0].op')" "$A4" "AC1 the op which made the marker live is named"
check "$(jf "$REC_A" '.markers[0].author')" "$NID" "AC1 the author is the op's nid"
check "$(jf "$REC_A" '.markers[0].date')" "2026-02-01T03:00:00Z" "AC1 the date is that op's"
check "$(jf "$REC_A" '.markers[1].op')" "$A5" "AC2 a second marker on one target keeps its own op"
check "$(jf "$REC_A" '.markers[2].op')" "$A6" "AC2 the newest marker is last"

# --- AC5: one shape for both kinds --------------------------------------------------------------
check "$(jf "$REC_A" "$F_KEYS")" "$(jf "$REC_P" "$F_KEYS")" "AC5 the same keys for issue and patch"
check "$(jf "$REC_A" "$F_KEYS")" "cob,comments,copy,head,kind,markers,revisions" "AC5 the key set"
check "$(jf "$REC_P" "$F_MARKERS")" "review $P3 ✅;revision-comment $P2 ➖" \
    "AC5 the marker levels of a patch, in op order"
check "$(jf "$REC_P" '.markers[0].level')" "review" "AC5 a review marker is its own level"
check "$(jf "$REC_P" "$F_COMMENTS")" "$P2" "AC5 the revision comment is in the index"
check "$(jf "$REC_P" '.comments[0].revision')" "$P1" "AC5 the revision it belongs to is named"
check "$(jf "$REC_P" '.revisions[0].oid')" "1111111111111111111111111111111111111111" \
    "AC5 the revision's oid is the head oid"
check "$(jf "$REC_P" '.revisions[0].op')" "$P1" "AC5 the op which added it is named"
check "$(jf "$REC_A" "$F_COMMENTS")" "$A1,$A2" "AC5 the comments of an issue, oldest first"
check "$(jf "$REC_A" '.comments[0].revision')" "-" "AC5 an issue comment belongs to no revision"
check "$(jf "$REC_A" '.revisions | length')" "0" "AC5 an issue has no revisions"
check "$(jf "$REC_A" '.copy')" "$NID" "AC5 the copy the chain was read from is named"

# --- AC7 ---------------------------------------------------------------------------------------
check "$(jf "$REC_B" "$F_MARKERS")" "" "AC7 the marker of a redacted comment is gone"
contains "$(jf "$REC_B" "$F_COMMENTS")" "$B2" "AC7 a redacted comment stays in the index"

# --- AC3: the count does not grow with the inventory --------------------------------------------
: >"$CALLS"
state --type issue >/dev/null
CALLS_ISSUE="$(wc -l <"$CALLS")"
: >"$CALLS"
state >/dev/null
CALLS_ALL="$(wc -l <"$CALLS")"
check "$CALLS_ALL" "$CALLS_ISSUE" "AC3 one COB more is not one call more"
if (( CALLS_ALL <= 2 )); then pass "AC3 at most 'rad path' and 'rad self'"
else fail "AC3 the helper spent $CALLS_ALL rad calls"; fi
absent "$(cat "$CALLS")" "cob " "AC3 no 'rad cob' invocation at all"

# --- AC4: --since is a skip --------------------------------------------------------------------
check "$(nonempty "$(state --since "$A1:$A6")")" "2" "AC4 a skipped COB is not reported"
absent "$(state --since "$A1:$A6")" "$A1" "AC4 the head given back suppresses it"
check "$(nonempty "$(state --since "${A1:0:7}:${A6:0:7}")")" "2" "AC4 both sides are prefixes"
HEADS="$(jf "$OUT" '"--since \(.cob):\(.head)"' | tr '\n' ' ')"
check "$(state $HEADS | wc -c | tr -d ' ')" "0" "AC4 every head handed back is an empty stream"
check "$(nonempty "$(state --since "$A1:0000000")")" "3" "AC4 a moved head is reported whole"

# --- AC8: --type and --json --------------------------------------------------------------------
check "$(nonempty "$(state --type issue)")" "2" "AC8 '--type issue' answers the issue COBs"
check "$(nonempty "$(state --type patch)")" "1" "AC8 '--type patch' answers the patch COBs"
check "$(nonempty "$(state --type issue,patch)")" "3" "AC8 '--type' takes a list"
check "$(nonempty "$(state --type all)")" "3" "AC8 '--type all' answers both kinds"
check "$(nonempty "$(state --json)")" "3" "AC8 '--json' states the format the family spells"
check "$(jq -rs 'map(keys | length) | unique | join(",")' <<<"$OUT")" "7" \
    "AC9 every record carries the same seven keys"

# --- AC9: failure semantics --------------------------------------------------------------------
check "$(rc_of --repo "$RID" --type bogus)" "2" "AC9 an unknown --type is a usage error"
check "$(rc_of --repo "$RID" --since nonsense)" "2" "AC9 a malformed --since is a usage error"
check "$(rc_of --repo "$RID" --since ':x')" "2" "AC9 an empty side of --since is a usage error"
check "$(rc_of --repo "$RID" extra)" "2" "AC9 an unexpected argument is a usage error"
check "$(rc_of --repo rad:z3NoSuchRepository)" "3" "AC9 a repository the node does not hold is 3"
check "$( ( cd "$REPO_ROOT" && FAIL_PATH=1 "$BAR" rad_cob state --repo "$RID" >/dev/null 2>&1 ) && echo 0 || echo $?)" \
    "5" "AC9 a node that cannot answer is 5"
ONE_HEAD="--since $A1:$A6"
check "$(state "$ONE_HEAD" "$ONE_HEAD" --type issue | wc -c | tr -d ' ')" "0" \
    "AC9 the same skip twice is still an empty stream"

# --- AC10 --------------------------------------------------------------------------------------
if ( cd "$REPO_ROOT" && "$BAR" helpers --check >/dev/null 2>&1 ); then
    pass "AC10 'bar helpers --check' accepts the module"
else
    fail "AC10 'bar helpers --check' rejects the module"
fi
USAGE="$( ( cd "$REPO_ROOT" && "$BAR" rad_cob state -h 2>&1 ) || true )"
contains "$USAGE" "rad_cob state" "AC10 the usage names the state verb"
contains "$USAGE" "--since <cob>:<op>" "AC10 the usage names --since"

echo
if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "all checks passed"
