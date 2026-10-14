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
#   AC20 the key form is open ('*<key>:<value>'): any key is read back -- keys with no registered
#        effect included -- and the bounds of a key end the block like any other non-marker line
#   AC21 '--query' is optional (no key at all answers every key) and repeatable; every line names
#        its own key
#   AC22 two markers of one second come back in chain order, not in hash order; '--last' is the
#        last record also when the smaller sha is the newer one
#   AC23 '--last' is per key (a key nobody asked for is not answered), and a newest block nobody can
#        be attributed to is skipped so that an older trusted block still applies
#   AC24 'rad_set_label' makes exactly one 'rad issue|patch label' write with the argv it promises,
#        travels a RID as '-r', reports a refusal rad made and refuses a usage error; an empty
#        '<add>' is a removal alone -- no '--add' in the write, no 'add=' in the report
#   AC25 'rad_assign'/'rad_unassign' resolve an alias through the facts command before writing the
#        DID, take a DID as it stands, and refuse an alias nobody knows without writing anything
#   AC26 'rad_apply_from_comments' applies the trusted proposals of an item: the new label carries
#        the previous chain state out with it, a label the item already says is skipped (the stored
#        state is read fresh), '--dry-run' reports the writes and makes none
#   AC27 a key with no registered effect is reported and never applied, and a block whose author is
#        not trusted never reaches an applier at all
#   AC28 'rad_reaction' compares against the caller's own reduced state: our newest live marker is
#        the state (an op stream entry its author took back is not, and neither is another identity's
#        marker), a mismatch writes nothing, and the whole transition -- the issue itself reached
#        through its root comment included -- is one 'rad cob update' whose action list carries what
#        rad writes itself, ids in the full form the store validates ('invalid length')
#   AC29 a transition takes the marker it replaces back in the same op, at every level, and an empty
#        reaction takes one back and sets nothing (which the typed issue command cannot do at all)
#   AC30 a revision id names the patch COB that holds it, and a comment of that revision is written
#        against the revision the comment itself names
#   AC31 what the store would refuse is refused before any call (a two codepoint emoji, a word, an
#        empty reaction without an expectation), and so is a usage error or an id nobody holds
#   AC32 'rad_rm_label' removes every stored label a glob matches in one write: the glob is anchored
#        at both ends, a glob which matches nothing writes nothing and is reported (exit 0), the
#        '<item>' forms and '--repo' are the write layer's, and the helper is registered

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
SELF_NID="z6MkCommentMetadataSelf0000000000000000"
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

mkdir -p "$PROJECT" "$RADHOME/storage" "$WORK/bin" "$WORK/labels.issue" "$WORK/labels.patch"
mkproject "$PROJECT"
git init -q "$PROJECT"
git -C "$PROJECT" commit -q --allow-empty -m "fixture"
git init -q --bare "$STORAGE"

# the fake 'rad': the node path, the identity of this checkout, the delegates of the fixture, the
# label table the stored state is read from, and a recorder for every write it is asked to make --
# 'rad cob update' records its call beside the action file it was handed, which is what the reaction
# tests assert on (the file name is a mktemp path and would make an exact match brittle)
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
self)
    case "\$2" in
    --did) printf 'did:key:%s\n' "$SELF_NID" ;;
    --alias) printf 'self\n' ;;
    esac
    ;;
cob)
    if [ "\$2" = update ]; then
        shift 2
        t=""; o=""; m=""; r=""; f=""
        while [ \$# -gt 0 ]; do
            case "\$1" in
            --type) t="\$2"; shift 2 ;;
            --object) o="\$2"; shift 2 ;;
            --message) m="\$2"; shift 2 ;;
            -r) r="\$2"; shift 2 ;;
            *) f="\$1"; shift ;;
            esac
        done
        printf 'cob update --type %s --object %s --message %s%s\n' "\$t" "\$o" "\$m" "\${r:+ -r \$r}" >>"$WORK/rad.calls"
        cat "\$f" >>"$WORK/rad.actions" 2>/dev/null
    fi
    ;;
issue | patch)
    case "\$2" in
    list)
        printf '│ ●   ID        Labels                     │\n'
        for file in "$WORK/labels.\$1"/*; do
            [ -e "\$file" ] || continue
            printf '│ ●   %s   %s   │\n' "\${file##*/}" "\$(cat "\$file")"
        done
        ;;
    label | assign | react | state | comment)
        printf '%s\n' "\$*" >>"$WORK/rad.calls"
        if [ -f "$WORK/refuse" ] && printf '%s' "\$*" | grep -qF "\$(cat "$WORK/refuse")"; then
            printf 'refused: %s\n' "\$*" >&2
            exit 1
        fi
        ;;
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
cehteh) nid="$DELEGATE_NID" ;;
esac
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
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"

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

