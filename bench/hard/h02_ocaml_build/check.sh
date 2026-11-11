#!/bin/sh
cd "$1" || exit 1
diff -r lib "$2/workspace/lib" >/dev/null || { echo "lib changed"; exit 1; }
dune build 2>&1 && dune exec ./bin/main.exe
