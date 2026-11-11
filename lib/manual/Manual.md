## The program

- One module: `module Main exposing (main)`, `import Agent exposing (..)`, and `main : Task e a`.
  The language is Elm 0.19.1 without ports. The core modules Basics, List, Maybe, Result,
  String, Char, Tuple, Dict and Set are there, plus `List.unique`; there is no Html, Json,
  Regex, Debug, Random, Time and no `List.Extra`. `port`, `type`, `as` and `where` are reserved.
- Write the Agent functions without a prefix: `succeed`, `andThen`, not `Task.succeed`.
  `String.toInt`, `List.head` and `Dict.get` return a `Maybe` (`Just` / `Nothing`), not a
  `Result`. `fromResult` turns a `Result` into a task.
- The whole program is typechecked before anything runs. A program that does not compile
  changes nothing; the compiler's report comes back, often with a `Hint:` line.
- `main` may keep its error type open (`Task e a`) when nothing can fail, use `IoErr`, or use
  a type of its own; convert each `IoErr` into it with `mapErr`.

## How a run goes

- Tasks run one after another, in the order `andThen` and `batch` give. `batch` runs its tasks
  in order and stops at the first one that fails. `map2 f first second` runs `first`, then
  `second`, and combines their values.
- `write` and `edit` are staged. Every later `read`, `grep` and `shell` of the same program
  sees them.
- Staged changes are written to the project together, and only if `main` succeeds. If `main`
  fails, crashes or runs out of steps, nothing it changed is written; failing on purpose after
  a check that did not pass is a fine way to throw changes away.
- The value of `main` comes back in Elm syntax, with strings quoted and escaped. Text that looks
  like a secret (an API key, a token, a private key) is shown as `[redacted secret]`.
- Paths are relative to the project's root. An absolute path, a path with `..`, a path into
  `.git`, `.claude`, `.codex`, `.cursor`, `.vscode`, `.teagent`, `.envrc` or `.mcp.json` at any
  depth, and any `.env` or `.env.*` file (but `.env.example` and the like) fail with `Denied`.

## The Agent calls

- `read path`: the whole text of the file. `NotFound path` if there is none, `Denied path` if
  the path is refused.
- `write path text`: creates or replaces the whole file, with its folders.
- `edit { path, old, new }`: replaces the one place where `old` occurs. It fails with
  `Conflict` when `old` is not in the file or occurs more than once: include enough
  surrounding text to make it unique, or `read`, change the text with `String.replace` and
  `write` it back to change every occurrence.
- `grep { pattern, glob }`: one `Match` per matching line, `line` counted from 1, `path`
  relative to the root, files in path order. Several matches in one file give several
  `Match`es with the same path; use `List.unique` on the paths. `pattern` is a regular
  expression with `.`, `*`, `+`, `?`, `[...]`, `^`, `$`, `|`, `(...)`, `\d`, `\s`, `\w` (and
  `\D`, `\S`, `\W`) and `\b`; write a backslash twice in an Elm string (`"\\s+"`). There is no
  `{n,m}` and no lookaround, and a pattern grep cannot read finds nothing. `glob`: `*` and `?`
  within one folder, `**` across any number of folders, so `**/*.ml` and `lib/**` work and
  `**` alone is every file. Folders and files whose names start with a dot, `_build` and
  `node_modules` are not searched. To list files, `shell "find . -type f"` is the plain way.
- `shell command`: runs `/bin/sh -c command` in the project's root, in a sealed copy that holds
  the program's staged changes. `out` is stdout and stderr together; `code` is the exit code,
  and a code other than 0 is a result, not a failure. Files the command writes or deletes
  become staged changes like any edit. There is no network, unless the person granted hosts;
  there are no API keys in its environment; it may run 30 minutes. A command teagent will not
  run returns code 126 and the reason in `out`.
- `hole "what goes here"`: a task of whatever type fits there, for code you can only write
  after seeing data. When `main` reaches it, the run stops and shows the values in scope; the
  code you send for it goes into that place, is typechecked there, and the program runs again
  without repeating the calls that already ran. Give every hole its own description.
- `spawn mounts task`: runs `task` as a child that sees the changes so far, cannot see what
  `mounts` hide (`Hidden path`, `Readonly path`, `Scratch path`), and keeps its own changes
  apart. `merge child` takes them into the parent, or fails with the changes that clash if a
  file moved meanwhile. A child never merged leaves nothing.
- `succeed`, `fail`, `andThen`, `map`, `map2`, `mapErr`, `onError`, `batch`, `fromResult` build
  tasks; they do nothing by themselves.

## Errors

`IoErr` is `NotFound path`, `Denied path` (the path is refused, hidden or read-only, or the
person's rules refused the call), or `Conflict reason` (`edit` did not find its text once, or
a file changed on disk since it was staged).

## What a person has to allow

- Files that other programs run or obey are written only with a person's yes: git hooks and
  attributes (`.husky/`, `.pre-commit-config.yaml`, `.gitattributes`, `.gitmodules`), CI
  workflows (`.github/workflows/`, `.gitlab-ci.yml` and the like), the `scripts` of
  `package.json` and npm or yarn settings, editor containers (`.devcontainer/`, `.idea/`), and
  instructions for agents (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules` and the like).
  The rest of the changes are still written, and the reply names the files that were not.
- teagent labels every value with where its content came from. A `Fetch` request, or a shell
  command when hosts are granted, that carries content of the project, or that was chosen
  because of it, needs a person's yes; so does everything after this session has read the
  project, since the code that follows was written after seeing it. Without a yes, `Fetch`
  fails with `Declined` and a command gets code 126. Reach the network before reading the
  project when the task allows it.
- `Fetch.post` cannot be taken back, so it always needs a yes.
