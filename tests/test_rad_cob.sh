#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the COB store interface (Bar.d/rad + Bar.d/radicle_lib).
#
# The store is faked twice over: 'rad' is a script that answers from fixtures and records every
# call, and the node's storage is a real git repository with namespace refs -- the copy rule is a
# question about those refs, so it is answered by 'git for-each-ref' and not by a mock.
#
#   AC1  '-h' answers the usage on stdout, exit 0
#   AC2  usage errors exit 2 and keep stdout empty (no verb, an unknown verb, a missing --type or
#        --object, an unknown flag, '--format' other than json, a type the store does not carry)
#   AC3  'list' answers one {"kind","cob","copy"} per COB the store holds, 'copy' the namespace
#        whose tip is the newest (and null where the storage carries no copy)
#   AC4  a type the store cannot answer costs that type only; every type failing is 'unreadable'
#   AC5  'ops' answers the chain oldest first, the store's objects verbatim, and passes '--from'/
#        '--until' through
#   AC6  'document' answers one normalized shape for an issue and for a patch; '--bodies' adds the
#        texts, a redacted comment is an empty body with "redacted": true
#   AC7  the four failure cases are told apart by the exit code and the JSON line on stdout
#   AC8  the copy a read landed on is named, and a read behind the newest copy says so
#   AC9  the helper is registered ('bar helpers --check', and the index names it with its usage)
#
# usage: tests/test_rad_cob.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RID="rad:z3CobTestRepository"
NID_A="z6MkAAAAnamespaceAAAAAAAAAAAAAAAAAAAAAAAAAAA"
NID_B="z6MkBBBBnamespaceBBBBBBBBBBBBBBBBBBBBBBBBBBB"
ISSUE_NEW="aaaa111122223333444455556666777788889999"
ISSUE_BEHIND="bbbb111122223333444455556666777788889999"
ISSUE_NOSTORE="cccc111122223333444455556666777788889999"
PATCH_OK="dddd111122223333444455556666777788889999"
PATCH_ABSENT="eeee111122223333444455556666777788889999"
PATCH_REFUSED="ffff111122223333444455556666777788889999"
ID_COB="9999111122223333444455556666777788889999"

RADHOME="$WORKDIR/radhome"
FIXTURES="$WORKDIR/fixtures"
CALLS="$WORKDIR/calls"
mkdir -p "$RADHOME/storage" "$FIXTURES/bin" "$FIXTURES"
: >"$CALLS"

# --- the fixture store: two namespaces which disagree about how far a COB got -------------------
STORAGE="$RADHOME/storage/${RID#rad:}"
git init -q --bare "$STORAGE"
commit_at() { # <date> - an empty op commit, its id on stdout
    local date="$1"
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git --git-dir="$STORAGE" commit-tree "$(git --git-dir="$STORAGE" hash-object -t tree /dev/null)" -m op
}
OLD_OP="$(commit_at '2026-01-01T00:00:00+00:00')"
NEW_OP="$(commit_at '2026-03-01T00:00:00+00:00')"
NEWEST_OP="$(commit_at '2026-04-01T00:00:00+00:00')"
MID_OP="$(commit_at '2026-02-01T00:00:00+00:00')"
# ISSUE_NEW: namespace B has the newer tip (what a consumer must read)
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID_A/refs/cobs/xyz.radicle.issue/$ISSUE_NEW" "$OLD_OP"
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID_B/refs/cobs/xyz.radicle.issue/$ISSUE_NEW" "$NEW_OP"
# ISSUE_BEHIND: namespace B holds the newest tip, but 'rad' will answer from A's older one
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID_A/refs/cobs/xyz.radicle.issue/$ISSUE_BEHIND" "$MID_OP"
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID_B/refs/cobs/xyz.radicle.issue/$ISSUE_BEHIND" "$NEWEST_OP"
# PATCH_OK: one copy only
git --git-dir="$STORAGE" update-ref "refs/namespaces/$NID_A/refs/cobs/xyz.radicle.patch/$PATCH_OK" "$NEW_OP"

