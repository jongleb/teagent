## The program

- One module: `module Main exposing (main)`, `import Agent exposing (..)`, `main : Task e a`.
  Elm 0.19.1 without ports. Core: Basics, List, Maybe, Result, String, Char, Tuple, Dict, Set,
  plus `List.unique` (keeps the first of each value, in order). No Html, Json, Regex, Debug,
  Random, Time, `List.Extra`. `port`, `type`, `as`, `where` cannot be names or record fields
  (`type` declarations are fine).
- Agent functions take no prefix (`succeed`, not `Task.succeed`). `String.toInt`, `List.head`,
  `Dict.get` return `Maybe`. `fromResult` turns a `Result` into a task.
- Typechecked before anything runs; a program that does not compile changes nothing and the
  report comes back, often with a `Hint:`.
- `main`'s error type may stay open (`Task e a`), be `IoErr`, or be your own (convert with
  `mapErr`).

## How a run goes

- Tasks run one after another in `andThen` / `batch` order; `batch` stops at the first failure.
  `map2 f a b` runs `a`, then `b`, and combines them.
- `write` and `edit` are staged; later `read`, `grep` and `shell` see them. They are written
  together, and only if `main` succeeds: a failed, crashed or looping `main` writes nothing.
- So check the result before `main` succeeds: grep for what must be gone or must stay, run the
  tests, and `fail` when it is wrong. A replace that also hit a longer name (`log(` in
  `dialog(`) is caught this way and never written.
- The value of `main` comes back in Elm syntax. Secret-looking text shows as
  `[redacted secret]`.
- Paths are relative to the project root. Absolute paths, `..`, anything under `.git`,
  `.claude`, `.codex`, `.cursor`, `.vscode`, `.teagent`, `.envrc`, `.mcp.json` at any depth,
  and `.env` / `.env.*` files (not `.env.example` and the like) fail with `Denied`.

## The Agent calls

- `read path`: the file's text; `NotFound` or `Denied` otherwise.
- `write path text`: creates or replaces the file, with its folders.
- `edit { path, old, new }`: replaces the single occurrence of `old`; `Conflict` if it occurs
  zero or several times. To change every occurrence: `read`, `String.replace`, `write`.
- `grep { pattern, glob }`: one `Match` per line (`line` from 1, `path` from the root, in path
  order); `List.unique` the paths. `pattern`: `. * + ? [...] ^ $ | (...) \d \s \w \D \S \W \b`;
  a backslash makes a character literal and is doubled in Elm strings (`"Foo\\.bar"`); no
  `{n,m}`, no lookaround; an unreadable pattern finds nothing. `glob`: `*` `?` within a folder,
  `**` across folders (`**` alone is every file). Dot names, `_build`, `node_modules` are
  skipped. To list files: `shell "find . -type f"`.
- `shell command`: `/bin/sh -c` in the project root, in a sealed copy holding the staged
  changes. `out` is stdout and stderr; a non-zero `code` is a result, not a failure. Files it
  writes or deletes become staged changes, except caches (`__pycache__`, `*.pyc`, `_build`,
  `node_modules`, dot names). Paths in `out` name the project. No network unless hosts were
  granted, no API keys, 30 minutes. A refused command returns code 126 and the reason.
- `hole "what goes here"`: a task of any type, for code you can only write after seeing data.
  The run stops there and shows the values in scope; the code you send is typechecked in that
  place and the program runs again without repeating finished calls. One description per hole.
  The code replaces the hole in the program's text: a hole in a function or a loop gets the
  same code on every pass. Code that branches on the values decides every later pass without
  you; when each pass needs your judgement, leave a new hole for unseen cases or run one
  program per case. A run
  fills at most 8 holes; at a ninth it fails and writes nothing.
- `spawn mounts task`: a child that sees the changes so far, not what `mounts` hide
  (`Hidden`, `Readonly`, `Scratch` path), with changes of its own. `merge child` takes them,
  or fails with the clashes if a file moved meanwhile; an unmerged child leaves nothing.
- Rewriting a file with the same text is no change.

## Errors

`IoErr`: `NotFound path`; `Denied path` (refused, hidden or read-only path, or refused by the
person's rules); `Conflict reason` (`edit` did not match once, or the file changed on disk).

## What a person has to allow

- Files other programs run: git hooks and attributes (`.husky/`, `.pre-commit-config.yaml`,
  `.gitattributes`, `.gitmodules`), CI (`.github/workflows/`, `.gitlab-ci.yml`, …), npm/yarn
  settings and `package.json` `scripts` (a version change is fine), editor containers
  (`.devcontainer/`, `.idea/`), agent instructions (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`,
  …). Other changes are still written; the reply names the held files.
- Every value carries where its content came from. A `Fetch` call, or a shell command with
  granted hosts, that carries project content or was chosen by it needs a yes, as does
  everything after the session has read the project. Otherwise `Fetch` fails with `Declined`
  and a command gets 126. Reach the network before reading the project when you can.
- `Fetch.post` always needs a yes.

## From a shell

`teagent -C project --exec program.elm` does what `run` does and prints only the result and
the files written. Exit code: 0 done, 1 does not compile, 3 some files held, 4 `main` failed
(nothing written), 5 stopped at a hole (nothing written yet). At a hole it prints the values in
scope and the session log; `teagent --fill LOG code.elm` puts the expression in the hole and goes
on, exiting the same way. `--dry-run` writes nothing; `--trace` prints every call.
