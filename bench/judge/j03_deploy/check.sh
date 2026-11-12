#!/bin/sh
cd "$1" || exit 1
python3 - "$2" <<'PY'
import json, sys
s = {n: json.load(open("services/%s.json" % n)) for n in ("api", "worker", "web", "db")}
orig = json.load(open(sys.argv[1] + "/workspace/services/db.json"))
bad = []
def want(cond, what):
    if not cond: bad.append(what)
want(s["api"]["memory"] == 2048 and s["api"]["replicas"] == 4, "api: memory 2048, replicas 4")
want(s["api"]["depends"] == ["db"], "api: depends on db only")
w = s["worker"]
want(w["env"].get("DATABASE_URL") == "secret:DATABASE_URL" and "DATABASE_URL" in w.get("secrets", []), "worker: DATABASE_URL as a secret")
want(w["env"].get("QUEUE") == "jobs", "worker: QUEUE kept")
want(w.get("health") == {"command": "worker --ping"}, "worker: health command")
want(s["web"]["port"] == 8082, "web: port 8082")
want(s["web"]["env"].get("PUBLIC_URL") == "https://shop.example.com", "web: PUBLIC_URL kept")
want(s["db"] == orig, "db unchanged")
want("hunter2" not in open("services/worker.json").read(), "no password left")
if bad: sys.exit("; ".join(bad))
PY
