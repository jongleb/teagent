"""Draws the README's figures. Run from the repository root: python3 assets/draw.py"""

from html import escape

BG = "#050607"
PANEL = "#0c0e10"
RAISED = "#121518"
LINE = "#24282d"
TEXT = "#e8ecef"
MUTED = "#7f8790"
DIM = "#4b5158"
RED = "#ff3d3d"
AMBER = "#ffb21e"
GREEN = "#34e089"
CYAN = "#5cc8ff"

MONO = "ui-monospace, SFMono-Regular, 'JetBrains Mono', Menlo, Consolas, monospace"

STYLE = f"""<style>
text {{ font-family: {MONO}; fill: {TEXT}; }}
.muted {{ fill: {MUTED}; }}
.dim {{ fill: {DIM}; }}
.red {{ fill: {RED}; }}
.amber {{ fill: {AMBER}; }}
.green {{ fill: {GREEN}; }}
.cyan {{ fill: {CYAN}; }}
.flow {{ stroke-dasharray: 6 8; animation: flow 1.2s linear infinite; }}
@keyframes flow {{ to {{ stroke-dashoffset: -28; }} }}
.blink {{ animation: blink 1.1s steps(1) infinite; }}
@keyframes blink {{ 50% {{ opacity: 0; }} }}
@media (prefers-reduced-motion: reduce) {{ .flow, .blink {{ animation: none; }} }}
</style>"""


def text(x, y, body, size=11, cls="", weight=400, anchor="start", spacing=0):
    attributes = f' class="{cls}"' if cls else ""
    tracking = f' letter-spacing="{spacing}"' if spacing else ""
    return (
        f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
        f'text-anchor="{anchor}" xml:space="preserve"{tracking}{attributes}>{escape(body)}</text>'
    )


def box(x, y, w, h, stroke=LINE, fill=PANEL, radius=6, width=1.2, dash=""):
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="{width}"{dashed}/>'
    )


def bar(x, y, w, h=9):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="1.5" fill="#000" stroke="#2c3036" stroke-width="0.8"/>'


def arrow(x1, y1, x2, y2, color=DIM, moving=True):
    cls = ' class="flow"' if moving else ""
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="1.4"{cls}/>'
        f'<path d="M{x2},{y2} l-7,-4 v8 z" fill="{color}" transform="rotate({angle(x1, y1, x2, y2)} {x2} {y2})"/>'
    )


def angle(x1, y1, x2, y2):
    from math import atan2, degrees

    return round(degrees(atan2(y2 - y1, x2 - x1)), 2)


def stamp(x, y, label, color=RED, rotate=-6, size=11):
    width = len(label) * size * (0.6 + 0.15) + 18
    return (
        f'<g transform="rotate({rotate} {x + width / 2} {y})">'
        f'<rect x="{x}" y="{y - size - 3}" width="{width}" height="{size + 10}" rx="3" fill="none" '
        f'stroke="{color}" stroke-width="1.6"/>'
        + text(x + width / 2, y + 1, label, size, weight=700, anchor="middle", spacing=1.5).replace(
            "<text ", f'<text fill="{color}" style="fill:{color}" '
        )
        + "</g>"
    )


def chip(x, y, label, color, size=10):
    width = len(label) * size * 0.62 + 14
    return (
        f'<rect x="{x}" y="{y - size - 2}" width="{width}" height="{size + 8}" rx="3" '
        f'fill="{color}" fill-opacity="0.12" stroke="{color}" stroke-width="1"/>'
        + text(x + 7, y + 1, label, size, weight=650).replace("<text ", f'<text style="fill:{color}" ')
    )


