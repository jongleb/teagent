#!/bin/sh
cd "$1" || exit 1
for f in package.json src/version.ts CHANGELOG.md; do diff "$2/expected/$f" "$f" || exit 1; done
echo ok
