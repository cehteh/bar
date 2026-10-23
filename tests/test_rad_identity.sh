#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the identity helper (Bar.d/rad).
#
# Everything runs against a throw-away project and a real git storage built here commit by commit --
# no radicle installation, no node and no network are needed.  Covered:
#
#   AC1  every delegate of the accepted identity document is answered: nid, DID, delegate, threshold,
#        the revision op it was read from and the COB that op belongs to
#   AC2  the alias and the git authors come from the ops the store carries ('<alias>@<nid>'), the
#        identity COB is read before a comment, and a delegate which authored no op has none
#   AC3  '--did' takes a DID, a bare NID and an alias, and an identity this repository does not know
#        exits 3
#   AC4  an op is verified as its author ('how=identity', naming the COB), and an op of an identity the
#        repository does not delegate to is verified too -- authorship is not delegation
#   AC5  a commit published in an identity's namespace is verified ('how=namespace'), and the patch COB
#        which is chained onto such a commit does not turn that commit into an op
#   AC6  a canonical branch authenticates no author and a commit the store does not hold is not
#        verified -- the reason names the author line as what it is (exit 1)
#   AC7  '--json' is one object per line, valid JSON and nothing else on stdout
#   AC8  usage errors exit 2; a repository the node does not hold, one without an identity document
#        and an unknown identity exit 3
#   AC9  the helper is registered ('bar helpers --check')

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

echo "=== Testing the identity helper (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
if [[ -n "${RAD_IDENTITY_TEST_KEEP:-}" ]]; then
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

# ------------------------------------------------------------------------------------------------
# fixtures
# ------------------------------------------------------------------------------------------------

RID="rad:zIdentityTestRepository000000000000"
EMPTY_RID="rad:zIdentityTestNoDocument000000000000"
ALICE_NID="z6MkIdentityTestAlice000000000000000000"
BOB_NID="z6MkIdentityTestBob00000000000000000000"
CAROL_NID="z6MkIdentityTestCarol00000000000000000"
OUTSIDER_NID="z6MkIdentityTestOutsider00000000000000"
OUTSIDER2_NID="z6MkIdentityTestOutsiderTwo000000000000"
ID_COB="1111111111111111111111111111111111111111"
ISSUE_COB="2222222222222222222222222222222222222222"
PATCH_COB="3333333333333333333333333333333333333333"

PROJECT="$WORK/project"
RADHOME="$WORK/radhome"
STORAGE="$RADHOME/storage/${RID#rad:}"
FAKERAD="$WORK/bin/rad"

mkdir -p "$PROJECT" "$RADHOME/storage/${EMPTY_RID#rad:}" "$WORK/bin"
mkproject "$PROJECT"
git init -q "$PROJECT"
git -C "$PROJECT" commit -q --allow-empty -m "fixture"
git init -q --bare "$STORAGE"

# the fake 'rad': the node path of this fixture and the RID of the checkout
cat >"$FAKERAD" <<EOF
#!/bin/sh
case "\$1" in
path) printf '%s\n' "$RADHOME" ;;
inspect) printf '%s\n' "$RID" ;;
esac
exit 0
EOF
chmod +x "$FAKERAD"

# <json> - the sha of that blob in the storage
blob() { printf '%s' "$1" | git --git-dir="$STORAGE" hash-object -w --stdin; }

# <ns> <type> <cob> <subject> <payload> [parent] [name] [nid] [date] - one COB op, prints its sha
op() {
    local ns="$1" type="$2" cob="$3" subject="$4" payload="$5" parent="${6:-}"
    local name="${7:-alice}" nid="${8:-$ALICE_NID}" date="${9:-2026-10-23T10:00:00+02:00}"
    local pblob mblob tree sha
    local -a args=()
    pblob="$(blob "$payload")"
    mblob="$(blob "{\"typeName\":\"xyz.radicle.$type\",\"version\":1}")"
    tree="$(printf '100644 blob %s\t0\n100644 blob %s\tmanifest\n' "$pblob" "$mblob" |
        git --git-dir="$STORAGE" mktree)"
    [[ -n "$parent" ]] && args+=(-p "$parent")
    sha="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$name@$nid" GIT_AUTHOR_DATE="$date" \
           GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$name@$nid" GIT_COMMITTER_DATE="$date" \
           git --git-dir="$STORAGE" commit-tree "$tree" ${args[@]+"${args[@]}"} -m "$subject")"
    git --git-dir="$STORAGE" update-ref "refs/namespaces/$ns/refs/cobs/xyz.radicle.$type/$cob" "$sha"
    printf '%s' "$sha"
}