def frame(name, width, height, code, title, body, mark="RESTRICTED"):
    head = (
        box(0.5, 0.5, width - 1, height - 1, stroke="#1b1e22", fill=BG, radius=12, width=1)
        + f'<line x1="0" y1="34" x2="{width}" y2="34" stroke="#16191c"/>'
        + f'<circle cx="18" cy="17" r="3.5" fill="{RED}" class="blink"/>'
        + text(30, 21, f"TEAGENT // {code}", 10, "muted", 600, spacing=2)
        + text(width - 16, 21, mark, 10, "red", 700, "end", spacing=2.5)
        + text(18, 60, title, 13.5, weight=650)
    )
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" role="img">{STYLE}{head}{body}</svg>'
    )
    with open(f"assets/{name}.svg", "w") as out:
        out.write(svg)


def logo():
    body = (
        box(0.5, 0.5, 159, 159, stroke="#1b1e22", fill=BG, radius=28, width=1)
        + f'<path d="M44 82 h62 v18 a26 26 0 0 1 -26 26 h-10 a26 26 0 0 1 -26 -26 z" fill="none" '
        f'stroke="{TEXT}" stroke-width="5" stroke-linejoin="round"/>'
        + f'<path d="M106 88 h6 a11 11 0 0 1 0 22 h-8" fill="none" stroke="{TEXT}" stroke-width="5"/>'
        + f'<line x1="36" y1="134" x2="124" y2="134" stroke="{TEXT}" stroke-width="5" stroke-linecap="round"/>'
        + text(80, 66, "{ }", 26, weight=700, anchor="middle").replace("<text ", f'<text style="fill:{GREEN}" ')
        + f'<rect x="52" y="93" width="46" height="9" rx="2" fill="{RED}"/>'
    )
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160" width="160" height="160" role="img">'
        f"{STYLE}{body}</svg>"
    )
    with open("assets/logo.svg", "w") as out:
        out.write(svg)


def stats():
    tiles = [
        ("20/20", "reference tasks", "pass on the bench"),
        ("1", "way to act", "a Task value"),
        ("5", "call classes", "pure → irreversible"),
        ("0.32 s", "to clone 2,093 files", "for a sandboxed shell"),
        ("ABI 2", "exact replay", "of any session log"),
    ]
    body = ""
    for index, (big, line, small) in enumerate(tiles):
        x = 16 + index * 172
        body += box(x, 76, 160, 92, fill=PANEL)
        body += text(x + 14, 116, big, 28, weight=700)
        body += text(x + 14, 140, line.upper(), 9.5, "muted", 600, spacing=1)
        body += text(x + 14, 156, small, 10, "dim")
    frame("stats", 880, 184, "FILE 00 · VITALS", "One program, checked before anything runs", body, "UNCLASSIFIED")


def pipeline():
    stages = [
        ("MODEL", ["writes one", "Dartea program"], TEXT),
        ("TYPECHECK", ["≤ 4 rounds;", "reports go back"], CYAN),
        ("PLAN CHECK", ["reachable calls;", "leak legs"], AMBER),
        ("INTERPRET", ["tree of effects,", "values labelled"], TEXT),
        ("HANDLER", ["budget, journal,", "policy, tools"], RED),
        ("REVIEW", ["the diff; hooks", "and CI apart"], AMBER),
        ("COMMIT", ["one write;", "undo any time"], GREEN),
    ]
    body = ""
    for index, (name, lines, color) in enumerate(stages):
        x = 16 + index * 122
        body += box(x, 84, 108, 96, stroke=color if color != TEXT else LINE, fill=PANEL)
        body += text(x + 10, 106, f"{index + 1:02d}", 9.5, "dim", 700)
        body += text(x + 10, 124, name, 11.5, weight=700).replace("<text ", f'<text style="fill:{color}" ')
        for row, line in enumerate(lines):
            body += text(x + 10, 146 + row * 15, line, 10, "muted")
        if index < len(stages) - 1:
            body += arrow(x + 108, 132, x + 122, 132)
    body += f'<path d="M190 182 v26 h-122 v-26" fill="none" stroke="{CYAN}" stroke-width="1.2" class="flow"/>'
    body += text(76, 226, "a report goes back to the model, not a crash", 10, "cyan")
    body += text(374, 226, "nothing runs until both checks pass", 10, "amber")
    body += text(612, 226, "every call: rules, labels, consent", 10, "red")
    frame("pipeline", 880, 262, "FILE 01 · PIPELINE", "From a model's reply to a commit", body)