# --- the fixture 'rad' -------------------------------------------------------------------------
cat >"$FIXTURES/bin/rad" <<'FAKE'
#!/usr/bin/env bash
# A fake 'rad': answers from $FIXTURES, records every invocation in $CALLS.
set -uo pipefail
printf '%s\n' "$*" >>"$CALLS"
cmd="${1:-}"
shift || true
case "$cmd" in
path) printf '%s\n' "$RADHOME" ;;
self)
    if [[ -n "${FAIL_SELF:-}" ]]; then
        printf '✗ Error: failed to connect to node: connection refused\n'
        exit 1
    fi
    printf 'Alias fake\nDID did:key:z6MkFake\n'
    ;;
inspect) printf '%s\n' "$RIDFIX" ;;
cob)
    sub="${1:-}"
    shift || true
    type="" object=""
    while (( $# )); do
        case "$1" in
        -r | --repo | -t | --type | -o | --object | --format | --from | --until)
            case "$1" in
            -t | --type) type="${2:-}" ;;
            -o | --object) object="${2:-}" ;;
            esac
            shift 2
            ;;
        *) shift ;;
        esac
    done
    case "$sub" in
    list)
        if [[ -n "${FAIL_LIST:-}" ]]; then
            printf '✗ Error: store: update error: cannot read the stores\n'
            exit 1
        fi
        if [[ -n "${FAIL_LIST_FOR:-}" && ",${FAIL_LIST_FOR}," == *",$type,"* ]]; then
            printf '✗ Error: store: update error: cannot read %s\n' "$type"
            exit 1
        fi
        if [[ -f "$FIXTURES/list.$type" ]]; then cat "$FIXTURES/list.$type"; fi
        ;;
    log)
        if [[ -f "$FIXTURES/log.$type.$object" ]]; then
            cat "$FIXTURES/log.$type.$object"
        else
            printf '✗ Error: object `%s` of type `%s` was not found\n' "$object" "$type"
            exit 1
        fi
        ;;
    show)
        if [[ -f "$FIXTURES/refuse.$type.$object" ]]; then
            cat "$FIXTURES/refuse.$type.$object"
            exit 1
        fi
        if [[ -f "$FIXTURES/show.$type.$object" ]]; then
            cat "$FIXTURES/show.$type.$object"
        else
            printf '✗ Error: object `%s` of type `%s` was not found\n' "$object" "$type"
            exit 1
        fi
        ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$FIXTURES/bin/rad"

# --- the fixture answers -----------------------------------------------------------------------
printf '%s\n%s\n%s\n' "$ISSUE_NEW" "$ISSUE_BEHIND" "$ISSUE_NOSTORE" >"$FIXTURES/list.xyz.radicle.issue"
printf '%s\n%s\n%s\n' "$PATCH_OK" "$PATCH_ABSENT" "$PATCH_REFUSED" >"$FIXTURES/list.xyz.radicle.patch"
printf '%s\n' "$ID_COB" >"$FIXTURES/list.xyz.radicle.id"

# 'ops' answers newest first, as 'rad cob log' does; one op carries a field of its own, which the
# helper must hand on unchanged.
printf '%s\n' \
    '{"id":"'"$NEW_OP"'","actions":[{"type":"comment.react","reaction":"✅","active":true}],"author":"'"$NID_A"'","timestamp":1790000200000,"manifest":{"typeName":"xyz.radicle.issue","version":1}}' \
    '{"id":"'"$OLD_OP"'","actions":[{"type":"comment","body":"*label:wip","replyTo":"'"$OLD_OP"'"}],"author":"'"$NID_A"'","timestamp":1790000100000,"extra":"kept","manifest":{"typeName":"xyz.radicle.issue","version":1}}' \
    >"$FIXTURES/log.xyz.radicle.issue.$ISSUE_NEW"
