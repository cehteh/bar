#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the comment metadata helper (Bar.d/rad).
#
# Everything runs against a throw-away project, a fake 'rad' ('RAD_BIN'), a fake fact tool
# ('RAD_TRIAGE_FACTS') and a real git storage built here commit by commit -- no radicle
# installation, no node and no network are needed.  Covered:
#
#   AC1  one item's trusted block is returned, oldest first, exit 0
#   AC2  an untrusted author is dropped, '--trust did:…' admits it (both spellings of the DID)
#   AC3  the block must start at the comment: a marker later in the body, an empty value and a
#        value carrying whitespace are not proposals
#   AC4  the issue description counts (rad calls it the root comment), a patch comment is
#        'item=patch:…', and the query returns its own marker kind only
#   AC5  '--trust contributor(<n>)' admits by authored commits and the reason names the rule
#   AC6  one fact lookup per identity, however many thresholds are asked for
#   AC7  '--last' keeps the newest block of that item, all of its lines
#   AC8  '--json' is one object with bar_rad, query, repo, count and the entries
#   AC9  usage errors exit 2 and say how to call it (no item, two items, unknown query/spec/flag)
#   AC10 a repository the node does not hold exits 3
#   AC11 the helper is registered ('bar helpers --check')
#   AC12 one COB replicated into two namespaces is read once, not once per copy
#   AC13 an item the node does not hold exits 3
#   AC14 only the item asked about is read: another item's blocks never show up in its answer
#   AC15 the item's assignees are trusted (a later assignment makes an earlier proposal count)
#   AC16 an op whose author has no radicle identity is dropped, silently
#   AC17 'contributor(<n>)' without RAD_TRUST_CMD is a usage error, delegates alone need no tool
#   AC18 the parsing edges: CRLF, indented/quoted markers, prose before the block, quotes/unicode
#        in a value, a marker at the end of the body without a trailing newline
#   AC19 a node without 'rad' reports the missing tool (not missing storage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar, the repertoire and the helper
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules radicle_lib rad rad_rules"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (found [$2])"; fi; }
lines_of() { printf '%s\n' "$1" | grep -c . || true; }

echo "=== Testing the comment metadata helper (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
if [[ -n "${RAD_COMMENT_METADATA_TEST_KEEP:-}" ]]; then
    trap 'echo "WORK kept: $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# <dir> - a throw-away project: bar's modules, a Barf and nothing else
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    printf 'rule MAIN: -- true\n' >"$1/Barf"
}

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

RID="rad:zCommentMetadataTest000000000000000"
UNHELD="rad:zCommentMetadataUnheld00000000000"
DELEGATE_NID="z6MkCommentMetadataDelegate000000000000"
OUTSIDER_NID="z6MkCommentMetadataOutsider000000000000"
CONTRIBUTOR_NID="z6MkCommentMetadataContributor00000000"
ISSUE="4444444444444444444444444444444444444444"
OTHER="6666666666666666666666666666666666666666"
PATCH="5555555555555555555555555555555555555555"
ISSUE_ID="${ISSUE:0:7}"
OTHER_ID="${OTHER:0:7}"
PATCH_ID="${PATCH:0:7}"

PROJECT="$WORK/project"
RADHOME="$WORK/radhome"
STORAGE="$RADHOME/storage/${RID#rad:}"
FAKERAD="$WORK/bin/rad"
FACTS="$WORK/bin/triage-facts"

mkdir -p "$PROJECT" "$RADHOME/storage" "$WORK/bin"
mkproject "$PROJECT"
git init -q "$PROJECT"
git -C "$PROJECT" commit -q --allow-empty -m "fixture"
git init -q --bare "$STORAGE"

# the fake 'rad': the node path, the identity of this checkout, the delegates of the fixture
cat >"$FAKERAD" <<EOF
#!/bin/sh
case "\$1" in
path) printf '%s\n' "$RADHOME" ;;
inspect)
    case "\$2" in
    --rid) printf '%s\n' "$RID" ;;
    "$RID") printf 'did:key:%s (delegate)\n' "$DELEGATE_NID" ;;
    "$UNHELD") printf 'did:key:%s (delegate)\n' "$DELEGATE_NID" ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$FAKERAD"

# the fake facts command (RAD_TRUST_CMD): the commits each identity authored *as itself*, and it
# counts its own invocations
cat >"$FACTS" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/facts.calls"
nid=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    --author) nid="\$2"; shift 2 ;;
    *) shift ;;
    esac
