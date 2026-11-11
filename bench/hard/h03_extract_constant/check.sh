#!/bin/sh
cd "$1" || exit 1
python3 - "$2" <<'EOF'
import os, re, sys
problems = []
constants = open("src/constants.js").read() if os.path.exists("src/constants.js") else ""
if not re.search(r"export\s+const\s+SECONDS_PER_HOUR\s*=\s*3600", constants):
    problems.append("constants.js does not export SECONDS_PER_HOUR = 3600")
for name in ["cache.js", "session.js", "report.js"]:
    text = open("src/" + name).read()
    if "3600" in text: problems.append(name + " still has 3600")
    if "SECONDS_PER_HOUR" not in text: problems.append(name + " does not use the constant")
    if not re.search(r"import\s*\{[^}]*SECONDS_PER_HOUR[^}]*\}\s*from\s*['\"]\./constants(\.js)?['\"]", text):
        problems.append(name + " does not import it from ./constants")
if "SECONDS_PER_HOUR" in open("src/math.js").read(): problems.append("math.js was touched")
if open("test/fixtures/data.json").read() != open(sys.argv[1] + "/workspace/test/fixtures/data.json").read():
    problems.append("fixtures changed")
print("\n".join(problems) or "ok")
sys.exit(1 if problems else 0)
EOF
