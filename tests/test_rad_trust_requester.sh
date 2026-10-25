#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'rad_trust --second-party --requester' (Bar.d/rad).
#
# The second party a consent needs is somebody *other* than the identity which asked for the
# decision.  '--requester' names that identity, as a unique id and nothing else; without it the
# requester is the actor itself, so no item is consulted for an opener.  The node is a fake ('rad
# path' and a storage built by hand), the fact tool a stub which resolves an alias to the identity it
# names.
#
#   AC1  the item's opener, asked about by somebody else, is a second party -- and the item is read
#   AC2  the same actor named as the requester is not
#   AC3  the comparison needs no item, and no item is read
#   AC4  without a requester the requester is the actor, so the answer is 'false' -- for the opener and
#        for an assignee alike; a plain '--dump' still carries no 'second_party'
#   AC5  an alias is refused as a requester, and so is a DID which is not a 'did:key:' NID
#   AC6  '--requester' without '--second-party', and an empty one, are exit 2
#   AC7  the shape callers are written against: one object per line, 'bar_rad', a boolean, the usage
#
# usage: tests/test_rad_trust_requester.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the helper under test
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git git_lib json_lib agent_rules helpers_rules radicle_lib rad usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

echo "=== Testing 'rad_trust --second-party --requester' (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -------------------------------------------------------------------------------------------------
# fixtures
# -------------------------------------------------------------------------------------------------

# <dir> - a project directory with the modules and no repository of its own
mkproject() { # <dir>
    local dir="$1" module
    mkdir -p "$dir/Bar.d"
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done
    cat >"$dir/Barf" <<'BARF'
rule MAIN: -- true
BARF
}

OUT=""
ERR=""
RC=0
run_bar_env() { # <dir> <VAR=value>.. -- <args..> - stdout and rc with environment assignments
    local dir="$1"
    shift
    local -a envs=()
    while [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && env "${envs[@]}" "$BAR" "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}
run_bar() { # <dir> <args..> - stdout and rc
    local dir="$1"
    shift
    run_bar_env "$dir" -- "$@"
}

PROJ="$WORK/proj"
mkproject "$PROJ"

# a fake node: 'rad path' is the only thing the helper asks it
mkfakerad() { # <file> <radicle-home>
    cat >"$1" <<FAKE
#!/bin/sh
case "\${1:-}" in
path) printf '%s\n' "$2" ;;
*) printf 'unexpected rad invocation: %s\n' "\$*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$1"
}

# the fact tool: '--author <alias>' is resolved through STUB_MAP ('<alias> <did>' lines), a DID or
# NID is taken as it stands, and an author nobody names answers the tool's own error object
mkfacts() { # <file>
    cat >"$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_ARGS:-/dev/null}"
author=""
prev=""
for a in "$@"; do
    if [ "$prev" = "--author" ]; then author="$a"; fi
    prev="$a"
done
did=""
case "$author" in
    did:*) did="$author" ;;
    z6M*) did="did:key:$author" ;;
    *)
        if [ -n "${STUB_MAP:-}" ] && [ -f "$STUB_MAP" ]; then
            did="$(awk -v a="$author" '$1 == a { print $2; exit }' "$STUB_MAP")"
        fi
        ;;
esac
rid="${STUB_RID:-rad:zFAKE}"
if [ -z "$did" ]; then
    printf '{"rid":"%s","author":null,"contributor":null,"reason":"","error":"cannot resolve author %s"}' "$rid" "$author"
    exit 2
fi
nid="${did#did:key:}"
nid="${nid#did:}"
printf '{"rid":"%s","threshold":10,"delegates":[],"author":{"alias":"%s","nid":"%s","did":"%s","is_delegate":false,"total_authored":1},"contributor":null,"reason":"stub"}' \
    "$rid" "$author" "$nid" "$did"
exit 0
STUB
    chmod +x "$1"
}

# <store> <nid> <subject> <payload-json|-> [<parent>..] - one COB op in the node's storage
mkop() {
    local store="$1" nid="$2" subject="$3" payload="$4"
    shift 4
    local tree="" blob="" manifest=""
    if [[ "$payload" == "-" ]]; then
        tree="$(printf '' | git --git-dir="$store" mktree)"
    else
        blob="$(printf '%s' "$payload" | git --git-dir="$store" hash-object -w --stdin)"
        manifest="$(printf '{"typeName":"xyz.radicle.issue","version":1}' |
            git --git-dir="$store" hash-object -w --stdin)"
        tree="$(printf '100644 blob %s\t0\n100644 blob %s\tmanifest\n' "$blob" "$manifest" |
            git --git-dir="$store" mktree)"
    fi
    GIT_AUTHOR_NAME="$nid" GIT_AUTHOR_EMAIL="$nid@$nid" \
    GIT_AUTHOR_DATE="2026-10-15T12:00:00+02:00" \
    GIT_COMMITTER_NAME="$nid" GIT_COMMITTER_EMAIL="$nid@$nid" \
    GIT_COMMITTER_DATE="2026-10-15T12:00:00+02:00" \
    git --git-dir="$store" commit-tree "$tree" "$@" -m "$subject"
}