done
case "\$nid" in
"$OUTSIDER_NID") authored=9 ;;
"$CONTRIBUTOR_NID") authored=42 ;;
"$DELEGATE_NID") authored=7 ;;
*) authored=1 ;;
esac
printf '{"author":{"nid":"%s","commits_as_identity":%s,"total_authored":%s},"contributor":false,"rid":"%s","threshold":10,"verdict":"untrusted"}\n' \
    "\$nid" "\$authored" "\$authored" "$RID"
EOF
chmod +x "$FACTS"
: >"$WORK/facts.calls"

# <ns> <type> <cob> <subject> <payload> [parent] [name] [nid] [date] - one COB op, prints its sha
op() {
    local ns="$1" type="$2" cob="$3" subject="$4" payload="$5" parent="${6:-}"
    local name="${7:-delegate}" nid="${8:-$DELEGATE_NID}" date="${9:-2026-10-11T10:00:00+02:00}"
    local blob tree sha
    local -a args=()
    blob="$(printf '%s' "$payload" | git --git-dir="$STORAGE" hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\t0\n' "$blob" | git --git-dir="$STORAGE" mktree)"
    [[ -n "$parent" ]] && args+=(-p "$parent")
    sha="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$name@$nid" GIT_AUTHOR_DATE="$date" \
           GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$name@$nid" GIT_COMMITTER_DATE="$date" \
           git --git-dir="$STORAGE" commit-tree "$tree" ${args[@]+"${args[@]}"} -m "$subject")"
    git --git-dir="$STORAGE" update-ref "refs/namespaces/$ns/refs/cobs/xyz.radicle.$type/$cob" "$sha"
    printf '%s' "$sha"
}

# <ns> <type> <cob> - point a second namespace at the same tip (rad replicates the chain)
replicate() {
    local ns="$1" type="$2" cob="$3" sha
    sha="$(git --git-dir="$STORAGE" rev-parse "refs/namespaces/$DELEGATE_NID/refs/cobs/xyz.radicle.$type/$cob")"
    git --git-dir="$STORAGE" update-ref "refs/namespaces/$ns/refs/cobs/xyz.radicle.$type/$cob" "$sha"
}

# -- the issue: the description proposes a label, a delegate proposes later, an outsider too ----
ISSUE_TIP="$(op "$DELEGATE_NID" issue "$ISSUE" "Create issue" \
    '{"body":"*label:idea\nA maintenance command should apply the trusted proposals.","type":"issue","title":"apply the metadata comments"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:00:00+02:00")"
ISSUE_TIP="$(op "$DELEGATE_NID" issue "$ISSUE" "Comment" \
    '{"body":"*label:improvement\n*assign:cehteh\nreads as an improvement, and I would take it.","type":"comment"}' \
    "$ISSUE_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:05:00+02:00")"
ISSUE_TIP="$(op "$OUTSIDER_NID" issue "$ISSUE" "Comment" \
    '{"body":"*label:rejected\nnot from a trusted source","type":"comment"}' \
    "$ISSUE_TIP" "outsider" "$OUTSIDER_NID" "2026-10-11T10:06:00+02:00")"
ISSUE_TIP="$(op "$DELEGATE_NID" issue "$ISSUE" "Comment" \
    '{"body":"*label:bug\n*label:wip\nthe newest block, two labels","type":"comment"}' \
    "$ISSUE_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:07:00+02:00")"
# the same chain replicated into the outsider's namespace: read once, not twice
replicate "$OUTSIDER_NID" issue "$ISSUE"

# -- a second issue: its blocks must never show up in the first one's answer ---------------------
OTHER_TIP="$(op "$DELEGATE_NID" issue "$OTHER" "Create issue" \
    '{"body":"*label:notmine\nanother item entirely","type":"issue","title":"the other item"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:07:30+02:00")"

# -- a third issue: its author is untrusted until a delegate assigns the issue to them -------------
THIRD="8888888888888888888888888888888888888888"
THIRD_ID="${THIRD:0:7}"
THIRD_TIP="$(op "$OUTSIDER_NID" issue "$THIRD" "Create issue" \
    '{"body":"*label:wip\nI am working on this, please assign me.","type":"issue","title":"assigned later"}' \
    "" "outsider" "$OUTSIDER_NID" "2026-10-11T10:13:00+02:00")"
# … and an op whose author is a plain git user, with no radicle identity at all
THIRD_TIP="$(op "$DELEGATE_NID" issue "$THIRD" "Comment" \
    '{"body":"*label:done\n*assign:somebody\nno radicle identity behind this op","type":"comment"}' \
    "$THIRD_TIP" "githuman" "example.com" "2026-10-11T10:14:00+02:00")"