def tree():
    body = (
        box(16, 80, 230, 52, stroke=LINE)
        + text(30, 102, "main", 13, weight=700)
        + text(30, 120, ": Task Err { out, code }", 10, "muted")
        + arrow(246, 106, 292, 106)
        + box(292, 80, 150, 52, stroke=CYAN, fill=RAISED)
        + text(306, 102, "And_then", 12, "cyan", 700)
        + text(306, 120, "λ _ → shell \"dune test\"", 9.5, "muted")
        + arrow(442, 106, 488, 106)
        + box(488, 80, 150, 52, stroke=CYAN, fill=RAISED)
        + text(502, 102, "And_then", 12, "cyan", 700)
        + text(502, 120, "λ ms → batch [edit…]", 9.5, "muted")
        + arrow(638, 106, 684, 106)
        + box(684, 80, 180, 52, stroke=AMBER, fill=RAISED)
        + text(698, 102, "Tool (Grep …)", 12, "amber", 700)
        + text(698, 120, "pattern \"Foo\\.bar\"", 9.5, "muted")
        + text(16, 170, "the whole program is a value. a handler walks it: perform, stage, replay.", 10.5, "muted")
        + stamp(640, 172, "0 EFFECTS PERFORMED", GREEN, -4, 10)
    )
    frame("tree", 880, 200, "FILE 02 · TASK TREE", "What main evaluates to, before anything runs", body)


def shell():
    rules = [
        ("deny by default", "Seatbelt / bubblewrap"),
        ("writes", "only inside the clone"),
        ("network", f"proxy to --net hosts only"),
        ("environment", "PATH, HOME, toolchains; no keys"),
        ("closed", "clipboard, keychain, sockets"),
        ("limits", "30 min · 4 GiB files · procs + 1024"),
    ]
    body = (
        box(16, 80, 190, 150)
        + text(30, 104, "PROJECT", 11, "muted", 700, spacing=1.5)
        + text(30, 126, "lib/a.ml", 11)
        + text(30, 144, "lib/b.ml", 11)
        + text(30, 162, ".env", 11, "dim")
        + bar(70, 154, 60)
        + text(30, 186, "+ staged edits", 10.5, "amber")
        + text(30, 210, "APFS clone · reflink", 10, "dim")
        + arrow(206, 155, 248, 155)
        + box(248, 72, 396, 166, stroke=RED, fill=RAISED, width=1.6)
        + text(264, 96, "CONTAINED SHELL", 11.5, "red", 700, spacing=2)
    )
    for index, (left, right) in enumerate(rules):
        body += text(264, 120 + index * 19, left, 10.5, weight=650)
        body += text(392, 120 + index * 19, right, 10.5, "muted")
    body += arrow(644, 155, 686, 155, GREEN)
    body += box(686, 80, 178, 150, stroke=GREEN)
    body += text(700, 104, "BACK AS DATA", 11, "green", 700, spacing=1.5)
    body += text(700, 128, "files written", 10.5)
    body += text(700, 146, "files deleted", 10.5)
    body += text(700, 168, "→ staged changes", 10.5, "muted")
    body += text(700, 186, "→ in the diff you", 10.5, "muted")
    body += text(700, 204, "  approve", 10.5, "muted")
    frame("shell", 880, 252, "FILE 03 · CONTAINMENT", "A command never touches your folder", body)