# <ns> <branch> [message] - a branch commit published in that identity's namespace, prints its sha
pushed() {
    local ns="$1" branch="$2" message="${3:-a pushed commit}" tree sha
    tree="$(git --git-dir="$STORAGE" mktree </dev/null)"
    sha="$(GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL="alice@$ALICE_NID" \
        GIT_COMMITTER_NAME=alice GIT_COMMITTER_EMAIL="alice@$ALICE_NID" \
        git --git-dir="$STORAGE" commit-tree "$tree" -m "$message")"
    git --git-dir="$STORAGE" update-ref "refs/namespaces/$ns/refs/heads/$branch" "$sha"
    printf '%s' "$sha"
}

# -- the identity document: alice, bob and carol delegate, threshold 1 ---------------------------------
DOC_BLOB="$(blob "{\"delegates\":[\"did:key:$ALICE_NID\",\"did:key:$BOB_NID\",\"did:key:$CAROL_NID\"],\"payload\":{},\"threshold\":1}")"
ID_OP="$(op "$ALICE_NID" id "$ID_COB" "Initial revision" \
    "{\"blob\":\"$DOC_BLOB\",\"parent\":null,\"signature\":\"sig\",\"title\":\"Initial revision\",\"type\":\"revision\"}" \
    "" alice "$ALICE_NID" "2026-10-23T09:00:00+02:00")"
# the accepted revision, and the copy the other namespace carries
git --git-dir="$STORAGE" update-ref refs/rad/id "$ID_OP"
git --git-dir="$STORAGE" update-ref "refs/namespaces/$BOB_NID/refs/cobs/xyz.radicle.id/$ID_COB" "$ID_OP"

# -- bob authored an issue, and an outsider commented on it -------------------------------------------
ISSUE_TIP="$(op "$BOB_NID" issue "$ISSUE_COB" "Create issue" \
    '{"body":"the map this asks for","type":"issue","title":"identity"}' \
    "" bob "$BOB_NID" "2026-10-23T09:10:00+02:00")"
OUTSIDER_OP="$(op "$BOB_NID" issue "$ISSUE_COB" "Comment" \
    '{"body":"a comment","type":"comment"}' \
    "$ISSUE_TIP" outsider "$OUTSIDER_NID" "2026-10-23T09:20:00+02:00")"

# -- a branch commit alice published, and a patch COB chained onto it ---------------------------------
# radicle chains a patch COB onto the commits the patch was cut from, so this commit is reachable from a
# COB ref while being an ordinary commit -- the shape, not the reachability, decides what an op is
PUSHED="$(pushed "$ALICE_NID" topic)"
patch_op="$(op "$ALICE_NID" patch "$PATCH_COB" "Create patch" \
    '{"type":"patch","title":"a patch"}' "$PUSHED" alice "$ALICE_NID" "2026-10-23T09:30:00+02:00")"
# a second identity which uses the same display name: an alias is not an identifier
op "$ALICE_NID" patch "$PATCH_COB" "Comment" '{"type":"comment"}' "$patch_op" outsider "$OUTSIDER2_NID" \
    "2026-10-23T09:40:00+02:00" >/dev/null

# -- a commit only the canonical branch carries ----------------------------------------------
CANONICAL="$(GIT_AUTHOR_NAME=bob GIT_AUTHOR_EMAIL="bob@$BOB_NID" \
    GIT_COMMITTER_NAME=delegate GIT_COMMITTER_EMAIL="delegate@$ALICE_NID" \
    git --git-dir="$STORAGE" commit-tree "$(git --git-dir="$STORAGE" mktree </dev/null)" -m "merged")"