RID="rad:zFAKE"
OPENER="z6Mkopener"
ASSIGNEE="z6Mkassignee"
OWNER="z6Mkowner"
ITERATOR="z6Mkiterator"     # a second party to the opener's item, in every sense
REQUESTER="z6Mkrequester"   # the identity which asks for the decision
ITEM="d89673599766b6b4f472e267b6e2ebaba7b1c543"

HOME1="$WORK/home"
FAKERAD="$WORK/fake-rad"
mkfakerad "$FAKERAD" "$HOME1"
FACTS="$WORK/facts"
mkfacts "$FACTS"

# the alias map the fact tool resolves through: one alias per identity, plus one nobody knows
STUB_MAP="$WORK/aliases"
cat >"$STUB_MAP" <<MAP
opener did:key:$OPENER
iterator did:key:$ITERATOR
requester did:key:$REQUESTER
MAP

# <home> - a node storage: an identity document, and one issue the opener created and assigned
mkstore() { # <home>
    local home="$1"
    local store="$home/storage/${RID#rad:}"
    mkdir -p "$store"
    git init -q --bare "$store"
    local first second create assign
    first="$(mkop "$store" "$OWNER" "Initialize identity" -)"
    second="$(mkop "$store" "$OWNER" "Initialize identity" - -p "$first")"
    create="$(mkop "$store" "$OPENER" "Create issue" '{"type":"comment","body":"the item"}' -p "$second")"
    assign="$(mkop "$store" "$OPENER" "Assign" \
        "{\"type\":\"assign\",\"assignees\":[\"did:key:$ASSIGNEE\"],\"message\":\"\"}" -p "$create")"
    git --git-dir="$store" update-ref refs/rad/id "$second"
    git --git-dir="$store" update-ref "refs/namespaces/$OWNER/refs/cobs/xyz.radicle.issue/$ITEM" "$assign"
}
mkstore "$HOME1"

# <author-json-did> - the answer the fact tool gives for one actor, with the fixture's rid
trust() { # <dir> <actor> <args..>
    local dir="$1" actor="$2"
    shift 2
    run_bar_env "$dir" "RAD_TRIAGE_FACTS=$FACTS" "RAD_BIN=$FAKERAD" "STUB_ARGS=/dev/null" \
        "STUB_MAP=$STUB_MAP" "STUB_RID=$RID" -- rad_trust --repo "$RID" "$@" --author "$actor"
}

# -------------------------------------------------------------------------------------------------
# AC1 - the opener is a second party to somebody else's question
# -------------------------------------------------------------------------------------------------

echo "--- AC1 the item's opener, asked about by somebody else, is a second party ---"
trust "$PROJ" "$OPENER" --second-party --requester "$REQUESTER" --issue "$ITEM"
check "$RC" "0" "a verdict is an answer, exit 0"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "true" \
    "the opener is a second party to another identity's question"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "true" \
    "the item was read, and the ground it carries is there"
check "$(printf '%s' "$OUT" | jq -r '.verdict // "none"')" "none" "the dump decides nothing"

echo "--- AC1b a third identity is a second party to the opener's question too ---"
trust "$PROJ" "$ITERATOR" --second-party --requester "$OPENER" --issue "$ITEM"
check "$RC" "0" "exit 0"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "true" "somebody who opened nothing is a second party"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "false" "and carries no 'opened' ground"

# -------------------------------------------------------------------------------------------------
# AC2 - the actor named as the requester is nobody's second party
# -------------------------------------------------------------------------------------------------

echo "--- AC2 the actor named as the requester is not a second party ---"
trust "$PROJ" "$OPENER" --second-party --requester "$OPENER" --issue "$ITEM"
check "$RC" "0" "exit 0: the answer is a fact, not a refusal"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" \
    "the identity which asked is not a second party to its own question"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "true" "whatever the grounds say"

echo "--- AC2b the DID and the bare NID name the same requester ---"
trust "$PROJ" "$OPENER" --second-party --requester "did:key:$OPENER" --issue "$ITEM"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" "a 'did:key:' requester is the same identity"

# -------------------------------------------------------------------------------------------------
# AC3 - with a requester the flag needs no item
# -------------------------------------------------------------------------------------------------