def replay():
    rows = [
        ('{"task": "…", "abi": 2, "image": "4b17…c6c"}', "cyan"),
        ('{"wrote": "```elm module Main …"}', "muted"),
        ('{"performed": {"tool": {"read": "lib/a.ml"}, …}}', "muted"),
        ('{"held": {"diff": "+++ b/AGENTS.md …", "decision": "discard"}}', "amber"),
        ('{"committed": ["lib/a.ml"]}', "green"),
    ]
    body = box(16, 76, 520, 138)
    for index, (row, cls) in enumerate(rows):
        body += text(30, 100 + index * 24, row, 10.5, cls)
    body += arrow(536, 112, 590, 112)
    body += arrow(536, 178, 590, 178)
    body += box(590, 84, 274, 56, stroke=CYAN, fill=RAISED)
    body += text(604, 106, "--replay", 12, "cyan", 700)
    body += text(604, 126, "no model, no disk; checks every event", 9.5, "muted")
    body += box(590, 150, 274, 56, stroke=GREEN, fill=RAISED)
    body += text(604, 172, "--resume", 12, "green", 700)
    body += text(604, 192, "plays the log, then goes on live", 9.5, "muted")
    body += text(16, 238, "a log names its ABI and the hash of its OS. another build, same ABI: same events.", 10.5, "muted")
    body += text(16, 256, "labels of values are never logged; the interpreter computes them again.", 10.5, "dim")
    frame("replay", 880, 276, "FILE 04 · JOURNAL", "Every session is a log of what the world answered", body)


def os_layers():
    layers = [
        ("PROGRAM", "Main.elm, written by the model; it can only ask", "your code", TEXT),
        ("CALLS", "Agent and drivers, cut to the OS before compiling", "syscall table", CYAN),
        ("PROCESSES", "spawn narrows the view; merge joins it back", "fork · join", CYAN),
        ("FILES", "hidden · readonly · scratch · staged; .env hidden; tooling denied", "mount table", AMBER),
        ("BOOT LAYERS", "budget → journal → policy (rules, labels, consent)", "kernel modules", RED),
        ("OUTSIDE", "held files, Egress asks, --net proxy, commit", "firewall", GREEN),
    ]
    body = ""
    for index, (name, line, analog, color) in enumerate(layers):
        y = 76 + index * 52
        body += box(16, y, 640, 44, stroke=color if color != TEXT else LINE, fill=PANEL)
        body += text(30, y + 27, name, 11.5, weight=700).replace("<text ", f'<text style="fill:{color}" ')
        body += text(156, y + 27, line, 10.5, "muted")
        body += text(680, y + 27, analog.upper(), 10, "dim", 700, spacing=1.5)
        body += f'<line x1="656" y1="{y + 22}" x2="672" y2="{y + 22}" stroke="{DIM}" stroke-dasharray="2 3"/>'
    body += text(16, 404, "an OS value only narrows: every right comes from granted, the profile can only take some away.", 10.5, "muted")
    frame("os", 880, 422, "FILE 05 · MICRO-OS", "teagent as a small operating system", body)


def holes():
    body = (
        box(16, 76, 410, 176)
        + text(30, 100, "main", 11, "muted", 700)
        + text(30, 122, 'read "lib/x.ml"', 11)
        + text(30, 140, "  |> andThen (\\src ->", 11)
        + box(56, 150, 350, 82, stroke=AMBER, fill=RAISED, dash="4 4")
        + text(70, 172, 'hole "fix the call"', 11, "amber", 700)
        + text(70, 194, '→ edit { path = "lib/x.ml", … }', 10.5, "muted")
        + text(70, 214, "  typechecked in place, then run", 10.5, "dim")
    )
    runs = [("read", ["run", "↺", "↺"]), ("hole", ["asks", "", ""]), ("edit", ["", "run", "↺"]), ("shell", ["", "", "run"])]
    body += text(470, 100, "TOOL", 10, "dim", 700, spacing=1.5)
    for column in range(3):
        body += text(560 + column * 100, 100, f"RUN {column + 1}", 10, "dim", 700, spacing=1.5)
    for row, (name, cells) in enumerate(runs):
        y = 126 + row * 28
        body += text(470, y, name, 11)
        for column, cell in enumerate(cells):
            cls = {"run": "green", "asks": "amber", "↺": "dim"}.get(cell, "dim")
            body += text(560 + column * 100, y, cell or "·", 11, cls, 650)
    body += text(16, 278, "the model sees the values in scope; every line it writes there carries what the session read.", 10.5, "muted")
    frame("holes", 880, 296, "FILE 06 · HOLES", "Code the model writes after it has seen data", body)


