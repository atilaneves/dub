#!/usr/bin/env bash

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$test_dir/common.sh"

[[ $(uname -s) == Linux ]] || exit 0
"$DC" --version | grep -q '^DMD' || exit 0

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export DUB_HOME="$fixture/dub-home"
unset DUB_NO_DESCRIBE_CACHE LD_LIBRARY_PATH
mkdir -p "$fixture/project/source"
cd "$fixture/project"
printf 'module original;\n' > source/original.d
printf '{"name":"git-env-check","targetType":"library"}\n' > dub.json
git init -q
cache=.dub/describe-cache-v1.bin

check_allowed() {
    local name=$1 value=$2
    rm -f "$cache"
    env "$name=$value" "$DUB" describe > "$fixture/$name-1.json"
    sleep 2
    env "$name=$value" "$DUB" describe > "$fixture/$name-2.json"
    [[ -f "$cache" ]] || die $LINENO "Allowed $name disabled cache"
    local inode=$(stat -c %i "$cache")
    env "$name=$value" "$DUB" describe > "$fixture/$name-3.json"
    [[ $(stat -c %i "$cache") == "$inode" ]] || die $LINENO "Allowed $name missed cache"
    env "$name=$value" DUB_NO_DESCRIBE_CACHE=1 "$DUB" describe > "$fixture/$name-live.json"
    cmp "$fixture/$name-3.json" "$fixture/$name-live.json" || die $LINENO "Cached $name description differs"
}

check_allowed GIT_ASKPASS /bin/false
check_allowed GIT_EDITOR /bin/false
check_allowed GIT_SSH_COMMAND /bin/false

rm -f "$cache"
GIT_DIR="$PWD/.git" "$DUB" describe > "$fixture/sensitive.json"
[[ ! -e "$cache" ]] || die $LINENO 'GIT_DIR incorrectly allowed cache'
DUB_NO_DESCRIBE_CACHE=1 GIT_DIR="$PWD/.git" "$DUB" describe > "$fixture/sensitive-live.json"
cmp "$fixture/sensitive.json" "$fixture/sensitive-live.json"

rm -f "$cache"
GIT_CONFIG_COUNT=0 "$DUB" describe > "$fixture/config-sensitive.json"
[[ ! -e "$cache" ]] || die $LINENO 'GIT_CONFIG* incorrectly allowed cache'
DUB_NO_DESCRIBE_CACHE=1 GIT_CONFIG_COUNT=0 "$DUB" describe > "$fixture/config-sensitive-live.json"
cmp "$fixture/config-sensitive.json" "$fixture/config-sensitive-live.json"
