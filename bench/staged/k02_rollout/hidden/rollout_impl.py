import configparser, os, sys

MS = {"billing": 30000, "search": 1500, "mail": 45000, "ledger": 120000, "auth": 500, "web": 12000}
OLD = {"billing": "30s", "search": "1.5s", "mail": "45", "ledger": "2m", "auth": "500ms", "web": "12s"}
V1 = ["ledger", "auth"]
OTHER = {"billing": {("db", "timeout"): "5s"}, "search": {("cache", "timeout"): "200ms", ("http", "idle_timeout"): "60s"},
         "mail": {("smtp", "timeout"): "10s"}, "ledger": {("db", "timeout"): "30s"}, "auth": {}, "web": {("cache", "timeout"): "1s"}}

def load(name):
    c = configparser.ConfigParser(interpolation=None)
    c.read("services/%s/app.ini" % name)
    return c

def problem():
    for name in sorted(MS):
        c = load(name)
        if not c.has_section("http"):
            return "services/%s/app.ini: no [http] section." % name
        h = c["http"]
        if "request_timeout_ms" not in h:
            return "services/%s/app.ini: [http] has no request_timeout_ms." % name
        if h["request_timeout_ms"].strip() != str(MS[name]):
            return "services/%s/app.ini: request_timeout_ms = %s is not the old timeout in milliseconds." % (name, h["request_timeout_ms"].strip())
        for (section, key), value in OTHER[name].items():
            if not c.has_option(section, key) or c.get(section, key).strip() != value:
                return "services/%s/app.ini: [%s] %s changed, and it is not part of this rollout." % (name, section, key)
        if name not in V1 and "timeout" in h:
            return "services/%s/app.ini: [http] still has timeout." % name
    for name in V1:
        h = load(name)["http"]
        if h.get("timeout", "").strip() != OLD[name]:
            return ("services/%s runs config loader v1, which cannot read request_timeout_ms. Until it "
                    "upgrades, its [http] section must also keep timeout, as it was before the rollout." % name)
    return None

if sys.argv[1:] != ["check"]:
    sys.exit("usage: python3 rollout.py check")
p = problem()
print(p if p else "Rollout ready: 6 services.")
sys.exit(1 if p else 0)