# ISSUE_BEHIND is answered from A's older tip
printf '%s\n' \
    '{"id":"'"$MID_OP"'","actions":[{"type":"comment","body":"older"}],"author":"'"$NID_A"'","timestamp":1790000050000,"manifest":{"typeName":"xyz.radicle.issue","version":1}}' \
    >"$FIXTURES/log.xyz.radicle.issue.$ISSUE_BEHIND"
printf '%s\n' \
    '{"id":"'"$NEW_OP"'","actions":[{"type":"revision","oid":"'"$NEW_OP"'"}],"author":"'"$NID_B"'","timestamp":1790000200000,"manifest":{"typeName":"xyz.radicle.patch","version":1}}' \
    >"$FIXTURES/log.xyz.radicle.patch.$PATCH_OK"

# an issue document: a root comment, a reply out of insertion order, and a redacted one
cat >"$FIXTURES/show.xyz.radicle.issue.$ISSUE_NEW" <<JSON
{"assignees":["$NID_B"],"title":"a title","state":{"status":"open"},"labels":["improvement"],
 "thread":{"comments":{
   "$NEW_OP":{"author":"$NID_A","reactions":[["$NID_B","👀"]],"resolved":false,"replyTo":"$OLD_OP","body":"the reply",
              "edits":[{"author":"$NID_A","timestamp":1790000200000,"body":"the reply","embeds":[]}]},
   "$MID_OP":{"author":"$NID_B","reactions":[],"resolved":false,"body":null,"edits":[]},
   "$OLD_OP":{"author":"$NID_A","reactions":[],"resolved":false,"body":"the edited description",
              "edits":[{"author":"$NID_A","timestamp":1790000100000,"body":"the description","embeds":[]},
                       {"author":"$NID_A","timestamp":1790000300000,"body":"the edited description","embeds":[]}]}},
  "timeline":["$OLD_OP","$MID_OP","$NEW_OP"]}}
JSON

# a patch document: one revision, one review with a verdict and a comment of its own
cat >"$FIXTURES/show.xyz.radicle.patch.$PATCH_OK" <<JSON
{"title":"a patch","author":{"id":"did:key:$NID_A"},"state":{"status":"open"},"target":"main",
 "labels":[],"assignees":[],"merges":{},
 "revisions":{"$PATCH_OK":{"id":"$PATCH_OK","author":{"id":"did:key:$NID_A"},
   "description":[{"author":"$NID_A","timestamp":1790000200000,"body":"the description","embeds":[]}],
   "base":"$OLD_OP","oid":"$NEW_OP","resolves":[],"reactions":[{"location":null,"emoji":"❓","authors":["$NID_B"]}],
   "discussion":{"comments":{"$OLD_OP":{"author":"$NID_A","reactions":[],"resolved":false,"body":"a revision comment",
       "edits":[{"author":"$NID_A","timestamp":1790000100000,"body":"a revision comment","embeds":[]}]}},
     "timeline":["$OLD_OP"]},
   "reviews":{"$NID_B":{"id":"$MID_OP","author":{"id":"did:key:$NID_B"},"verdict":"accept",
       "summary":[{"author":"$NID_B","timestamp":1790000250000,"body":"Accepting: it does what it says.","embeds":[]}],
       "labels":[],"reactions":[["$NID_A","➖"]],
       "comments":{"comments":{"$NEW_OP":{"author":"$NID_B","reactions":[],"resolved":false,"body":"a review comment",
           "edits":[{"author":"$NID_B","timestamp":1790000260000,"body":"a review comment","embeds":[]}]}},
         "timeline":["$NEW_OP"]}}}}},
 "timeline":["$PATCH_OK","$OLD_OP","$MID_OP","$NEW_OP"]}
JSON

# PATCH_ABSENT: listed, and its document does not materialise.  PATCH_REFUSED: the store refuses.
printf '✗ Error: store: update error: unsupported manifest version\n' >"$FIXTURES/refuse.xyz.radicle.patch.$PATCH_REFUSED"