# -- a fifth issue: the generic '<key>:<value>' form and the bounds of a key ----------------------
KEYS="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
KEYS_ID="${KEYS:0:7}"
KEYS_TIP="$(op "$DELEGATE_NID" issue "$KEYS" "Create issue" \
    '{"body":"*issue:5555555\n*Note:hello\n*label:seen\nthe key form is the open one","type":"issue","title":"any key"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:22:00+02:00")"
# a key which does not start with a letter is no marker: the block ends at that line
KEYS_TIP="$(op "$DELEGATE_NID" issue "$KEYS" "Comment" \
    '{"body":"*9bad:no\n*label:after-digits","type":"comment"}' \
    "$KEYS_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:23:00+02:00")"
# and neither is a key carrying a character outside the charset, or no key at all
KEYS_TIP="$(op "$DELEGATE_NID" issue "$KEYS" "Comment" \
    '{"body":"*weird.key:v\n*label:after-dot","type":"comment"}' \
    "$KEYS_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:24:00+02:00")"
KEYS_TIP="$(op "$DELEGATE_NID" issue "$KEYS" "Comment" \
    '{"body":"*:novalue\n*label:after-keyless","type":"comment"}' \
    "$KEYS_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:25:00+02:00")"
# an empty value and one carrying whitespace are dropped, and the block goes on
KEYS_TIP="$(op "$DELEGATE_NID" issue "$KEYS" "Comment" \
    '{"body":"*label:\n*label:two words\n*label:after-empty","type":"comment"}' \
    "$KEYS_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:26:00+02:00")"

# -- a sixth issue: two marker ops in one second, in the opposite order than their hashes ---------
ORDER="cccccccccccccccccccccccccccccccccccccccc"
ORDER_ID="${ORDER:0:7}"
ORDER_TIP="$(op "$DELEGATE_NID" issue "$ORDER" "Create issue" \
    '{"body":"*label:ordering-filler\none block, so that the item is not empty","type":"issue","title":"ordering"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:27:00+02:00")"
# The defect this pins: two markers written in the same second were ordered by their op sha.  So the
# fixture has to be one where the hash order is the *reverse* of the chain order -- the newer record
# with the smaller sha -- else it would pass either way.  The nonce varies the payload until a pair
# is found (and the loop is bounded: not finding one is a broken fixture, and says so).
ORDER_A=""
ORDER_B=""
nonce=0
while (( nonce < 60 )); do
    ORDER_A="$(op "$DELEGATE_NID" issue "$ORDER" "Comment" \
        "{\"body\":\"*label:first\nnonce $nonce\",\"type\":\"comment\"}" \
        "$ORDER_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:28:00+02:00")"
    ORDER_B="$(op "$DELEGATE_NID" issue "$ORDER" "Comment" \
        "{\"body\":\"*label:second\nnonce $nonce\",\"type\":\"comment\"}" \
        "$ORDER_A" "delegate" "$DELEGATE_NID" "2026-10-11T10:28:00+02:00")"
    if [[ "$ORDER_B" < "$ORDER_A" ]]; then
        break
    fi
    nonce=$(( nonce + 1 ))
done

# -- an eighth issue and a second patch: the reaction markers ------------------------------------
# The reader never sees a reaction as a proposal (its subject carries no body), which is why they can
# live in the same COBs: what is read back here is the reaction API's own business.
REACT="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
REACT_ID="${REACT:0:7}"
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "Create issue" \
    '{"body":"no proposals here at all","type":"issue","title":"reactions"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:40:00+02:00")"
REACT_COMMENT="$(op "$DELEGATE_NID" issue "$REACT" "Comment" \
    '{"body":"a comment to react to","type":"comment"}' \
    "$REACT_TIP" "delegate" "$DELEGATE_NID" "2026-10-11T10:41:00+02:00")"
# a marker of the delegate's: not ours, so it is not the state this caller compares
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "React" \
    "{\"active\":true,\"id\":\"$REACT\",\"reaction\":\"✅\",\"type\":\"comment.react\"}" \
    "$REACT_COMMENT" "delegate" "$DELEGATE_NID" "2026-10-11T10:42:00+02:00")"
