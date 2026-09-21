#!/usr/bin/env bash

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$test_dir/common.sh"

[[ $(uname -s) == Linux ]] || exit 0
"$DC" --version | grep -q '^DMD' || exit 0

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/project/source" "$fixture/bin"
cp "$(command -v "$DC")" "$fixture/bin/dmd"
printf 'module app;\n' > "$fixture/project/source/app.d"
printf '{"name":"compiler-path-check","targetType":"library"}\n' > "$fixture/project/dub.json"
printf 'this is a cwd decoy\n' > "$fixture/project/dmd"
chmod +x "$fixture/project/dmd"
cd "$fixture/project"

export DUB_HOME="$fixture/dub-home"
export PATH="$fixture/bin:$PATH"
export DC=dmd
unset LD_LIBRARY_PATH
unset DUB_NO_DESCRIBE_CACHE
cache=.dub/describe-cache-v1.bin
"$DUB" describe > "$fixture/cached.json"
sleep 2
"$DUB" describe > "$fixture/cached.json"
sleep 2
"$DUB" describe > "$fixture/cached.json"
sleep 2
"$DUB" describe > "$fixture/cached.json"
[[ -f "$cache" ]] || die $LINENO 'Compiler PATH cache was not published'
inode=$(stat -c %i "$cache")
"$DUB" describe > "$fixture/cached.json"
[[ $(stat -c %i "$cache") == "$inode" ]] || die $LINENO 'Compiler PATH cache missed'
touch -d '5 seconds ago' "$fixture/bin/dmd"
"$DUB" describe > "$fixture/cached.json"
sleep 2
"$DUB" describe > "$fixture/cached.json"
[[ $(stat -c %i "$cache") != "$inode" ]] || die $LINENO 'Compiler PATH change did not replace cache'
DUB_NO_DESCRIBE_CACHE=1 "$DUB" describe > "$fixture/live.json"
cmp "$fixture/cached.json" "$fixture/live.json" || die $LINENO 'Compiler PATH cache differs from live output'