def flow():
    body = (
        box(16, 80, 210, 52, stroke=LINE)
        + text(30, 102, 'read "lib/a.ml"', 11, weight=650)
        + chip(30, 122, "File lib/a.ml", AMBER, 9.5)
        + arrow(226, 106, 262, 106)
        + box(262, 80, 270, 52, stroke=AMBER, fill=RAISED)
        + text(276, 102, '"https://x/?q=" ++ text', 11, weight=650)
        + chip(276, 122, "File lib/a.ml", AMBER, 9.5)
        + arrow(532, 106, 568, 106)
        + box(568, 80, 140, 52, stroke=RED, fill=RAISED)
        + text(582, 102, "Fetch.get", 11.5, "red", 700)
        + text(582, 120, "Egress", 10, "muted")
        + arrow(708, 106, 744, 106, RED)
        + stamp(748, 110, "ASK", AMBER, -5, 12)
        + box(16, 156, 210, 52, stroke=LINE)
        + text(30, 178, 'if text == "x" then …', 11, weight=650)
        + chip(30, 198, "File lib/a.ml", AMBER, 9.5)
        + arrow(226, 182, 262, 182)
        + box(262, 156, 270, 52, stroke=AMBER, fill=RAISED)
        + text(276, 178, "the branch chose the call", 11, weight=650)
        + chip(276, 198, "File lib/a.ml", AMBER, 9.5)
        + arrow(532, 182, 744, 182, RED)
        + stamp(748, 186, "ASK", AMBER, -5, 12)
        + box(16, 232, 210, 52, stroke=LINE)
        + text(30, 254, '"https://x/fixed"', 11, weight=650)
        + text(30, 274, "no labels", 10, "dim")
        + arrow(226, 258, 744, 258, GREEN)
        + stamp(748, 262, "ALLOW", GREEN, -5, 12)
        + text(16, 314, "rules.elm sees the same labels and the session's history, and may answer Deny first.", 10.5, "muted")
    )
    frame("flow", 880, 334, "FILE 07 · PROVENANCE", "Every value knows where its content came from", body)


def threats():
    rows = [
        ("injected text adds a call", "program fixed and typechecked before data", "CLOSED", GREEN),
        ("project data leaves via Fetch", "labels on values; Egress asks the person", "ASKS", AMBER),
        ("model pastes what it saw", "code labelled by the session's reads", "ASKS", AMBER),
        ("shell reads API keys", "environment allowlist", "CLOSED", GREEN),
        ("escape via clipboard, keychain, sockets", "Seatbelt deny by default", "CLOSED", GREEN),
        ("hooks, CI, AGENTS.md planted", "held apart; only a person allows", "ASKS", AMBER),
        (".env and home secrets", "hidden; redacted before the model", "CLOSED", GREEN),
        ("fork bomb, runaway command", "limits; process group killed", "CLOSED", GREEN),
        ("questions until you say yes", "silent no after 3 refusals", "CLOSED", GREEN),
        ("repo skills trusted on sight", "trust by hash: next on the list", "OPEN", RED),
        ("launchd service list readable", "read only; no job can start", "OPEN", RED),
    ]
    body = (
        text(16, 92, "THREAT", 10, "dim", 700, spacing=1.5)
        + text(330, 92, "CONTROL", 10, "dim", 700, spacing=1.5)
        + text(864, 92, "STATUS", 10, "dim", 700, "end", spacing=1.5)
    )
    for index, (threat, control, status, color) in enumerate(rows):
        y = 116 + index * 26
        body += f'<line x1="16" y1="{y + 8}" x2="864" y2="{y + 8}" stroke="#14171a"/>'
        body += text(16, y, threat, 11)
        body += text(330, y, control, 10.5, "muted")
        body += chip(864 - (len(status) * 9.5 * 0.62 + 14), y, status, color, 9.5)
    frame("threats", 880, 116 + len(rows) * 26 + 10, "FILE 08 · THREAT LEDGER", "What stops what, and what is still open", body, "EYES ONLY")