# ours: claimed, then superseded -- the issue level has no way to take the old one back
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "React" \
    "{\"active\":true,\"id\":\"$REACT\",\"reaction\":\"👀\",\"type\":\"comment.react\"}" \
    "$REACT_TIP" "self" "$SELF_NID" "2026-10-11T10:43:00+02:00")"
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "React" \
    "{\"active\":true,\"id\":\"$REACT\",\"reaction\":\"➖\",\"type\":\"comment.react\"}" \
    "$REACT_TIP" "self" "$SELF_NID" "2026-10-11T10:44:00+02:00")"
# ours: an add and its withdrawal -- the op stream carries the marker, the state does not
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "React" \
    "{\"active\":true,\"id\":\"$REACT\",\"reaction\":\"🔧\",\"type\":\"comment.react\"}" \
    "$REACT_TIP" "self" "$SELF_NID" "2026-10-11T10:45:00+02:00")"
REACT_TIP="$(op "$DELEGATE_NID" issue "$REACT" "React" \
    "{\"active\":false,\"id\":\"$REACT\",\"reaction\":\"🔧\",\"type\":\"comment.react\"}" \
    "$REACT_TIP" "self" "$SELF_NID" "2026-10-11T10:46:00+02:00")"

RATCH="ffffffffffffffffffffffffffffffffffffffff"
RATCH_ID="${RATCH:0:7}"
RATCH_ROOT="$(op "$DELEGATE_NID" patch "$RATCH" "Initial revision" \
    '{"type":"revision","description":"a patch to react to","oid":"0000000000000000000000000000000000000000","base":"1111111111111111111111111111111111111111"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:47:00+02:00")"
RATCH_COMMENT="$(op "$DELEGATE_NID" patch "$RATCH" "Comment" \
    "{\"body\":\"a comment on the patch\",\"revision\":\"$RATCH_ROOT\",\"type\":\"comment\"}" \
    "$RATCH_ROOT" "delegate" "$DELEGATE_NID" "2026-10-11T10:48:00+02:00")"
RATCH_REVISION="$(op "$DELEGATE_NID" patch "$RATCH" "Add revision" \
    '{"type":"revision","description":"the second one","oid":"2222222222222222222222222222222222222222","base":"1111111111111111111111111111111111111111"}' \
    "$RATCH_COMMENT" "delegate" "$DELEGATE_NID" "2026-10-11T10:49:00+02:00")"
# our marker on the patch's root revision
RATCH_TIP="$(op "$DELEGATE_NID" patch "$RATCH" "React" \
    "{\"active\":true,\"revision\":\"$RATCH_ROOT\",\"reaction\":\"✅\",\"type\":\"revision.react\"}" \
    "$RATCH_REVISION" "self" "$SELF_NID" "2026-10-11T10:50:00+02:00")"

# -- a seventh issue: its newest label block is an outsider's, which only a trust spec hands over ---
OWN="dddddddddddddddddddddddddddddddddddddddd"
OWN_ID="${OWN:0:7}"
OWN_TIP="$(op "$DELEGATE_NID" issue "$OWN" "Create issue" \
    '{"body":"*label:carried\nan outsider proposes the next state","type":"issue","title":"an outsider proposes"}' \
    "" "delegate" "$DELEGATE_NID" "2026-10-11T10:30:00+02:00")"
OWN_TIP="$(op "$OUTSIDER_NID" issue "$OWN" "Comment" \
    '{"body":"*label:outsider-wip\nfrom an identity nobody trusts here","type":"comment"}' \
    "$OWN_TIP" "outsider" "$OUTSIDER_NID" "2026-10-11T10:31:00+02:00")"

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
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" "$PATCH_ID" --query label
check "$RC" 2 "two items"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query "9bad"
check "$RC" 2 "a key which cannot stand at the start of a marker"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query "weird.key"
check "$RC" 2 "a key carrying a character no marker can carry"
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

