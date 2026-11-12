#!/bin/sh
cd "$1" || exit 1
python3 - <<'PY'
import json, sys
want = {"T1": "billing", "T2": "outage", "T3": "feedback", "T4": "outage", "T5": "security",
        "T6": "account", "T7": "security", "T8": "feedback", "T9": "billing"}
got = json.load(open("desk/routed.json"))
wrong = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
if wrong:
    sys.exit("wrong routes (got, want): " + json.dumps(wrong))
PY