# -- a fourth issue: the parsing edges (CRLF, quotes/unicode, prose that looks like a marker) -----
EDGES="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EDGES_ID="${EDGES:0:7}"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Create issue" \
    '{"body":"the parsing edges","type":"issue","title":"parsing edges"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:16:00+02:00")"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Comment" \
    '{"body":"*label:crlf\r\n*label:second\r\nafter\r\n","type":"comment"}' \
    "$EDGES_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:17:00+02:00")"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Comment" \
    '{"body":"*label:a\"b\\c\u2764\nquotes, backslash and unicode","type":"comment"}' \
    "$EDGES_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:18:00+02:00")"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Comment" \
    '{"body":"  *label:indented\n> *label:quoted\n*label:after-prose","type":"comment"}' \
    "$EDGES_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:19:00+02:00")"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Comment" \
    '{"body":"\n*label:after-blank\n","type":"comment"}' \
    "$EDGES_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:20:00+02:00")"
EDGES_TIP="$(op "$DELEGATE_NID" issue "$EDGES" "Comment" \
    '{"body":"*label:eof","type":"comment"}' \
    "$EDGES_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:21:00+02:00")"

# -- the patch: a delegate comment carries a marker, and the tricky bodies -----------------------
PATCH_TIP="$(op "$DELEGATE_NID" patch "$PATCH" "Initial revision" \
    '{"type":"revision","description":"a patch","oid":"0000000000000000000000000000000000000000","base":"1111111111111111111111111111111111111111"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:08:00+02:00")"
PATCH_TIP="$(op "$DELEGATE_NID" patch "$PATCH" "Comment" \
    '{"body":"*label:bug\nfits the bug chain","type":"comment"}' \
    "$PATCH_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:09:00+02:00")"
PATCH_TIP="$(op "$DELEGATE_NID" patch "$PATCH" "Comment" \
    '{"body":"a reply which mentions\n*label:notaproposal\nand nothing else","type":"comment"}' \
    "$PATCH_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:10:00+02:00")"
PATCH_TIP="$(op "$DELEGATE_NID" patch "$PATCH" "Comment" \
    '{"body":"*label:\n*label:two words\nboth are not proposals","type":"comment"}' \
    "$PATCH_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:11:00+02:00")"
# an edited body is the newest word on that comment
PATCH_TIP="$(op "$DELEGATE_NID" patch "$PATCH" "Edit comment" \
    '{"body":"*label:improvement\n*unassign:ct_vibes\nedited","type":"comment"}' \
    "$PATCH_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:12:00+02:00")"

# -- running the helper --------------------------------------------------------------------------

RC=0
OUT=""
TRUST_CMD="$FACTS"                       ## what RAD_TRUST_CMD is set to for the runs below
run() { # <dir> <args>.. - stdout, exit code in RC
    OUT=""
    RC=0
    OUT="$(cd "$1" && RAD_BIN="$FAKERAD" RAD_TRUST_CMD="$TRUST_CMD" "$BAR" "${@:2}" 2>/dev/null)" || RC=$?
}
err() { # <dir> <args>.. - stderr only
    OUT=""
    RC=0
    OUT="$(cd "$1" && RAD_BIN="$FAKERAD" RAD_TRUST_CMD="$TRUST_CMD" "$BAR" "${@:2}" 2>&1 >/dev/null)" || RC=$?
}

# ------------------------------------------------------------------------------------------------

echo "AC1 one item's trusted block is returned, oldest first"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 4 "four trusted label entries of that item"
contains "$OUT" "label item=issue:$ISSUE_ID author=delegate did=did:key:$DELEGATE_NID trust=delegate" "the delegate's lines are named with their trust"
check "$(printf '%s\n' "$OUT" | grep -n "value=idea" | cut -d: -f1)" 1 "oldest first (the description leads)"
absent "$OUT" "value=rejected" "the outsider's proposal is not in the default answer"
echo

echo "AC2 an untrusted author is dropped, '--trust did:…' admits it"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "did:$OUTSIDER_NID"
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 5 "five entries with the outsider admitted"
contains "$OUT" "trust=named" "the named identity is trusted by name"
contains "$OUT" "value=rejected" "…and its proposal is there"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "did:key:$OUTSIDER_NID"
check "$(lines_of "$OUT")" 5 "the 'did:key:' spelling names the same identity"
echo