git --git-dir="$STORAGE" update-ref refs/heads/main "$CANONICAL"

# -- the forgery: an unsigned local commit whose author line claims alice's identity -------------------
FORGED="$(GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL="alice@$ALICE_NID" \
    GIT_COMMITTER_NAME=somebody GIT_COMMITTER_EMAIL="somebody@example.invalid" \
    git -C "$PROJECT" commit-tree "$(git -C "$PROJECT" rev-parse 'HEAD^{tree}')" -m "forged")"

# ------------------------------------------------------------------------------------------------
# running the helper
# ------------------------------------------------------------------------------------------------

RC=0
OUT=""
run() { # <dir> <args>.. - stdout, exit code in RC
    OUT=""
    RC=0
    OUT="$(cd "$1" && RAD_BIN="$FAKERAD" "$BAR" "${@:2}" 2>/dev/null)" || RC=$?
}
err() { # <dir> <args>.. - stderr only
    OUT=""
    RC=0
    OUT="$(cd "$1" && RAD_BIN="$FAKERAD" "$BAR" "${@:2}" 2>&1 >/dev/null)" || RC=$?
}

# ------------------------------------------------------------------------------------------------

echo "AC1 every delegate of the identity document is answered"
run "$PROJECT" rad_identity --repo "$RID"
check "$RC" 0 "exit 0"
check "$(lines_of "$OUT")" 3 "one line per delegate"
contains "$OUT" "nid=$ALICE_NID did=did:key:$ALICE_NID alias=alice delegate=yes threshold=1" "alice, with her DID, alias, delegation and the threshold"
contains "$OUT" "identity_cob=$ID_OP" "the revision op the document was read from"
run "$PROJECT" rad_identity --repo "$RID" --json
check "$RC" 0 "the JSON form answers too"
contains "$OUT" "\"identity_object\":\"$ID_COB\"" "…and names the COB the revision belongs to"
contains "$OUT" "\"delegate\":true,\"threshold\":1" "delegation and threshold as JSON values"
echo

echo "AC2 the alias and the git authors are read from the ops the store carries"
run "$PROJECT" rad_identity --repo "$RID" --json
contains "$OUT" "\"alias\":\"alice\",\"alias_source\":\"$ID_OP\"" "alice's alias comes from the identity COB itself"
contains "$OUT" "\"alias\":\"bob\",\"alias_source\":\"$ISSUE_TIP\"" "bob's from the op that carried it"
contains "$OUT" "\"git_authors\":[{\"name\":\"bob\",\"email\":\"bob@$BOB_NID\"}]" "…and the author line it uses"
contains "$OUT" "\"alias\":null" "a delegate which authored no op has no alias to read"
contains "$OUT" "\"nid\":\"$CAROL_NID\"" "…while still being answered"
echo

echo "AC3 '--did' takes a DID, a NID and an alias"
for who in "did:key:$BOB_NID" "$BOB_NID" bob; do
    run "$PROJECT" rad_identity --repo "$RID" --did "$who"
    check "$RC" 0 "'$who' resolves"
    check "$(lines_of "$OUT")" 1 "…to one identity"
    contains "$OUT" "nid=$BOB_NID" "…which is bob"
done
run "$PROJECT" rad_identity --repo "$RID" --did nobody
check "$RC" 3 "an identity this repository does not know exits 3"
err "$PROJECT" rad_identity --repo "$RID" --did nobody
contains "$OUT" "names no identity of" "…and says so"
run "$PROJECT" rad_identity --repo "$RID" --did outsider
check "$RC" 2 "an alias two identities answer to is a usage error"
err "$PROJECT" rad_identity --repo "$RID" --did outsider
contains "$OUT" "more than one identity" "…and says how to ask instead"
echo