echo "AC20 the key form is open: any key is read back, and the bounds of a key end the block"
run "$PROJECT" rad_comment_metadata "$KEYS_ID"
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 4 "four proposals: issue, Note and two labels"
contains "$OUT" "issue item=issue:$KEYS_ID" "a key with no registered effect is read back"
contains "$OUT" "value=5555555" "and carries its value"
contains "$OUT" "Note item=issue:$KEYS_ID" "a key is read as it is written (a capital letter is a key too)"
run "$PROJECT" rad_comment_metadata "$KEYS_ID" --query Note
check "$(lines_of "$OUT")" 1 "asking for that key answers for it alone"
absent "$OUT" "value=seen" "…and no other key leaks into the answer"
run "$PROJECT" rad_comment_metadata "$KEYS_ID" --query label
check "$(lines_of "$OUT")" 2 "two label blocks of that item"
contains "$OUT" "value=after-empty" "an empty value and one with whitespace are dropped, the block goes on"
absent "$OUT" "value=after-digits" "a key not starting with a letter is no marker: the block ends"
absent "$OUT" "value=after-dot" "so is a key with a character outside the charset"
absent "$OUT" "value=after-keyless" "and so is a line without a key at all"
echo

echo "AC21 '--query' is optional and repeatable"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID"
check "$RC" 0 "no --query at all answers every key"
check "$(lines_of "$OUT")" 5 "the issue's four labels, its assign and no untrusted one"
contains "$OUT" "assign item=issue:$ISSUE_ID" "the line names its own key, not the query"
contains "$OUT" "label item=issue:$ISSUE_ID" "…for every key of the block"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --query unassign
check "$RC" 0 "two keys in one call exit 0"
check "$(lines_of "$OUT")" 4 "four labels and no unassign on the issue"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query label --query unassign
check "$(lines_of "$OUT")" 3 "the patch's two labels and its one unassign"
run "$PROJECT" rad_comment_metadata "$ISSUE_ID" --query label --query label
check "$(lines_of "$OUT")" 4 "a key asked for twice is not answered twice"
echo

echo "AC22 two markers of one second come back in chain order, not in hash order"
check "$(git --git-dir="$STORAGE" show -s --format=%at "$ORDER_A")" \
    "$(git --git-dir="$STORAGE" show -s --format=%at "$ORDER_B")" \
    "the fixture really holds the two ops in one second"
if [[ "$ORDER_B" < "$ORDER_A" ]]; then
    pass "and the newer op really carries the smaller sha (as the defect needs)"
else
    fail "the fixture could not be built: the newer op's sha is not the smaller one"
fi
run "$PROJECT" rad_comment_metadata "$ORDER_ID" --query label
FIRST_AT="$(printf '%s\n' "$OUT" | grep -n "value=first" | cut -d: -f1)"
SECOND_AT="$(printf '%s\n' "$OUT" | grep -n "value=second" | cut -d: -f1)"
if (( ${FIRST_AT:-0} > 0 && ${FIRST_AT:-0} < ${SECOND_AT:-0} )); then
    pass "the answer is in chain order (the older marker first, line $FIRST_AT then $SECOND_AT)"
else
    fail "the answer is not in chain order (first at line ${FIRST_AT:-none}, second at ${SECOND_AT:-none})"
fi
run "$PROJECT" rad_comment_metadata "$ORDER_ID" --query label --last
check "$(lines_of "$OUT")" 1 "one marker is the newest"
contains "$OUT" "value=second" "--last takes the last record of the chain, not the smallest op sha"
run "$PROJECT" rad_comment_metadata "$ORDER_ID" --query label --last --json
check "$(printf '%s' "$OUT" | jq -r '.entries[0].op')" "$ORDER_B" "and it is that op which is named"
echo

echo "AC23 '--last' is per key, and a newest block nobody can be attributed to is skipped"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query label --last
check "$(lines_of "$OUT")" 1 "the patch's newest label block is one label"
contains "$OUT" "value=improvement" "the edited body is the newest word"
absent "$OUT" "value=ct_vibes" "the unassign of that same block is not applied by a label query"
run "$PROJECT" rad_comment_metadata "$PATCH_ID" --query unassign --last
check "$(lines_of "$OUT")" 1 "…but it is answered when it is asked for"
contains "$OUT" "value=ct_vibes" "with its own value"
run "$PROJECT" rad_comment_metadata "$KEYS_ID" --query label --last
check "$(lines_of "$OUT")" 1 "the newest label of the key fixture"
contains "$OUT" "value=after-empty" "which is the last block carrying that key"
run "$PROJECT" rad_comment_metadata "$KEYS_ID" --query label --query issue --last
check "$RC" 0 "two keys, one call"
check "$(lines_of "$OUT")" 2 "each key answers with its own newest block"
check "$(printf '%s\n' "$OUT" | grep -n "issue item=" | cut -d: -f1)" 1 "in chain order: the description's key first"
run "$PROJECT" rad_comment_metadata "$THIRD_ID" --query label --last
check "$(lines_of "$OUT")" 1 "the newest op of that item has no radicle identity"
contains "$OUT" "value=wip" "so the older trusted block still applies"
absent "$OUT" "value=done" "and the op nobody can be attributed to is never applied"
echo

