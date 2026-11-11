#!/bin/sh
cd "$1" || exit 1
for f in pkg/config.py pkg/app.py docs/usage.md; do diff "$2/expected/$f" "$f" || exit 1; done
echo ok