echo "AC3 the block must start at the comment, values are single words"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query label
check "$(lines_of "$OUT")" 2 "the patch's two real label blocks"
absent "$OUT" "value=notaproposal" "a marker later in the body is prose"
absent "$OUT" "value=two" "a value with whitespace is dropped"
check "$(printf '%s\n' "$OUT" | grep -c 'value=$' || true)" 0 "an empty value is dropped"
contains "$OUT" "value=improvement" "the edited body is the newest word on that comment"
echo

echo "AC4 the description counts, a patch is 'item=patch:…', and the query returns its own kind"
contains "$OUT" "item=patch:$PATCH_ID" "the patch comment is reported as a patch item"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query assign
check "$(lines_of "$OUT")" 1 "one assign proposal on the issue"
contains "$OUT" "value=cehteh" "the assignee travels through"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query unassign
check "$(lines_of "$OUT")" 0 "the issue proposes no unassign — kinds do not leak into each other"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query unassign
check "$(lines_of "$OUT")" 1 "the patch's unassign is there when it is asked for"
contains "$OUT" "value=ct_vibes" "and it names the identity to drop"
echo

echo "AC5 '--trust contributor(<n>)' admits by authored commits and names the rule"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(20)"
check "$(lines_of "$OUT")" 4 "an outsider below the threshold stays out"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(5)"
check "$(lines_of "$OUT")" 5 "the outsider is admitted at 5 (it has 9)"
contains "$OUT" "trust=contributor(5)" "and the reason names that threshold"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(5),contributor(20)"
check "$(lines_of "$OUT")" 5 "a comma separated list works too"
contains "$OUT" "trust=contributor(5)" "the first matching threshold is the reason"
echo

echo "AC6 one fact lookup per identity"
: >"$WORK/facts.calls"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(5)" --trust "contributor(20)"
check "$(grep -c . "$WORK/facts.calls" || true)" 1 "one lookup for the one identity which is not a delegate"
echo

echo "AC7 '--last' keeps the newest block of that item, all of its lines"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --last
check "$(lines_of "$OUT")" 2 "the issue's newest block is a two-label block"
contains "$OUT" "value=bug" "…with its first line"
contains "$OUT" "value=wip" "…and its second"
absent "$OUT" "value=idea" "the older block is gone"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query label --last
check "$(lines_of "$OUT")" 1 "the patch's newest block is one label"
echo

echo "AC8 '--json' is one complete object"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --json
check "$RC" 0 "exit 0"
check "$(printf '%s' "$OUT" | jq -r '.bar_rad')" 1 "bar_rad is 1"
check "$(printf '%s' "$OUT" | jq -r '.query')" label "the query is echoed"
check "$(printf '%s' "$OUT" | jq -r '.repo')" "$RID" "the repository is echoed"
check "$(printf '%s' "$OUT" | jq -r '.count')" 4 "four entries"
check "$(printf '%s' "$OUT" | jq -r '.entries[0].value')" idea "the entries carry the values, oldest first"
check "$(printf '%s' "$OUT" | jq -r '.entries[0].did')" "did:key:$DELEGATE_NID" "…and the identity as a DID"
check "$(printf '%s' "$OUT" | jq -r '.assignees | length')" 0 "the item has no assignee"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label
contains "$OUT" "did=did:key:$DELEGATE_NID" "the text form prints the same DID as the JSON"
echo

echo "AC9 usage errors exit 2"
run "$PROJECT" rad_comment_metadata
check "$RC" 2 "no item, no query"
err "$PROJECT" rad_comment_metadata
contains "$OUT" "usage: rad_comment_metadata <item>" "and it says how to call it"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID"
check "$RC" 2 "no query"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" "$PATCH_ID" --query label
check "$RC" 2 "two items"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query bogus
check "$RC" 2 "an unknown query"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "somebody"
check "$RC" 2 "an unknown trust spec"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(x)"
check "$RC" 2 "a threshold which is not a number"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --nonsense
check "$RC" 2 "an unknown argument"
echo

echo "AC10 a repository the node does not hold exits 3"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --repo "$UNHELD"
check "$RC" 3 "no storage for that RID"
err "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --repo "$UNHELD"
contains "$OUT" "holds no storage" "and it says which repository"
echo

echo "AC11 the helper is registered"
OUT=""
RC=0
OUT="$(RAD_BIN="$FAKERAD" RAD_TRUST_CMD="$FACTS" "$BAR" helpers --check 2>&1)" || RC=$?
check "$RC" 0 "'bar helpers --check' passes"
contains "$OUT" "OK" "and reports OK"
echo

