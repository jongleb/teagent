import json, os, sys

LIMIT = 2048
TAKEN = {8080: "legacy-web", 8081: "metrics"}

def problem():
    services = {}
    for name in sorted(os.listdir("services")):
        if name.endswith(".json"):
            try:
                services[name] = json.load(open(os.path.join("services", name)))
            except ValueError as e:
                return "services/%s: not valid JSON (%s)." % (name, e)
    names = {s.get("name") for s in services.values()}
    for f, s in services.items():
        if s.get("memory", 0) > LIMIT:
            return "services/%s: memory %d is over the plan's limit of %d per replica." % (f, s["memory"], LIMIT)
    for f, s in services.items():
        for k, v in s.get("env", {}).items():
            if isinstance(v, str) and "://" in v and "@" in v.split("://", 1)[1]:
                return "services/%s: env %s holds a credential." % (f, k)
        for k in s.get("secrets", []):
            if s.get("env", {}).get(k) != "secret:" + k:
                return "services/%s: secret %s is not used as secret:%s in env." % (f, k, k)
    for f, s in services.items():
        p = s.get("port")
        if p is not None and p < 1024:
            return "services/%s: port %d is reserved by the router." % (f, p)
        if p in TAKEN:
            return "services/%s: port %d is taken on the cluster by %s." % (f, p, TAKEN[p])
    for f, s in services.items():
        if s.get("kind") != "database" and "health" not in s:
            return "services/%s: no health check." % f
    for f, s in services.items():
        for d in s.get("depends", []):
            if d not in names:
                return "services/%s: depends on %s, which no service provides." % (f, d)
    return None

if sys.argv[1:] != ["check"]:
    sys.exit("usage: python3 deploy.py check")
p = problem()
print(p if p else "Ready to deploy: %d services." % len(os.listdir("services")))
sys.exit(1 if p else 0)
