#!/usr/bin/env bash

. $(dirname "${BASH_SOURCE[0]}")/common.sh

project=$(mktemp -d)
trap 'rm -rf "$project"' EXIT
mkdir "$project/source"
printf 'module original;\n' > "$project/source/original.d"
cat > "$project/dub.json" <<'JSON'
{
    "name": "describe-generated-files",
    "targetType": "library",
    "preGenerateCommands": ["echo 'module generated;' > source/generated.d"]
}
JSON

# describe collects package settings before running generation hooks. Target
# settings must discover the new source rather than reuse the earlier scan.
"$DUB" describe --root="$project" --compiler="$DC" \
    --data=source-files --data-list > "$project/files"
if ! grep -Fx "$project/source/generated.d" "$project/files"; then
    die $LINENO 'describe missed a source created by preGenerateCommands'
fi
if ! grep -Fx "$project/source/original.d" "$project/files"; then
    die $LINENO 'describe missed the original source'
fi