# --- running the helper ------------------------------------------------------------------------
OUT=""
ERR=""
RC=0
run() { # <args..> - 'bar rad_cob', stdout/stderr split, exit code in RC
    RC=0
    OUT="$(RAD_BIN="$FIXTURES/bin/rad" RADHOME="$RADHOME" FIXTURES="$FIXTURES" CALLS="$CALLS" \
        RIDFIX="$RID" "$BAR" rad_cob "$@" 2>"$WORKDIR/err")" || RC=$?
    ERR="$(cat "$WORKDIR/err")"
}
: >"$CALLS"

echo "AC1 '-h' answers the usage on stdout, exit 0"
run -h
check "$RC" 0 "'-h' exits 0"
contains "$OUT" "usage: bar rad_cob list" "the usage goes to stdout"
absent "$ERR" "usage:" "and nothing goes to stderr"
run --help
check "$RC" 0 "'--help' exits 0 too"
echo

echo "AC2 usage errors exit 2 and keep stdout empty"
run
check "$RC" 2 "no verb is a usage error"
absent "$OUT" "{" "stdout stays empty"
contains "$ERR" "a verb is required" "and the error says which"
run nonsense
check "$RC" 2 "an unknown verb is a usage error"
contains "$ERR" "unknown verb 'nonsense'" "named as such"
run list --type
check "$RC" 2 "'--type' without a value is a usage error"
run list --type changelog
check "$RC" 2 "a type the store does not carry is a usage error"
run ops --type issue
check "$RC" 2 "'ops' without --object is a usage error"
run document --type issue
check "$RC" 2 "'document' without --object is a usage error"
run list --repo
check "$RC" 2 "'--repo' without a value is a usage error"
run list --nope
check "$RC" 2 "an unknown flag is a usage error"
run list --format xml
check "$RC" 2 "'--format xml' is refused (json is the only answer)"
contains "$ERR" "json only" "and says what it prints"
echo

echo "AC3 'list' answers every COB with the copy a read lands on"
run list --repo "$RID"
check "$RC" 0 "'list' answers"
check "$(printf '%s\n' "$OUT" | wc -l)" 7 "one line per COB the store holds"
check "$(printf '%s\n' "$OUT" | jq -r 'select(.kind=="issue" and .cob=="'"$ISSUE_NEW"'") | .copy')" "$NID_B" \
    "the copy is the namespace whose tip is the newest"
check "$(printf '%s\n' "$OUT" | jq -r 'select(.cob=="'"$PATCH_OK"'") | .copy')" "$NID_A" \
    "a single copy names its namespace"
check "$(printf '%s\n' "$OUT" | jq -r 'select(.cob=="'"$ISSUE_NOSTORE"'") | .copy')" "null" \
    "a COB the storage does not carry has no copy (not a guess)"
check "$(printf '%s\n' "$OUT" | jq -r 'select(.kind=="id") | .cob')" "$ID_COB" "the identity COB is listed too"
run list --repo "$RID" --type issue
check "$(printf '%s\n' "$OUT" | wc -l)" 3 "'--type' narrows the answer"
check "$(printf '%s\n' "$OUT" | jq -r '.kind' | sort -u)" "issue" "to the type asked for"
run list --repo "$RID" --type issue,id
check "$(printf '%s\n' "$OUT" | wc -l)" 4 "'--type' takes a list"
run list --repo "$RID" --format json
check "$RC" 0 "'--format json' is the same answer"
echo

echo "AC4 a type which cannot be read costs that type only"
RC=0
OUT="$(FAIL_LIST_FOR=xyz.radicle.patch RAD_BIN="$FIXTURES/bin/rad" RADHOME="$RADHOME" \
    FIXTURES="$FIXTURES" CALLS="$CALLS" RIDFIX="$RID" "$BAR" rad_cob list --repo "$RID" 2>"$WORKDIR/err")" || RC=$?
