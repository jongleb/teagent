import os, sys

WANT_VERSION = {"core": "3.0.0", "api": "1.9.0", "cli": "0.9.4", "web": "3.1.2"}
WANT_DEPS = {"core": "", "api": "core ^3.0\n", "cli": "core ^3.0\napi ^1.8\n", "web": "api ^1.8\n"}
WANT_CHANGES = """# Changes

## Unreleased

## core 3.0.0

- core: Parsing large config files is about twice as fast.
- core: `Config.load_file` is gone; call `Config.load` with a path instead.

## api 1.9.0

- api: New endpoint `/v2/health` reports the state of every backend.

## cli 0.9.4

- cli: Fixed a crash when the config path contains spaces.

## core 2.4.1

- core: Fixed reading configs with a byte order mark.

## web 3.1.2

- web: The login page no longer flashes on slow networks.
"""

def sections(text):
    out, current = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("## "):
            current = (line, [])
            out.append(current)
        elif line.startswith("- ") and current is not None:
            current[1].append(line)
    return [(head, sorted(entries)) for head, entries in out]

def read(path):
    try:
        return open(path).read()
    except OSError:
        return None

def problem():
    for name in ("core", "api", "cli", "web"):
        got = (read("packages/%s/VERSION" % name) or "").strip()
        if got != WANT_VERSION[name]:
            return "packages/%s/VERSION is %s, which does not match the changes listed for %s." % (name, got or "missing", name)
    for name in ("core", "api", "cli", "web"):
        got = read("packages/%s/deps" % name)
        if (got or "").strip() != WANT_DEPS[name].strip():
            return "packages/%s/deps does not pin what %s's dependencies now are." % (name, name)
    got = read("CHANGES.md") or ""
    if sections(got) != sections(WANT_CHANGES):
        return "CHANGES.md is not laid out as RELEASING.md says for this release."
    return None

if sys.argv[1:]:
    sys.exit("usage: python3 gate.py")
p = problem()
if p:
    print("Not ready: " + p)
    sys.exit(1)
print("Blocked: core 3.0.0 is a major release, and a major release of core needs a migration "
      "guide approved by the core team, which the release team has not received. The release "
      "cannot go out this week. Nothing may be left half released: put every file back.")
sys.exit(2)