echo "AC12 a replicated COB is read once"
check "$(git --git-dir="$STORAGE" for-each-ref --format='%(refname)' | grep -c "/refs/cobs/xyz.radicle.issue/$ISSUE")" 2 \
    "the fixture really has the chain in two namespaces"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label
check "$(printf '%s\n' "$OUT" | grep -c "value=idea")" 1 "the description is reported once"
echo

echo "AC13 an item the node does not hold exits 3"
run "$PROJECT" rad_comment_metadata "9999999" --query label
check "$RC" 3 "no such issue or patch"
err "$PROJECT" rad_comment_metadata "9999999" --query label
contains "$OUT" "holds no issue or patch" "and it says which item"
echo

echo "AC14 only the item asked about is read"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label
absent "$OUT" "value=notmine" "the other issue's block is not in this item's answer"
run "$PROJECT" rad_comment_metadata "$OTHER_ID" --query label
check "$(lines_of "$OUT")" 1 "the other item answers for itself"
contains "$OUT" "value=notmine" "…with its own block"
echo

echo "AC15 an assignee is trusted -- read now, not stored"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query label
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 0 "the outsider's proposal is dropped while nobody is assigned"
THIRD_TIP="$(op "$DELEGATE_NID" issue "$THIRD" "Assign" \
    "{\"assignees\":[\"did:key:$OUTSIDER_NID\"],\"type\":\"assign\"}" \
    "$THIRD_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:15:00+02:00")"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query label
check "$(lines_of "$OUT")" 1 "…and trusted once the item is assigned to its author"
contains "$OUT" "trust=assignee" "the reason names the assignment"
contains "$OUT" "value=wip" "with the proposal they made"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query label --json
check "$(printf '%s' "$OUT" | jq -r '.assignees[0]')" "did:key:$OUTSIDER_NID" "and '--json' reports the assignee the trust came from"
echo

echo "AC16 an op without a radicle identity is dropped"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query label
absent "$OUT" "value=done" "a proposal from a plain git author is not returned"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query assign
check "$RC" 0 "and that is not an error"
check "$(lines_of "$OUT")" 0 "nor is their assignment proposal"
echo

echo "AC17 a contributor threshold needs the facts command"
TRUST_CMD=""
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(5)"
check "$RC" 2 "asking for a threshold without RAD_TRUST_CMD"
err "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "contributor(5)"
contains "$OUT" "RAD_TRUST_CMD" "and it names what is missing"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --trust "did:$OUTSIDER_NID"
check "$RC" 0 "a named identity needs no facts command"
TRUST_CMD="$FACTS"
echo

echo "AC18 the parsing edges: CRLF, prose that looks like a marker, quotes and unicode"
run "$PROJECT" rad_comment_metadata "$EDGES_ID" --query label
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 4 "four proposals out of the five edge bodies"
contains "$OUT" "value=crlf" "a CRLF body yields its marker"
check "$(printf '%s\n' "$OUT" | grep -c $'\r' || true)" 0 "and the carriage returns are gone"
contains "$OUT" "value=second" "…its second block line too"
absent "$OUT" "value=indented" "an indented marker is prose"
absent "$OUT" "value=quoted" "a quoted marker is prose"
absent "$OUT" "value=after-prose" "so is one that follows prose"
absent "$OUT" "value=after-blank" "and one that follows a blank line"
contains "$OUT" "value=eof" "a marker at the end of the body without a newline still counts"
run "$PROJECT" rad_comment_metadata "$EDGES_ID" --query label --json
check "$RC" 0 "the JSON is valid with a quote, a backslash and unicode in a value"
check "$(printf '%s' "$OUT" | jq -r '.entries[] | select(.value | test("a\"b\\\\c")) | .value')" 'a"b\c❤' \
    "the value survives escaping byte for byte"
echo

echo "AC19 a node without 'rad' says so"
OUT=""
RC=0
OUT="$(cd "$PROJECT" && RAD_BIN=/nonexistent/rad RAD_TRUST_CMD="$FACTS" "$BAR" rad_comment_metadata "$ISSUE_ID" --query label 2>&1 >/dev/null)" || RC=$?
check "$RC" 1 "exit 1"
contains "$OUT" "is not installed" "and it names the missing tool, not the storage"
echo

echo
if (( failures )); then
    echo "=== $failures check(s) failed ==="
    exit 1
fi
echo "=== all checks passed ==="