check "$RC" 0 "one type failing still answers"
contains "$OUT" "$ISSUE_NEW" "the types which answered are in the answer"
contains "$(cat "$WORKDIR/err")" "did not answer for 'patch'" "and the missing one is named"
RC=0
OUT="$(FAIL_LIST=1 RAD_BIN="$FIXTURES/bin/rad" RADHOME="$RADHOME" FIXTURES="$FIXTURES" \
    CALLS="$CALLS" RIDFIX="$RID" "$BAR" rad_cob list --repo "$RID" 2>"$WORKDIR/err")" || RC=$?
check "$RC" 5 "every type failing is 'unreadable'"
check "$(printf '%s' "$OUT" | jq -r .error)" "unreadable" "and says so on stdout"
echo

echo "AC5 'ops' answers the chain oldest first, the store's objects verbatim"
run ops --repo "$RID" --type issue --object "$ISSUE_NEW"
check "$RC" 0 "'ops' answers"
check "$(printf '%s\n' "$OUT" | wc -l)" 2 "one line per op"
check "$(printf '%s\n' "$OUT" | head -1 | jq -r .id)" "$OLD_OP" "oldest first (rad prints newest first)"
check "$(printf '%s\n' "$OUT" | tail -1 | jq -r .id)" "$NEW_OP" "and newest last"
check "$(printf '%s\n' "$OUT" | head -1 | jq -r .extra)" "kept" "a field of the store's own survives"
check "$(printf '%s\n' "$OUT" | head -1 | jq -c .actions)" '[{"type":"comment","body":"*label:wip","replyTo":"'"$OLD_OP"'"}]' \
    "the actions are the store's, unchanged"
: >"$CALLS"
run ops --repo "$RID" --type issue --object "$ISSUE_NEW" --from "$OLD_OP" --until "$NEW_OP"
contains "$(cat "$CALLS")" "cob log -r $RID -t xyz.radicle.issue -o $ISSUE_NEW --format json --from $OLD_OP --until $NEW_OP" \
    "'--from' and '--until' reach the store"
echo

echo "AC6 'document' answers one normalized shape"
run document --repo "$RID" --type issue --object "$ISSUE_NEW" --bodies
check "$RC" 0 "'document' answers for an issue"
DOC="$OUT"
check "$(printf '%s' "$DOC" | jq -r .kind)" "issue" "kind=issue"
check "$(printf '%s' "$DOC" | jq -r .author)" "$NID_A" "the author is the root comment's author, as a NID"
check "$(printf '%s' "$DOC" | jq -r '.comments | length')" 3 "one entry per comment"
check "$(printf '%s' "$DOC" | jq -r '.comments[0].id')" "$OLD_OP" "ordered by the store's timeline"
check "$(printf '%s' "$DOC" | jq -r '.comments[0].root')" "true" "the root comment says so"
check "$(printf '%s' "$DOC" | jq -r '.comments[0].body')" "the edited description" "the body is the current text"
check "$(printf '%s' "$DOC" | jq -r '.comments[0].edits | length')" 2 "and the edits are kept"
check "$(printf '%s' "$DOC" | jq -r '.comments[0].date')" "$(date -d @1790000100 --iso-8601=seconds)" \
    "the date is ISO in the reader's offset"
check "$(printf '%s' "$DOC" | jq -r '.comments[1].redacted')" "true" "a redacted comment is flagged"
check "$(printf '%s' "$DOC" | jq -r '.comments[1].body')" "" "with an empty body, never null"
check "$(printf '%s' "$DOC" | jq -c '.comments[2].reactions')" '[{"emoji":"👀","authors":["'"$NID_B"'"]}]' \
    "reactions are one shape whatever the store's encoding"
