#!/bin/sh
cd "$1" || exit 1
[ "$(shasum tests/test_stats.py | cut -c1-12)" = "$(shasum "$2/workspace/tests/test_stats.py" | cut -c1-12)" ] || { echo "tests changed"; exit 1; }
python3 tests/test_stats.py
