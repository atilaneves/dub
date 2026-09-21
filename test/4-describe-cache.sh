#!/usr/bin/env bash

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$test_dir/common.sh"

# The initial fast path deliberately supports Linux and native DMD only.
[[ $(uname -s) == Linux ]] || exit 0
"$DC" --version | grep -q '^DMD' || exit 0

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export DUB_HOME="$fixture/dub-home"
unset DUB_NO_DESCRIBE_CACHE
mkdir -p "$fixture/project/source/empty"
cd "$fixture/project"
cache=.dub/describe-cache-v1.bin
printf 'module original;\n' > source/original.d
printf '{"name":"cache-check","targetType":"library"}\n' > dub.json

function check_description {
    # A first invocation can create selections or build directories. Such an
    # invocation must not publish a snapshot of inputs changed during the run.
    "$DUB" describe > "$fixture/cached.json"
    "$DUB" describe > "$fixture/cached.json"
    [[ -f "$cache" ]] || die $LINENO "No description cache: $1"
    local inode=$(stat -c %i "$cache")
    "$DUB" describe > "$fixture/cached.json"
    [[ $(stat -c %i "$cache") == "$inode" ]] || die $LINENO "Cache missed: $1"
    DUB_NO_DESCRIBE_CACHE=1 "$DUB" describe > "$fixture/live.json"
    cmp "$fixture/cached.json" "$fixture/live.json" || die $LINENO "Stale description: $1"
}

check_description initial
printf 'module added;\n' > source/empty/added.d
check_description 'source added in empty directory'
rm source/original.d
check_description 'source removed'
mkdir source/newdir
printf 'module newmodule;\n' > source/newdir/newmodule.d
check_description 'new directory'
printf '{"name":"renamed-cache-check","targetType":"library"}\n' > dub.json
check_description 'recipe changed'
printf '{"defaultArchitecture":"x86"}\n' > dub.settings.json
check_description 'settings created'
rm dub.settings.json
check_description 'settings removed'
printf '[Environment]\nDFLAGS=-m32\n' > dmd.conf
check_description 'compiler configuration created'
rm dmd.conf
check_description 'compiler configuration removed'
export DFLAGS=-version=CacheTest
check_description 'environment changed'
unset DFLAGS
check_description 'environment restored'
printf broken > "$cache"
check_description 'truncated cache'
printf garbage | dd of="$cache" bs=1 seek=150 conv=notrunc status=none
check_description 'corrupt cache payload'
printf '\377' | dd of="$cache" bs=1 seek=48 conv=notrunc status=none
check_description 'corrupt cache header'
rm "$cache"
mkfifo "$cache"
# Opening a non-regular cache must not block waiting for a writer.
timeout 10 "$DUB" describe > "$fixture/fifo.json"
check_description 'FIFO cache replaced'
cp -p dub.json "$fixture/recipe-before"
printf '{"name":"renamed-cache-again","targetType":"library"}\n' > dub.json
touch -r "$fixture/recipe-before" dub.json
check_description 'recipe modified with preserved mtime'
cp "$fixture/recipe-before" dub.json
check_description 'recipe restored'

mkdir "$fixture/external"
printf 'module linked;\n' > "$fixture/external/linked.d"
ln -s "$fixture/external" source/linked
check_description 'symlinked source tree'
printf 'module linkednew;\n' > "$fixture/external/linkednew.d"
check_description 'new source in symlinked tree'
rm source/linked
check_description 'symlink removed'
printf 'module switched;\n' > "$fixture/switch-target"
ln -s "$fixture/switch-target" source/switched.d
check_description 'symlink to file'
rm "$fixture/switch-target"
mkdir "$fixture/switch-target"
printf 'module nested;\n' > "$fixture/switch-target/nested.d"
check_description 'symlink target changed from file to directory'
rm source/switched.d


"$DUB" describe --data=target-name --data-list > "$fixture/name"
grep -Fx renamed-cache-check "$fixture/name" >/dev/null || die $LINENO 'Cached JSON used for --data'

# Generation hooks must execute on every call, including after a cached recipe
# acquires a hook. Their side effects cannot be represented by cached JSON.
printf '{"name":"cache-check","targetType":"library","preGenerateCommands":["echo tick >> counter"]}\n' > dub.json
"$DUB" describe > "$fixture/hook.json"
"$DUB" describe > "$fixture/hook.json"
[[ $(wc -l < counter) == 2 ]] || die $LINENO 'Generation hook was skipped'
printf '{"name":"cache-check","targetType":"library"}\n' > dub.json

git init -q
git add dub.json source
git -c user.name='Cache Test' -c user.email=cache@example.invalid commit -qm Initial
git tag v1.0.0
check_description 'Git repository and tag created'
git tag v2.0.0
check_description 'Git tag added'
git pack-refs --all
check_description 'Git refs packed'
git tag -d v2.0.0 >/dev/null
check_description 'Git tag removed'

# Globs can select files outside the default source/import directories.
mkdir -p extra/nested
printf 'module extra;\n' > extra/one.d
printf '{"name":"cache-check","targetType":"library","sourceFiles":["extra/**/*.d"]}\n' > dub.json
check_description 'explicit source glob'
printf 'module second;\n' > extra/nested/second.d
check_description 'source added under glob'

# Selections may be inherited, and registered local packages and overrides are
# additional inputs beyond the root recipe and its source tree.
for version in 1 2; do
    mkdir -p "$fixture/dep-$version/source"
    printf 'module dep;\n' > "$fixture/dep-$version/source/dep.d"
    printf '{"name":"cache-dep","targetType":"sourceLibrary","description":"dependency %s"}\n' "$version" > "$fixture/dep-$version/dub.json"
    "$DUB" add-local "$fixture/dep-$version" "$version.0.0" >/dev/null
done
printf '{"name":"cache-check","targetType":"library","dependencies":{"cache-dep":">=1.0.0"}}\n' > dub.json
rm -f dub.selections.json
printf '{"fileVersion":1,"inheritable":true,"versions":{"cache-dep":"1.0.0"}}\n' > ../dub.selections.json
check_description 'inherited selections'
grep -F 'dependency 1' "$fixture/cached.json" >/dev/null || die $LINENO 'Wrong inherited selection'
printf '{"fileVersion":1,"inheritable":true,"versions":{"cache-dep":"2.0.0"}}\n' > ../dub.selections.json
check_description 'inherited selections changed'
grep -F 'dependency 2' "$fixture/cached.json" >/dev/null || die $LINENO 'Stale inherited selection'
"$DUB" add-override cache-dep '>=1.0.0' "$fixture/dep-1" >/dev/null
# Overrides emit deprecation warnings, so these calls must use the normal path.
"$DUB" describe > "$fixture/cached.json" 2> "$fixture/warnings"
DUB_NO_DESCRIBE_CACHE=1 "$DUB" describe > "$fixture/live.json" 2>/dev/null
cmp "$fixture/cached.json" "$fixture/live.json"
grep -F 'Overrides are deprecated' "$fixture/warnings" >/dev/null || die $LINENO 'Override warning was suppressed'