check "$(printf '%s' "$DOC" | jq -r '.comments[2].replyTo')" "$OLD_OP" "a reply keeps what it answers"
run document --repo "$RID" --type issue --object "$ISSUE_NEW"
check "$(printf '%s' "$OUT" | jq -r 'has("body")')" "false" "without '--bodies' the document carries no text"
check "$(printf '%s' "$OUT" | jq -r '.comments[0] | has("body")')" "false" "not per comment either"
check "$(printf '%s' "$OUT" | jq -r '.comments[1].redacted')" "true" "but 'redacted' is still answered"
run document --repo "$RID" --type patch --object "$PATCH_OK" --bodies
check "$RC" 0 "'document' answers for a patch"
PDOC="$OUT"
check "$(printf '%s' "$PDOC" | jq -r .kind)" "patch" "kind=patch"
check "$(printf '%s' "$PDOC" | jq -r '.revisions | length')" 1 "the revisions are a list"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].author')" "$NID_A" "the revision author is a bare NID"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].description')" "the description" "the description is the text"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].comments | length')" 1 "its comments are there"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].reviews[0].verdict')" "accept" "its reviews carry the verdict"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].reviews[0].summary')" "Accepting: it does what it says." \
    "and the summary text"
check "$(printf '%s' "$PDOC" | jq -r '.revisions[0].reviews[0].comments | length')" 1 "and a review's comments"
check "$(printf '%s' "$PDOC" | jq -c '.revisions[0].reactions')" '[{"emoji":"❓","authors":["'"$NID_B"'"]}]' \
    "the revision's reactions are normalized too"
echo

echo "AC7 the four failure cases are told apart"
run document --repo "$RID" --type patch --object 1234567
check "$RC" 3 "an id the store does not list is 'notfound'"
check "$(printf '%s' "$OUT" | jq -r .error)" "notfound" "and says so"
contains "$(printf '%s' "$OUT" | jq -r .detail)" "not found" "the store's own line is the detail"
run ops --repo "$RID" --type patch --object "$PATCH_ABSENT"
check "$RC" 4 "an id the store lists whose chain is gone is 'absent'"
check "$(printf '%s' "$OUT" | jq -r .error)" "absent" "and says so"
run document --repo "$RID" --type patch --object "$PATCH_ABSENT"
check "$RC" 4 "'absent' is a document failure too"
run document --repo "$RID" --type patch --object "$PATCH_REFUSED"
check "$RC" 1 "a store which refuses is 'refused'"
check "$(printf '%s' "$OUT" | jq -r .detail)" "✗ Error: store: update error: unsupported manifest version" \
    "with the store's first line unchanged"
run list --repo "rad:z3NoSuchRepository"
check "$RC" 3 "a repository the node holds no storage for is 'notfound'"
RC=0
OUT="$(FAIL_SELF=1 RAD_BIN="$FIXTURES/bin/rad" RADHOME="$WORKDIR/nohome" FIXTURES="$FIXTURES" \
    CALLS="$CALLS" RIDFIX="$RID" "$BAR" rad_cob list --repo "rad:z3NoSuchRepository" 2>"$WORKDIR/err")" || RC=$?
check "$RC" 5 "a node which cannot be reached at all is 'unreadable', never 'gone'"
echo

echo "AC8 the copy a read landed on is named"
run ops --repo "$RID" --type issue --object "$ISSUE_NEW"
contains "$ERR" "read from $NID_B at $NEW_OP" "the copy the read landed on is named"
run document --repo "$RID" --type issue --object "$ISSUE_NEW"
check "$(printf '%s' "$OUT" | jq -r .copy)" "$NID_B" "the document names it in the answer"
run ops --repo "$RID" --type issue --object "$ISSUE_BEHIND"
check "$RC" 0 "a read behind the newest copy still answers"
contains "$ERR" "the newest copy is $NID_B at $NEWEST_OP" "and says it is behind"
contains "$ERR" "the answer is behind" "in so many words"
echo

echo "AC9 the helper is registered"
RC=0
OUT="$("$BAR" helpers --check 2>&1)" || RC=$?
check "$RC" 0 "'bar helpers --check' passes"
contains "$OUT" "OK" "and reports OK"
OUT="$("$BAR" helpers 2>&1)" || true
contains "$OUT" "rad_cob" "the index names rad_cob"
contains "$OUT" "the COB store as one interface" "with its declaration's description"
contains "$OUT" "rad_cob document --repo <rid,path>" "and its usage"
echo

if (( failures )); then
    echo "FAILED: $failures"
    exit 1
fi
echo "OK: rad_cob"