echo "AC24 rad_set_label makes one label write, and says what it wrote"
: >"$WORK/rad.calls"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" improvement wip
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 1 "one line, the report"
contains "$OUT" "applied label item=issue:$ISSUE_ID add=improvement delete=wip" "which names the item, the label and the state it replaces"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 1 "exactly one 'rad' invocation"
check "$(cat "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --add=improvement --delete=wip" \
    "with the argv the applier promises"
run "$PROJECT" rad_set_label "patch:$PATCH_ID" "$ISSUE_ID"
check "$(tail -1 "$WORK/rad.calls")" "patch label $PATCH_ID --quiet --add=$ISSUE_ID" \
    "a patch label goes through 'rad patch label'"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" idea --repo "$RID"
check "$(tail -1 "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --add=idea -r $RID" \
    "a repository given as a RID travels as '-r'"
printf 'improvement' >"$WORK/refuse"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" improvement
check "$RC" 1 "a write rad refuses is the exit code"
err "$PROJECT" rad_set_label "issue:$ISSUE_ID" improvement
contains "$OUT" "failed" "and the reason comes from rad"
rm -f "$WORK/refuse"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" "" "pr:$PATCH"
check "$RC" 0 "an empty add is a write of its own: a removal alone"
contains "$OUT" "applied label item=issue:$ISSUE_ID delete=pr:$PATCH" "the report names the delete and no add"
check "$(lines_of "$OUT")" 1 "one line, as ever"
check "$(tail -1 "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --delete=pr:$PATCH" \
    "…and the write carries no '--add' at all"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" "" "pr:$PATCH" "pr:$OTHER"
check "$(tail -1 "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --delete=pr:$PATCH --delete=pr:$OTHER" \
    "every delete follows, in the order the caller gave them"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" ""
check "$RC" 2 "an empty add with nothing to delete is still a usage error"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID"
check "$RC" 2 "no label at all is a usage error"
run "$PROJECT" rad_set_label "issue:$ISSUE_ID" idea --nonsense
check "$RC" 2 "so is an argument it does not know"
echo

echo "AC25 rad_assign and rad_unassign resolve the identity before they write it"
: >"$WORK/rad.calls"
: >"$WORK/facts.calls"
run "$PROJECT" rad_assign "issue:$ISSUE_ID" cehteh
check "$RC" 0 "exit 0"
contains "$OUT" "applied assign item=issue:$ISSUE_ID add=did:key:$DELEGATE_NID" "the alias became the DID rad takes"
check "$(cat "$WORK/rad.calls")" "issue assign $ISSUE_ID --quiet --add=did:key:$DELEGATE_NID" \
    "…in one 'rad issue assign'"
contains "$(cat "$WORK/facts.calls")" "--author cehteh" "the resolution asked the facts command"
run "$PROJECT" rad_assign "issue:$ISSUE_ID" "did:key:$CONTRIBUTOR_NID"
check "$(tail -1 "$WORK/rad.calls")" "issue assign $ISSUE_ID --quiet --add=did:key:$CONTRIBUTOR_NID" \
    "a DID is written as it stands"
run "$PROJECT" rad_unassign "patch:$PATCH_ID" "$CONTRIBUTOR_NID"
contains "$OUT" "applied unassign item=patch:$PATCH_ID delete=did:key:$CONTRIBUTOR_NID" "an unassign reports its delete"
check "$(tail -1 "$WORK/rad.calls")" "patch assign $PATCH_ID --quiet --delete=did:key:$CONTRIBUTOR_NID" \
    "…and it is a 'rad patch assign --delete'"
run "$PROJECT" rad_assign "issue:$ISSUE_ID" nosuchalias
check "$RC" 1 "an alias nobody knows is refused"
err "$PROJECT" rad_assign "issue:$ISSUE_ID" nosuchalias
contains "$OUT" "cannot resolve 'nosuchalias'" "and the refusal names the value"
run "$PROJECT" rad_unassign
check "$RC" 2 "no item and no identity is a usage error"
echo

echo "AC26 rad_apply_from_comments applies the trusted proposals of one item"
printf 'idea' >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$ISSUE_ID"
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 3 "two labels and the assignment"
contains "$OUT" "applied label item=issue:$ISSUE_ID add=bug delete=idea" \
    "the new label carries the old chain state out with it"
