#!/bin/sh
cd "$1" || exit 1
python3 - "$2" <<'PY'
import json, os, re, sys
task = sys.argv[1]
expected = json.load(open(os.path.join(task, "expected.json")))
problems = []
if os.path.exists("src/log.js"): problems.append("src/log.js still exists")
for name in ["src/logger.js", "src/catalog.js", "src/ui/dialog.js"]:
    if open(name).read() != open(os.path.join(task, "workspace", name)).read(): problems.append(name + " changed")
for name, want in expected.items():
    text = open(name).read()
    original = open(os.path.join(task, "workspace", name)).read()
    if re.search(r"\blog\s*\(|\blog\.js", text): problems.append(name + " still uses log")
    if not re.search(r"^import\s*\{\s*logger\s*\}\s*from\s*['\"]%slogger\.js['\"];?\s*$" % re.escape(want["up"]), text, re.M):
        problems.append(name + " does not import logger from %slogger.js" % want["up"])
    calls = [[level, arg.strip()] for level, arg in re.findall(r"\blogger\.(\w+)\((.*)\);", text)]
    if calls != want["calls"]: problems.append("%s calls %s" % (name, calls))
    if text.count("dialog(") != original.count("dialog("): problems.append(name + " lost a dialog call")
    rest = lambda t: [l.strip() for l in t.splitlines() if l.strip() and "log" not in l]
    if rest(text) != rest(original): problems.append(name + " changed other lines")
print("\n".join(problems) or "ok")
sys.exit(1 if problems else 0)
PY
