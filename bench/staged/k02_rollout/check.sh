#!/bin/sh
cd "$1" || exit 1
cmp -s ROLLOUT.md "$2/workspace/ROLLOUT.md" || { echo "ROLLOUT.md changed"; exit 1; }
python3 -c "import sys; sys.argv=['rollout.py','check']; exec(open('$2/hidden/rollout_impl.py').read())" >/dev/null