contains "$OUT" "applied label item=issue:$ISSUE_ID add=wip" "the block's second label follows, without a delete"
contains "$OUT" "applied assign item=issue:$ISSUE_ID add=did:key:$DELEGATE_NID" "the assignment is applied too"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 3 "three writes, one per effect"
check "$(sed -n 1p "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --add=bug --delete=idea" "the first write is the one with the delete"
printf 'bug, wip' >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$ISSUE_ID" --query label
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 2 "both labels are already said"
contains "$OUT" "skip label item=issue:$ISSUE_ID add=bug (the item already says it)" "…and that is reported"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 0 "the stored state is read fresh, so nothing is written again"
printf 'idea' >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$ISSUE_ID" --dry-run
check "$RC" 0 "a dry run exits 0"
contains "$OUT" "would label item=issue:$ISSUE_ID add=bug delete=idea" "it names the write and what it would replace"
contains "$OUT" "would assign item=issue:$ISSUE_ID add=did:key:$DELEGATE_NID" "and the identity it resolved"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 0 "and it writes nothing"
run "$PROJECT" rad_apply_from_comments
check "$RC" 2 "no item is a usage error"
echo

echo "AC27 a key with no effect, and an author nobody trusts, are never applied"
rm -f "$WORK/labels.issue/$OWN_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$OWN_ID"
check "$RC" 0 "an item whose newest block nobody is trusted for exits 0"
check "$(lines_of "$OUT")" 1 "one entry -- the older trusted block, not the newer one nobody is trusted for"
contains "$OUT" "applied label item=issue:$OWN_ID add=carried" "which is the block the delegate wrote"
absent "$OUT" "outsider-wip" "the untrusted block never reaches an applier"
check "$(cat "$WORK/rad.calls")" "issue label $OWN_ID --quiet --add=carried" "and it is the only write"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$OWN_ID" --trust "did:$OUTSIDER_NID"
check "$RC" 0 "exit 0"
contains "$OUT" "applied label item=issue:$OWN_ID add=outsider-wip" \
    "with that identity named, the newer block is what applies"
check "$(cat "$WORK/rad.calls")" "issue label $OWN_ID --quiet --add=outsider-wip" "…and it replaces nothing, the item carries no label"
: >"$WORK/rad.calls"
run "$PROJECT" rad_apply_from_comments "$KEYS_ID"
check "$RC" 0 "exit 0"
contains "$OUT" "skip issue item=issue:$KEYS_ID value=5555555 (no effect is registered for that key)" \
    "a key with no registered effect is reported"
contains "$OUT" "skip Note item=issue:$KEYS_ID value=hello (no effect is registered for that key)" \
    "…like every other one"
contains "$OUT" "applied label item=issue:$KEYS_ID add=after-empty" "while the keys which have one are applied"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 1 "and that is the only write"
echo

echo "AC28 rad_reaction compares against our own reduced state, never the op stream"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID"
check "$RC" 1 "our newest marker is already there, so 'no live marker' is refused"
err "$PROJECT" rad_reaction "" 👀 "$REACT_ID"
contains "$OUT" "is '➖' where no marker was expected" "…and the refusal names the state it found"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 0 "a mismatch writes nothing"
run "$PROJECT" rad_reaction 🔧 ✅ "$REACT_ID"
check "$RC" 1 "a marker the op stream carries but its author took back is not live"
run "$PROJECT" rad_reaction ✅ ❓ "$REACT_ID"
check "$RC" 1 "the delegate's marker is not ours, so it is not the state either"
run "$PROJECT" rad_reaction ➖ ✅ "$REACT_ID"
check "$RC" 0 "the newest live marker is the state, and it is accepted"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.issue --object $REACT --message React" \
    "the issue itself is one write on the issue COB"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 1 "one invocation carries the whole transition"
check "$(sed -n 1p "$WORK/rad.actions")" \
    "{\"type\":\"comment.react\",\"id\":\"$REACT\",\"reaction\":\"✅\",\"active\":true}" \
    "and the action is the payload rad writes itself"
check "$(sed -n 2p "$WORK/rad.actions")" \
    "{\"type\":\"comment.react\",\"id\":\"$REACT\",\"reaction\":\"➖\",\"active\":false}" \
    "…which withdraws the marker it replaces, in the same op"
