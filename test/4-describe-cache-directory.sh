#!/usr/bin/env bash

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$test_dir/common.sh"

[[ $(uname -s) == Linux ]] || exit 0
"$DC" --version | grep -q '^DMD' || exit 0

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/empty"
cd "$fixture/empty"

if "$DUB" describe > "$fixture/output" 2> "$fixture/error"; then
    die $LINENO 'describe unexpectedly succeeded outside a package'
fi
grep -q 'No valid root package found' "$fixture/error" \
    || die $LINENO 'describe emitted an unexpected no-package diagnostic'
[[ ! -e .dub ]] || die $LINENO 'describe created .dub outside a package'
