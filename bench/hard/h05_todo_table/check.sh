#!/bin/sh
cd "$1" || exit 1
tr -s ' ' < TODO.md | sed 's/ *$//' > /tmp/got.$$
tr -s ' ' < "$2/expected/TODO.md" | sed 's/ *$//' > /tmp/want.$$
diff /tmp/want.$$ /tmp/got.$$ && echo ok
