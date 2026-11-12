#!/bin/sh
cd "$1" || exit 1
for f in "$2"/workspace/migrations/*.json "$2/workspace/db.py"; do
  name=${f#"$2/workspace/"}
  [ "$name" = migrations/0005_users_login.json ] && continue
  cmp -s "$f" "$name" || { echo "$name changed"; exit 1; }
done
python3 - "$2/expected/db.json" <<'PY'
import json, sys
got, want = json.load(open("db.json")), json.load(open(sys.argv[1]))
if got != want:
    print("db.json differs:", json.dumps(got, sort_keys=True))
    sys.exit(1)
print("ok")
PY