echo "AC4 an op is verified as its author, and authorship is not delegation"
run "$PROJECT" rad_identity --repo "$RID" --commit "$OUTSIDER_OP" --json
check "$RC" 0 "an op of a non-delegate is verified"
contains "$OUT" "\"nid\":\"$OUTSIDER_NID\"" "…as the identity which signed it"
contains "$OUT" "\"how\":\"identity\"" "'how=identity'"
contains "$OUT" "\"cob\":\"$ISSUE_COB\"" "…naming the COB it is an op of"
run "$PROJECT" rad_identity --repo "$RID" --did "$OUTSIDER_NID"
check "$RC" 0 "that identity resolves too"
contains "$OUT" "delegate=no" "…and is not a delegate"
echo

echo "AC5 a published commit is tied to the namespace which published it"
run "$PROJECT" rad_identity --repo "$RID" --commit "$PUSHED"
check "$RC" 0 "exit 0"
contains "$OUT" "nid=$ALICE_NID verified=yes how=namespace" "verified as a namespace publication"
run "$PROJECT" rad_identity --repo "$RID" --commit "$PUSHED" --json
contains "$OUT" "\"cob\":null" "a namespace answer names no COB"
contains "$OUT" "\"author\":{\"name\":\"alice\",\"email\":\"alice@$ALICE_NID\"}" "…and reports the git author beside it"
echo

echo "AC6 a name is not an authentication"
run "$PROJECT" rad_identity --repo "$RID" --commit "$CANONICAL"
check "$RC" 1 "a commit only a canonical branch carries is not verified"
contains "$OUT" "verified=no" "…verified=no"
contains "$OUT" "canonical branch is the repository's" "…for the reason that a canonical ref is not an identity's"
run "$PROJECT" rad_identity --repo "$RID" --commit "$FORGED" --json
check "$RC" 1 "the forgery is not verified"
contains "$OUT" "\"verified\":false" "…verified=false"
contains "$OUT" "the author line names alice <alice@$ALICE_NID>, but the commit is neither stored nor published" "…and the reason names the author line as the claim it is"
contains "$OUT" "\"author\":{\"name\":\"alice\",\"email\":\"alice@$ALICE_NID\"}" "…which is reported as the author line it read"
echo

echo "AC7 '--json' is one object per line and nothing else"
run "$PROJECT" rad_identity --repo "$RID" --json
check "$RC" 0 "exit 0"
if printf '%s\n' "$OUT" | jq -e . >/dev/null 2>&1; then pass "every line is JSON"; else fail "every line is JSON"; fi
check "$(lines_of "$OUT")" "$(printf '%s\n' "$OUT" | jq -c . | wc -l | tr -d ' ')" "no line is anything but one object"
run "$PROJECT" rad_identity --repo "$RID"
absent "$OUT" "{" "the text form carries no JSON"
echo

echo "AC8 usage and the repository it cannot answer for"
run "$PROJECT" rad_identity --repo "$RID" --did bob --commit "$ID_OP"
check "$RC" 2 "'--did' and '--commit' together are a usage error"
run "$PROJECT" rad_identity --repo "$RID" --nonsense
check "$RC" 2 "an unknown option is a usage error"
err "$PROJECT" rad_identity --repo "$RID"
absent "$OUT" "usage:" "a working call says nothing on stderr"
run "$PROJECT" rad_identity --repo "rad:zIdentityTestUnheld00000000000000"
check "$RC" 3 "a repository the node does not hold exits 3"
run "$PROJECT" rad_identity --repo "$EMPTY_RID"
check "$RC" 3 "a storage without an identity document exits 3"
run "$PROJECT" rad_identity --repo "$RID" --help
check "$RC" 0 "'--help' answers with the usage"
contains "$OUT" "usage: rad_identity" "…on stdout"
echo

echo "AC9 the helper is registered"
OUT=""
RC=0
OUT="$(RAD_BIN="$FAKERAD" "$BAR" helpers --check 2>&1)" || RC=$?
check "$RC" 0 "'bar helpers --check' passes"
contains "$OUT" "OK" "and reports OK"
echo

if (( failures )); then
    echo "=== $failures check(s) failed ==="
    exit 1
fi
echo "=== all checks passed ==="