contains "$OUT" "level=root" "the report names the level"
contains "$OUT" "withdrawn=yes" "…and that the marker it supersedes was taken back"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID" "$REACT_COMMENT"
check "$RC" 0 "'no live marker' holds on a comment nobody of ours reacted to"
check "$(tail -1 "$WORK/rad.calls")" "cob update --type xyz.radicle.issue --object $REACT --message React" \
    "…and that comment is a write on the same item"
check "$(tail -1 "$WORK/rad.actions")" \
    "{\"type\":\"comment.react\",\"id\":\"$REACT_COMMENT\",\"reaction\":\"👀\",\"active\":true}" \
    "the action names the comment"
contains "$OUT" "level=comment" "reported as a comment of the item"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID" "${REACT_COMMENT:0:7}"
check "$RC" 0 "a comment named in shorthand is accepted"
check "$(tail -1 "$WORK/rad.actions")" \
    "{\"type\":\"comment.react\",\"id\":\"$REACT_COMMENT\",\"reaction\":\"👀\",\"active\":true}" \
    "…and the action carries the full op id the store insists on"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID" "$REACT_COMMENT" --repo "$RID"
check "$RC" 0 "a RID may name the repository"
check "$(tail -1 "$WORK/rad.calls")" \
    "cob update --type xyz.radicle.issue --object $REACT --message React -r $RID" \
    "…and it travels to 'rad' as '-r'"
echo

echo "AC29 a transition takes the marker it replaces back, at every level"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction ✅ 🔧 "$RATCH_ROOT"
check "$RC" 0 "the state the patch carries is accepted"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.patch --object $RATCH --message React" \
    "one write on the patch COB"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 1 "one invocation: the replace is not two calls"
check "$(sed -n 1p "$WORK/rad.actions")" \
    "{\"type\":\"revision.react\",\"revision\":\"$RATCH_ROOT\",\"reaction\":\"🔧\",\"active\":true}" \
    "the new marker goes first"
check "$(sed -n 2p "$WORK/rad.actions")" \
    "{\"type\":\"revision.react\",\"revision\":\"$RATCH_ROOT\",\"reaction\":\"✅\",\"active\":false}" \
    "…and the one it replaces is withdrawn in the same op"
contains "$OUT" "withdrawn=yes" "the report says what happened"
contains "$OUT" "level=revision" "at the revision level"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction 👀 🔧 "$RATCH_ROOT"
check "$RC" 1 "a marker which is not the state is refused"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 0 "…and nothing at all is written"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction ✅ "" "$RATCH_ROOT"
check "$RC" 0 "an empty reaction takes the marker back"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.patch --object $RATCH --message React" \
    "with the one call that does it"
check "$(cat "$WORK/rad.actions")" \
    "{\"type\":\"revision.react\",\"revision\":\"$RATCH_ROOT\",\"reaction\":\"✅\",\"active\":false}" \
    "…as the withdrawal alone, and it sets nothing"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction ➖ "" "$REACT_ID"
check "$RC" 0 "the issue level takes a marker back the same way"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.issue --object $REACT --message React" \
    "…through the same one call"
check "$(cat "$WORK/rad.actions")" \
    "{\"type\":\"comment.react\",\"id\":\"$REACT\",\"reaction\":\"➖\",\"active\":false}" \
    "…which is the write 'rad issue react' cannot make"
echo

echo "AC30 a revision id names the patch COB that holds it"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 🔧 "$RATCH_REVISION"
check "$RC" 0 "exit 0"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.patch --object $RATCH --message React" \
    "the revision is written against the COB that holds it"
check "$(cat "$WORK/rad.actions")" \
    "{\"type\":\"revision.react\",\"revision\":\"$RATCH_REVISION\",\"reaction\":\"🔧\",\"active\":true}" \
    "and the action names that revision, in full"
contains "$OUT" "level=revision" "and it is a revision of the patch"
contains "$OUT" "item=patch:$RATCH_ID" "which the read found through the chain"
: >"$WORK/rad.calls"
: >"$WORK/rad.actions"
run "$PROJECT" rad_reaction "" 👀 "$RATCH_ID" "$RATCH_COMMENT"
check "$RC" 0 "exit 0"
check "$(cat "$WORK/rad.calls")" "cob update --type xyz.radicle.patch --object $RATCH --message React" \
    "a comment of a patch is a write on the patch COB"
check "$(cat "$WORK/rad.actions")" \
    "{\"type\":\"revision.comment.react\",\"revision\":\"$RATCH_ROOT\",\"comment\":\"$RATCH_COMMENT\",\"reaction\":\"👀\",\"active\":true}" \
    "…naming the comment and the revision the comment was made on"
