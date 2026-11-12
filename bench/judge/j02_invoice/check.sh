#!/bin/sh
cd "$1" || exit 1
cmp -s PRICING.md "$2/workspace/PRICING.md" || { echo "PRICING.md changed"; exit 1; }
grep -q 'render_impl.py' render.py || { echo "render.py changed"; exit 1; }
[ "$(find . -type f | wc -l)" -eq 2 ] || { echo "files added"; exit 1; }
