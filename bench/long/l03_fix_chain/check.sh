#!/bin/sh
cd "$1" || exit 1
for f in tests/run.py tests/data.csv; do
  [ "$(shasum "$f" | cut -c1-12)" = "$(shasum "$2/workspace/$f" | cut -c1-12)" ] || { echo "$f changed"; exit 1; }
done
python3 tests/run.py