contains "$OUT" "level=comment" "reported as a comment of the revision"
echo

echo "AC31 rad_reaction refuses what the store would refuse"
run "$PROJECT" rad_reaction "" "$(printf '\u2764\ufe0f')" "$REACT_ID"
check "$RC" 2 "an emoji with a variation selector is refused before any call"
run "$PROJECT" rad_reaction "" "ab" "$REACT_ID"
check "$RC" 2 "so is a word"
run "$PROJECT" rad_reaction "" "" "$REACT_ID"
check "$RC" 2 "an empty reaction needs the marker it takes back"
run "$PROJECT" rad_reaction "" 👀
check "$RC" 2 "no target at all is a usage error"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID" one two
check "$RC" 2 "more than two target words are too"
run "$PROJECT" rad_reaction 👀 👀 "$REACT_ID"
check "$RC" 2 "a transition to itself is not a transition"
run "$PROJECT" rad_reaction "" "➖" "zzzzzzz"
check "$RC" 3 "an id nobody holds is no data"
run "$PROJECT" rad_reaction "" 👀 "$REACT_ID" --nonsense
check "$RC" 2 "an unknown argument"
echo

echo "AC32 rad_rm_label removes the stored labels a glob matches, in one write"
printf 'idea, pr:%s, pr:%s, xpr:%s' "$PATCH" "$OTHER" "$PATCH" >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_rm_label "issue:$ISSUE_ID" 'pr:*'
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 1 "one line, the report"
contains "$OUT" "removed label item=issue:$ISSUE_ID delete=pr:$PATCH pr:$OTHER" \
    "every label the glob matched is named, and no other"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 1 "exactly one 'rad' invocation"
check "$(cat "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --delete=pr:$PATCH --delete=pr:$OTHER" \
    "with one delete per removed label, and nothing else"
printf 'xpr:%s' "$PATCH" >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_rm_label "issue:$ISSUE_ID" 'pr:*'
check "$RC" 0 "a glob which matches nothing is an answer, not a failure"
check "$(lines_of "$(cat "$WORK/rad.calls")")" 0 "nothing is written"
contains "$OUT" "no label item=issue:$ISSUE_ID" "and the empty answer says so"
contains "$OUT" "pr:*" "naming the glob it looked for"
absent "$OUT" "xpr:$PATCH" "the glob is anchored at both ends: 'pr:*' never takes 'xpr:…'"
printf 'idea, pr:%s' "$PATCH" >"$WORK/labels.patch/$PATCH_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_rm_label "patch:$PATCH_ID" '*'
check "$RC" 0 "'*' is a glob like any other"
contains "$OUT" "removed label item=patch:$PATCH_ID delete=idea pr:$PATCH" \
    "the chain slot goes out with the rest -- an explicit act"
check "$(cat "$WORK/rad.calls")" "patch label $PATCH_ID --quiet --delete=idea --delete=pr:$PATCH" \
    "…through 'rad patch label', in the one write"
printf 'idea' >"$WORK/labels.issue/$ISSUE_ID"
: >"$WORK/rad.calls"
run "$PROJECT" rad_rm_label "$ISSUE_ID" 'idea' --repo "$RID"
check "$RC" 0 "a bare id is an issue and a RID may name the repository"
check "$(tail -1 "$WORK/rad.calls")" "issue label $ISSUE_ID --quiet --delete=idea -r $RID" \
    "…which travels as '-r'"
run "$PROJECT" rad_rm_label "issue:$ISSUE_ID"
check "$RC" 2 "a glob is required"
run "$PROJECT" rad_rm_label
check "$RC" 2 "so is an item"
run "$PROJECT" rad_rm_label "issue:$ISSUE_ID" 'pr:*' --nonsense
check "$RC" 2 "an unknown argument is a usage error"
run "$PROJECT" rad_rm_label -h
check "$RC" 0 "'-h' is the usage on stdout"
contains "$OUT" "usage: rad_rm_label" "…which says how to call it"
run "$PROJECT" helpers
contains "$OUT" "rad_rm_label" "the repertoire lists the removal half"
run "$PROJECT" helpers --check
check "$RC" 0 "and the registration guard passes with it"
echo

echo
if (( failures )); then
    echo "=== $failures check(s) failed ==="
    exit 1
fi
echo "=== all checks passed ==="