echo "--- AC3 the comparison needs no item ---"
trust "$PROJ" "$OPENER" --second-party --requester "$REQUESTER"
check "$RC" "0" "'--second-party --requester' answers without '--issue'/'--patch'"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "true" "and the comparison is the requester's"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "false" "no item was named, so no opener was read"
trust "$PROJ" "$REQUESTER" --second-party --requester "$REQUESTER"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" "the requester itself, still not a second party"

# -------------------------------------------------------------------------------------------------
# AC4 - without a requester: the requester is the actor itself
# -------------------------------------------------------------------------------------------------

echo "--- AC4 without a requester nobody is a second party, and no opener is consulted ---"
trust "$PROJ" "$OPENER" --second-party --issue "$ITEM"
check "$RC" "0" "exit 0"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" "the actor asked its own question"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "true" "the named item is still read as a ground"
trust "$PROJ" "$ASSIGNEE" --second-party --issue "$ITEM"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" \
    "an assignee is no second party either -- the item's opener is not the fallback"
trust "$PROJ" "$OPENER" --second-party --grounds delegate --issue "$ITEM"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" "an explicit '--grounds' answers the same"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened // "absent"')" "absent" \
    "and no ground is computed for the comparison"
trust "$PROJ" "$ASSIGNEE" --dump --issue "$ITEM"
check "$(printf '%s' "$OUT" | jq -r '.second_party // "absent"')" "absent" \
    "a plain '--dump' is unchanged: no 'second_party' field"

echo "--- AC4b without a requester the flag needs no item at all ---"
trust "$PROJ" "$OPENER" --second-party
check "$RC" "0" "no item and no requester is an answer, not a refusal"
check "$(printf '%s' "$OUT" | jq -r '.second_party')" "false" "and the answer is the same"
check "$(printf '%s' "$OUT" | jq -r '.grounds.opened')" "false" "with no item named, nothing was read"

# -------------------------------------------------------------------------------------------------
# AC5 - a requester is a unique identity, never an alias
# -------------------------------------------------------------------------------------------------

echo "--- AC5 an alias is refused as a requester ---"
trust "$PROJ" "$OPENER" --second-party --requester opener --issue "$ITEM"
check "$RC" "2" "an alias can name two identities, so it is a usage error"
check "$OUT" "" "and nothing is printed on stdout"
contains "$ERR" "never an alias" "the refusal says what a requester may be"
trust "$PROJ" "$OPENER" --second-party --requester "did:web:example.com" --issue "$ITEM"
check "$RC" "2" "a DID which is not a 'did:key:' NID is refused too"
check "$OUT" "" "and prints nothing on stdout"

# -------------------------------------------------------------------------------------------------
# AC6 - '--requester' on its own, and an empty one
# -------------------------------------------------------------------------------------------------

echo "--- AC6 '--requester' without '--second-party', and an empty requester ---"
trust "$PROJ" "$OPENER" --requester "$REQUESTER" --issue "$ITEM"
check "$RC" "2" "'--requester' without '--second-party' decides nothing"
check "$OUT" "" "and prints nothing on stdout"
contains "$ERR" "needs '--second-party'" "the refusal says what it belongs to"
trust "$PROJ" "$OPENER" --second-party --requester ""
check "$RC" "2" "an empty requester is a usage error"

# -------------------------------------------------------------------------------------------------
# AC7 - the shape callers are written against
# -------------------------------------------------------------------------------------------------

echo "--- AC7 the output shape and the usage ---"
trust "$PROJ" "$OPENER" --second-party --requester "$REQUESTER" --issue "$ITEM"
check "$(printf '%s' "$OUT" | wc -l)" "0" "one object, no trailing blank"
check "$(printf '%s' "$OUT" | jq -r '.bar_rad')" "1" "'bar_rad: 1' is in every object"
check "$(printf '%s' "$OUT" | jq -r '.grounds | type')" "object" "the dump is there beside the verdict"
check "$(printf '%s' "$OUT" | jq -r '.second_party | type')" "boolean" "'second_party' is a boolean"
check "$(printf '%s' "$OUT" | jq -r '.rid')" "$RID" "the repository travels with it"
run_bar "$PROJ" rad_trust --help
check "$RC" "0" "'--help' answers"
contains "$OUT" "--requester <did|nid>" "the usage names '--requester' and the ids it takes"
contains "$OUT" "--second-party" "and the flag it belongs to"
absent "$OUT" "fallback" "no opener fallback is left"
contains "$OUT" "against itself" "and it says the requester is the actor without one"

# -------------------------------------------------------------------------------------------------

if (( failures > 0 )); then
    echo
    echo "FAIL: $failures assertion(s) failed"
    exit 1
fi
echo
echo "OK: all assertions passed"
