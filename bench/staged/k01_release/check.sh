#!/bin/sh
cd "$1" || exit 1
diff -rq -x __pycache__ -x gate.py . "$2/workspace" >/dev/null || { echo "the project is not as it was"; exit 1; }