def parts():
    def part(x, y, w, name, where, lines, color):
        drawn = box(x, y, w, 22 + 16 * len(lines) + 12, stroke=color, fill=PANEL)
        drawn += text(x + 12, y + 20, name, 11.5, weight=700).replace("<text ", f'<text style="fill:{color}" ')
        drawn += text(x + w - 10, y + 20, where, 9.5, "dim", 600, "end")
        for row, line in enumerate(lines):
            drawn += text(x + 12, y + 40 + row * 16, line, 10, "muted")
        return drawn

    body = (
        part(16, 76, 230, "PERSON", "you", ["the task; yes or no;", "rules.elm and the profile"], TEXT)
        + part(325, 76, 230, "MODEL", "lib/llm", ["writes each program and", "the code for each hole"], TEXT)
        + part(634, 76, 230, "OTHER AGENT", "Claude Code, Codex", ["sends whole programs,", "or single tools"], TEXT)
        + part(16, 176, 560, "SESSION LOOP", "lib/driver", ["asks the model, compiles, runs, settles the diff, keeps the log;", "the same loop replays a log, or resumes from it"], CYAN)
        + part(600, 176, 264, "MCP SERVER", "lib/mcp", ["run, fill and the tools,", "with no person to ask"], CYAN)
        + part(16, 276, 200, "OS VALUE", "lib/os", ["calls, mounts, hosts, limits,", "boot order, rules; image"], AMBER)
        + part(232, 276, 200, "COMPILER", "lib/lang", ["Dartea → IR, cut to the OS;", "the calls it can reach"], CYAN)
        + part(448, 276, 200, "INTERPRETER", "lib/interp", ["IR → a tree of effects;", "every value labelled"], CYAN)
        + part(664, 276, 200, "RUN", "lib/run", ["one program; holes and", "their fills, no repeats"], CYAN)
        + part(16, 380, 416, "HANDLER", "lib/effect", ["boot layers: budget → journal → policy (rules, labels,", "consent); the staged overlay and its diff"], RED)
        + part(448, 380, 416, "TOOLS", "lib/tools · lib/device", ["the only IO: files, search, the sandbox, the proxy,", "limits, redaction, the commit; drivers such as Fetch"], RED)
        + arrow(131, 140, 131, 176)
        + arrow(430, 140, 430, 176)
        + arrow(450, 176, 450, 140, DIM)
        + arrow(749, 140, 749, 176)
        + arrow(332, 238, 332, 276)
        + arrow(540, 238, 700, 276)
        + arrow(764, 238, 764, 276)
        + arrow(216, 308, 232, 308, AMBER, False)
        + arrow(664, 308, 648, 308, DIM, False)
        + arrow(116, 340, 116, 380, AMBER)
        + arrow(548, 340, 330, 380)
        + arrow(432, 412, 448, 412, RED)
        + text(16, 482, "arrows show who hands what to whom. only TOOLS touches your disk or the network.", 10.5, "muted")
    )
    frame("map", 880, 500, "FILE 09 · MAP", "Who does what, and who hands what to whom", body)


for draw in (logo, stats, pipeline, tree, shell, replay, os_layers, holes, flow, threats, parts):
    draw()
