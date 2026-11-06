# Sandboxing Rune: how far the handler goes, and where the OS must take over

Research note, 2026-11-06. It answers one question: every Rune effect already passes through one interpreter, so how close can Rune get to container-grade isolation *inside the handler*, and where does it still need real OS mechanisms?

## TL;DR

- **Do not try to "implement Linux".** gVisor does exactly that: it is a user-space kernel that reimplements a *subset* of the Linux syscall ABI. It is Linux-only and needs a large engineering team. Rune doesn't need it because its syscall table is `Agent.elm`, which has five tools today. **The handler is Rune's Sentry**, and it is tiny because the ABI is tiny.
- **Do in the handler:** a copy-on-write overlay over the repo, transactional commit, O(1) forks, record/replay, per-effect policy and budgets. All of this is ordinary OCaml over a persistent map. None of it needs the OS, and none of it is available to an agent running in Docker.
- **Where the OS is needed:** `shell` runs real binaries (dune, cargo, node), which need a real filesystem and real processes. There the job is *containment plus harvesting*. Run the process under Seatbelt (macOS) or bubblewrap/Landlock (Linux), with writes redirected into a scratch layer. Then turn whatever it wrote back into `Write` effects in the overlay. That moves `shell` out of the "irreversible" class for its filesystem side effects. Network stays off by default; the only route out is an egress proxy.
- **Docker is a wall without windows.** It limits blast radius but shows nothing, can only roll back the whole container, and on macOS it means a Linux VM with a different toolchain. Rune's design gives the windows. A VM backend (Apple `container`, Firecracker) can still be added later as an optional heavy wall behind the same `shell` effect.

---

## 1. Landscape

### 1.1 What each approach isolates

| Approach | Mechanism | Isolates | Startup | Host OS | Fit for a local dev agent |
| --- | --- | --- | --- | --- | --- |
| **gVisor** | User-space kernel (Sentry) intercepts syscalls; the Gofer proxies files | Kernel attack surface, FS, net | ~container | Linux 5.6+ only | Heavy; Linux servers only |
| **User-Mode Linux** | Linux kernel running as a Linux process | Weakly (per its own docs) | seconds | Linux | No: kernel test harness |
| **Firecracker** | KVM microVM plus jailer | Everything (hardware virtualisation) | ≤125 ms to `/sbin/init` | Linux + KVM | Good on Linux CI or servers; nothing for macOS |
| **Apple `container`** | One lightweight Linux VM per container (Virtualization.framework) | Everything | "sub-second" | macOS 26, Apple silicon | Strong wall on macOS, but a Linux toolchain |
| **namespaces + overlayfs + seccomp** | Kernel primitives | Choose per resource | ms | Linux | The building blocks |
| **Landlock** | Unprivileged LSM: FS, TCP, scopes | FS paths, TCP ports, signals, abstract sockets | ~0 | Linux 5.13+ | Good; needs no root |
| **bubblewrap / nsjail** | Namespaces, plus seccomp and cgroups in nsjail | FS view, pid, net, ipc | ms | Linux | bwrap is the de facto choice for agents |
| **Seatbelt (`sandbox-exec`)** | macOS kernel sandbox, SBPL profiles | FS, network, mach, process | ~5 ms (measured below) | macOS | Only lightweight option on macOS; "deprecated" |
| **WASI / wasmtime** | Capability-based Wasm runtime | Everything (no ambient authority) | µs–ms | Any | Only for code compiled to Wasm |
| **WebContainers, Pyodide** | Node or CPython on Wasm in a browser | Everything (browser sandbox) | — | Browser | No native binaries |
| **just-bash** | Bash interpreter in TS over a virtual FS | Everything, because nothing is real | µs | Any (Node) | Glue only; no real compilers |
| **Plan 9 / Fuchsia** | Per-process namespaces, capabilities | Authority is what you were handed | — | — | Design model, not a dependency |
| **Nix / Bazel** | Hermetic builds over the OS sandboxes above | Build inputs and outputs | ms | Linux, macOS | Proof that Seatbelt and namespaces suffice for builds |

### 1.2 User-space kernels and microVMs

**gVisor** calls itself "an application kernel that implements a Linux-like interface" ([docs](https://gvisor.dev/docs/)). The Sentry handles application syscalls without passing them to the host kernel. Since mid-2023 the default platform has been `systrap`, which replaced the deprecated `ptrace` platform; KVM "runs best on bare-metal" ([platforms](https://gvisor.dev/docs/architecture_guide/platforms/)). File access goes through the Gofer. With *directfs*, the default since 2023, the Gofer hands file descriptors to the Sentry, which made `stat` "more than 2x faster" ([blog](https://gvisor.dev/blog/2023/06/27/directfs/)). gVisor still "only implements a subset of the Linux syscall ABI": io_uring is off by default, iptables support is partial, and cgroups inside the sandbox don't enforce limits ([compatibility](https://gvisor.dev/docs/user_guide/compatibility/)). Overhead is concentrated in syscall-bound work ([performance](https://gvisor.dev/docs/architecture_guide/performance/)), which describes compilers and test runners. It requires Linux 5.6+ ([install](https://gvisor.dev/docs/user_guide/install/)). gVisor is the honest answer to "implement basically all of Linux safely": it can be done, it is Google-scale work, and it still isn't complete.

**User-Mode Linux** is "just a process running on Linux". Its own docs warn that "the level of isolation between UML and the host is relatively weak" ([kernel docs](https://www.kernel.org/doc/html/latest/virt/uml/user_mode_linux_howto_v2.html)). Its main job today is running KUnit tests.

**Firecracker** has a published specification: ≤125 ms from `InstanceStart` to guest `/sbin/init`, ≤5 MiB VMM overhead, and VMM startup within 8 CPU-ms ([SPECIFICATION.md](https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md)). It needs KVM. The jailer adds chroot, namespaces, cgroups and privilege drop ([jailer.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)). Snapshots exist, but diff snapshots are still in developer preview, and restoring the same snapshot twice clones secrets ([snapshot-support.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)). On macOS it only runs inside a Linux VM.

### 1.3 Linux primitives and the tools built on them

- **Namespaces** ([namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)): mount, pid and user since 3.8; cgroup since 4.6; time since 5.6. Unprivileged user namespaces give the creator a full capability set *inside* the namespace, and overlayfs can be mounted there since 5.11 ([user_namespaces(7)](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)). **Caveat:** Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor by default ([release notes](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890)). bwrap therefore needs a profile or a sysctl change on stock Ubuntu.
- **overlayfs** ([docs](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html)): read-only lower layers and a writable upper layer. Modifying a file copies it up; deleting it leaves a *whiteout*. This is exactly the shape Rune's handler overlay has, implemented in the kernel.
- **seccomp-bpf** filters on the syscall number and raw arguments, and cannot dereference pointers ([kernel docs](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)), so it cannot express "only files under X". Its user-notification supervisor mode "can not be used to implement a security policy" because of TOCTOU races ([seccomp_unotify(2)](https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html)). That rules out "intercept every `openat` from the handler" as a design.
- **Landlock** ([kernel docs](https://www.kernel.org/doc/html/latest/userspace-api/landlock.html)) is unprivileged and stackable. ABIs by kernel version ([crate docs](https://docs.rs/landlock/latest/landlock/enum.ABI.html)):

  | ABI | Kernel | Adds |
  | --- | --- | --- |
  | v1 | 5.13 | Filesystem rules |
  | v2 | 5.19 | Rename and link across directories |
  | v3 | 6.2 | Truncate |
  | v4 | 6.7 | TCP bind and connect |
  | v5 | 6.10 | ioctl on devices |
  | v6 | 6.12 | Scoping for signals and abstract unix sockets |
  | v7 | 6.15 | Audit logging |
  | v8 | 7.0 | Enforce on all threads |
  | v9 | 7.1 | Pathname unix sockets |

  The current docs list v10–v12 (UDP, capability and namespace rules) without kernel versions.
- **bubblewrap** ([repo](https://github.com/containers/bubblewrap)) is "not a complete, ready-made sandbox"; it is a toolkit used by Flatpak. Setuid mode was removed in v0.12.0 (2026-08), so it now depends on user namespaces. `--overlay`, `--tmp-overlay` and `--ro-overlay` arrived in v0.11.0 (2024-10).
- **nsjail** ([repo](https://github.com/google/nsjail)) layers namespaces, cgroups, rlimits and Kafel seccomp policies. Google's kCTF uses it.

### 1.4 macOS

- **Seatbelt / `sandbox-exec`.** The man page says "DEPRECATED" and points to App Sandbox. An Apple DTS engineer says the profile language "has never been documented for third-party use… not considered API" ([forum](https://developer.apple.com/forums/thread/777509)). An open issue asks Apple to clarify the timeline ([containerization#737](https://github.com/apple/containerization/issues/737)). Even so, it ships and works on **macOS 26.5.1 on this machine**. Chromium ([README](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/README.md)), Bazel's darwin-sandbox ([docs](https://bazel.build/docs/sandboxing)), Nix (through the private `sandbox_init_with_parameters`, [source](https://github.com/NixOS/nix/blob/master/src/libstore/darwin/build/darwin-derivation-builder.cc)), Codex, Claude Code, Cursor and Gemini CLI all depend on it. The risk is real but shared by the whole industry.
  *Local measurement:* a `(deny default)` profile that allows reads everywhere and writes only to one directory added about 5.6 ms per exec (10 runs: 79 ms vs 23 ms). It blocked writes outside the workspace with `Operation not permitted` and blocked DNS and network (`curl` exit 6), while `curl` worked unsandboxed.
- **Apple Containerization / `container`** ([containerization](https://github.com/apple/containerization), [container](https://github.com/apple/container)) runs "each Linux container inside of its own lightweight virtual machine", claims sub-second start, and needs Apple silicon and macOS 26. The `container` CLI reached 1.0 on 2026-06-09; the current release is 1.6.1 (2026-10-23) ([releases](https://github.com/apple/container/releases)). It gives a stronger boundary than Docker Desktop's single shared VM. It is still Linux inside: a macOS opam switch and Homebrew toolchain are not available there.
- **Virtualization.framework** supports Linux guests (macOS 11), VirtioFS (12) and Rosetta for Linux (13) ([docs](https://developer.apple.com/documentation/virtualization/vzlinuxbootloader)). Lima's `vz` driver has been its default since 1.0 ([Lima](https://lima-vm.io/docs/config/vmtype/vz/)).

### 1.5 Wasm and in-process environments

- **WASI** is capability-based: a guest sees only the directories it was given (preopens) and has no processes. 0.2 (January 2024) introduced the component model. **0.3 was released on 2026-06-11** and adds native async ([roadmap](https://wasi.dev/roadmap)). **wasmtime** offers deterministic *fuel*, non-deterministic but cheaper *epoch interruption*, `ResourceLimiter` for memory, and sockets denied by default ([Config](https://docs.wasmtime.dev/api/wasmtime/struct.Config.html), [WasiCtxBuilder](https://docs.wasmtime.dev/api/wasmtime_wasi/struct.WasiCtxBuilder.html)).
- **WebContainers** runs Node toolchains in a browser tab. It "can only execute languages… natively supported on the Web", and native addons are disabled ([troubleshooting](https://webcontainers.io/guides/troubleshooting)). **Pyodide** cannot use `threading`, `multiprocessing` or `socket` ([constraints](https://pyodide.org/en/stable/usage/wasm-constraints.html)). **container2wasm**, **v86** and **WebVM/CheerpX** emulate whole x86 or RISC-V machines in Wasm: full fidelity at emulator speed.
- **Vercel just-bash** ([repo](https://github.com/vercel-labs/just-bash), v3.6.0) is a bash interpreter in TypeScript. It offers `InMemoryFs`, `OverlayFs` (reads a real directory, keeps writes in memory) and `ReadWriteFs`. It ships ~reimplemented cat/grep/sed/awk/jq/rg/sqlite3. `curl` doesn't exist until URL prefixes are allow-listed. Execution limits cover call depth, command count, time and output size. Its README says execution "happens without VM isolation" and recommends a real sandbox for real binaries. Overlay-FS-plus-interpreter is the closest existing analogue to what Rune's handler could be.

### 1.6 Capability operating systems as the design model

- **Plan 9** gives each process its own namespace: `bind`, `mount`, and `rfork(RFNAMEG)` to copy it. `RFNOMNT` forbids further mounts, which makes a sandbox out of one flag ([Pike et al., "The Use of Name Spaces in Plan 9"](https://9p.io/sys/doc/names.html), [rfork(2)](https://9p.io/magic/man2html/2/fork)).
- **Fuchsia** has "no global file system". "Every component receives its own namespace", built from handles that its parent routes to it ([namespaces](https://fuchsia.dev/fuchsia-src/concepts/process/namespaces), [security principles](https://fuchsia.dev/fuchsia-src/concepts/principles/secure)).

Rune already sits in this lineage. A Dartea program has *no ambient authority*: it can only build `Task` values, and what a tool means is decided by whichever handler interprets it. Wrapping a handler is `bind`. Giving a subagent a forked overlay is `rfork(RFNAMEG)`. A policy that denies new tools is `RFNOMNT`.

### 1.7 Hermetic builds

**Nix** sandboxes builds by default on Linux. On macOS the default is off, and when enabled it uses Seatbelt profiles ([nix.conf](https://nix.dev/manual/nix/latest/command-ref/conf-file.html)). **Bazel** has `linux-sandbox` (user, mount, PID, network and IPC namespaces), `darwin-sandbox` (sandbox-exec) and a portable symlink-tree `processwrapper-sandbox`. It notes that sandboxed processes "can still read all files" ([sandboxing](https://bazel.build/docs/sandboxing)). Two lessons for Rune: (a) Seatbelt plus namespaces are enough to run real compilers hermetically; (b) Bazel's per-action *declared inputs and outputs* are what make outputs harvestable.

### 1.8 How coding agents sandbox today

| Agent | macOS | Linux | Network | Notes |
| --- | --- | --- | --- | --- |
| **Codex CLI** | Seatbelt, generated profile, `/usr/bin/sandbox-exec` hard-coded ([seatbelt.rs](https://github.com/openai/codex/blob/main/codex-rs/sandboxing/src/seatbelt.rs)) | **bubblewrap + seccomp** since early 2026; Landlock is legacy ([README](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/README.md)) | Off in `workspace-write`; optional domain proxy | `.git`, `.codex`, `.agents` re-bound read-only. A past CVE let a model-chosen `cwd` become the writable root ([GHSA-w5fx-fh39-j5rw](https://github.com/openai/codex/security/advisories/GHSA-w5fx-fh39-j5rw)) |
| **Claude Code** | Seatbelt | bubblewrap + socat, optional seccomp | Unix-socket proxy outside the sandbox, host allowlist that starts empty ([docs](https://code.claude.com/docs/en/sandboxing)) | Built on [sandbox-runtime](https://github.com/anthropics/sandbox-runtime). Claims "reduces permission prompts by 84%" ([post](https://www.anthropic.com/engineering/claude-code-sandboxing)). Reads cover most of the machine unless `denyRead` is set |
| **Cursor** | Seatbelt, generated at runtime | Landlock + seccomp + overlay | — | "Sandboxed agents stop 40% less often" ([blog](https://cursor.com/blog/agent-sandboxing)) |
| **Gemini CLI** | Seatbelt profiles, `permissive-open` by default | Docker, Podman or gVisor | Profile-dependent | Opt-in ([docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/sandbox.md)) |
| **OpenHands** | Docker | Docker | — | The process runtime is "unsafe, but fast" |
| **pi** | none for shell | none for shell | — | QuickJS-WASM only for codemode glue |

**The 2026 escape pattern.** The sandboxes themselves held. What escaped was the agent *writing a file that an unsandboxed host component later trusted*: `.git/config` or hooks through fsmonitor, `.claude/settings.json` hooks, symlinks followed by the unsandboxed app, venv interpreters, `.vscode` tasks, or a reachable Docker socket. See Pillar's ["Week of Sandbox Escapes"](https://www.pillar.security/blog/the-week-of-sandbox-escapes) ("sandboxing the agent process does not sandbox the host") and Claude Code advisories CVE-2026-25725, CVE-2026-39861 and CVE-2026-55607 ([advisories](https://github.com/anthropics/claude-code/security/advisories)). Separately, allow-listed domains are an exfiltration channel: Anthropic's docs admit domain fronting is possible because the proxy does not inspect TLS. DNS has been used too ([CVE-2025-55284](https://embracethered.com/blog/posts/2025/claude-code-exfiltration-via-dns-requests)). **This matters most for Rune's design:** the dangerous output of a sandboxed process is *the files it leaves behind*, and Rune can turn those into data before anything trusts them (§2.5).

### 1.9 Does the plan's critique of pi hold?

pi's codemode ([README](https://github.com/earendil-works/pi/blob/main/packages/codemode/README.md)) runs model-written JS in QuickJS compiled to Wasm (`quickjs-wasi`), in a worker. "The only capability is calling injected tools." It has a `memoryLimitBytes` heap cap and an interrupt handler.

| Plan's claim | Verdict |
| --- | --- |
| "`eval` and `Function` work", implying the cage leaks | **Overstated.** pi documents that they "only produce more code inside the same VM". Isolation holds. What `eval` breaks is *static visibility*: you cannot enumerate effects before running. That is the real and correct argument for Rune. |
| "interrupt handler, which builtins on Bun don't poll" | **Holds.** pi's own README says a long built-in on Bun "may not poll QuickJS's interrupt handler… does not guarantee computation has stopped". |
| No determinism (`Date`, `Math.random`, promise order) | Plausible. pi removes timers, but I did not verify whether `Date` and `Math.random` exist in its VM. |
| pi #10897 as a tool-argument problem | Accurate as cited: it is JSON prefix-salvage of streaming tool arguments in `pi-ai`, not a sandbox leak. |
| "The cage leaks" in general | **Misdirected.** pi's real gap is that `tools.bash` is unsandboxed *by design* ([SECURITY.md](https://github.com/earendil-works/pi/blob/main/SECURITY.md)). **Rune has exactly the same gap through `shell`.** "The language is the sandbox" is true for the program and false for `shell`. |

The plan should say this outright: language-level isolation and an OS sandbox for `shell` are complementary. The plan's "What we don't do: a sandbox for the model's code" is correct only because the model's code here means Dartea, not the processes it spawns.

---

## 2. What Rune can do purely in the handler

The handler receives a tree of `Value.task` whose continuations are interpreted closures (`{home; parameters; scope; body : Ir.Ast.term}`), with no OCaml functions in them. That one fact makes everything below cheap. A suspended program is a *value*: it can be logged, diffed, forked and serialised.

### 2.1 Overlay VFS (copy-on-write over the repo)

An `overlay` handler wraps `run`:

```
overlay = { base : root_path; delta : entry Path_map.t }       (* persistent map *)
entry   = Written of { content; base_hash : hash option } | Deleted of { base_hash : hash }
```

- `Read p`: take `delta[p]` if present, otherwise read from base and remember its hash.
- `Write` and `Edit`: update `delta` only. `Edit` runs exact-match against the *merged* view.
- `Grep`: run ripgrep on base, drop hits in paths present in `delta`, and grep the delta contents in memory. A cheaper alternative is to materialise only the delta into a scratch dir and grep both.
- **Fork is O(1)**, because OCaml's `Map` is persistent. A fork is just keeping the old value. Spawning a subagent, running speculative `batch` branches, or making a "what if" plan all reduce to holding two `overlay` values.

This is the handler-level equivalent of overlayfs or just-bash's `OverlayFs`, with no kernel and no setup on either OS.

### 2.2 Transactions, diff preview, rollback

- **Diff preview**: `delta` *is* the diff. Show it with a unified diff against the base per path.
- **Rollback** means dropping `delta`.
- **All-or-nothing commit**: POSIX has no multi-file atomic rename, so commit is *journaled*.
  1. Check that every `base_hash` still matches disk. A mismatch is a typed `Conflict path` returned to the program or the user, the same mechanism as the plan's hash-anchored edits.
  2. Write a commit record (paths with pre-hashes and post-hashes) to the session log.
  3. Apply each file as temp file + `rename`.
  4. Mark the record done.

  After a crash, each file is at its pre-hash or its post-hash, so recovery is roll-forward. This is what makes the stage-3 `kill -9` test trivial: nothing touches disk before commit, and commit itself is idempotent.
- **Snapshots** are `(task, overlay, heap)` triples, all plain values.

### 2.3 Deterministic record/replay

The language is pure, so a run is fully determined by the program plus the sequence of effect results. Record `{seq; tool; result}`, and the replay handler answers from the log. Two refinements:

- Log the overlay delta as well. Resume then rebuilds the staged state without touching disk.
- With a contained shell (§2.5), a `shell` result *includes* its harvested writes. Replaying a shell means replaying its stdout *and* its file effects, without re-running it. The plan's "Irreversible ⇒ replay stops and asks" rule can then be narrowed to shells that had network access or touched paths outside the workspace.

### 2.4 Policy and budgets

`policy : tool -> Allow | Ask | Deny` acts on typed effects, so the policy knows intent: `Edit lib/foo.ml`, not `openat(…, O_WRONLY)`. Budgets are counters in the same wrapper: interpreter steps (already exist), effect count, bytes written to the overlay, total shell wall time, output bytes. They compose as handler wrappers, `budget (policy (overlay run))`.

### 2.5 A typed replacement for most of the shell

What agents use bash for, and how each use maps to Rune:

| Shell use | Rune answer |
| --- | --- |
| Glue: pipes, loops, `xargs`, `sed`, `awk`, `head` | **Dartea itself.** The program is the glue. This is why just-bash's 70-command reimplementation is mostly unnecessary for Rune: just-bash exists because bash is *their* glue language, and Dartea is ours. |
| Listing and search: `ls`, `find`, `rg`, `wc` | New pure-read effects `list : Glob -> Task e (List Path)` and `stat`, plus `grep`. They run in-process over the overlay. |
| VCS: `git status`, `diff`, `log`, `show` | Typed read effects over the overlay. `git status` and `git diff` *against the overlay* are computable without git touching disk. Mutations (`commit`, `checkout`) are separate effects with their own policy class, and `push` is network. |
| HTTP | `http : Request -> Task HttpErr Response` with a domain policy, enforced in the handler where the URL is a typed value. No proxy is needed for this path. |
| Build, test, run real programs | **Needs a real OS process.** `exec : { argv : List String, cwd : Path } -> Task e Output`, with argv instead of a string so there is no shell parsing and the policy matches on `argv[0]` exactly. `build` and `test` are thin wrappers that parse output into typed diagnostics later. |

How far can an in-process busybox go? Far for *glue*, nowhere for *compilers*. `dune build` needs to stat and read thousands of files, spawn `ocamlopt`, and write `_build/`. `cargo` needs rustc and a linker. `node` needs a V8 with a real fd table. Emulating that is the gVisor or WebContainers route, which is either Linux-only kernel work or limited to JS/Wasm. Only one effect needs the OS, `exec`, and the task is to sandbox that one well.

### 2.6 Harvesting: making `exec` reversible

This is the main idea.

1. Before `exec`, *materialise* the overlay into a scratch layer the process sees as the workspace:
   - **Linux**: `bwrap --overlay-src <repo> --overlay <upper> <work> <repo>`. Delta files are pre-seeded into `upper`, and deletions become whiteouts.
   - **macOS**: there is no overlayfs. Keep a session-long *shadow workspace* made with APFS `clonefile` (`cp -c`). Measured here: 2,093 files / 226 MB cloned in 0.32 s against 0.94 s for a real copy, about 150 µs per file. Sync deltas into the shadow incrementally. Run Seatbelt with writes allowed only in the shadow and a temp dir.
2. Run the process with network denied and writes confined to the scratch layer.
3. **Harvest**:
   - Linux: walk `upper/`, where whiteouts mean deletes.
   - macOS: compare the shadow against its last-synced manifest by `(mtime, size)`, then hash.

   Each change becomes a `Write` or `Deleted` entry in the overlay, *attributed to that exec*. Build output directories (`_build`, `target`, `node_modules`) are declared caches: kept in the scratch layer, never harvested into the repo delta.
4. Harvested writes go through **the same policy as model writes**. A process that writes `.git/hooks/*`, `.git/config`, `.claude/`, `AGENTS.md`, shell rc files or `.vscode/tasks.json` produces a typed effect the policy can `Deny` or `Ask` about, *before anything on the host trusts it*. This handles the 2026 escape pattern structurally rather than through a list of read-only bind mounts that each agent re-discovers.

Result: a contained `exec` is reversible with respect to the filesystem, because its effects are data in the overlay. What stays irreversible is anything that crossed the boundary: network, IPC to host daemons, writes to declared external paths.

---

## 3. Where OS mechanisms are unavoidable

Only `exec`, but it must be done properly.

| Option | Startup | Fidelity (host toolchain?) | Setup friction | Escape risk | Verdict |
| --- | --- | --- | --- | --- | --- |
| **Seatbelt** (macOS) | ~5 ms | Full: native opam, Homebrew, Xcode | None, ships with the OS | Kernel-enforced; SBPL undocumented and "deprecated"; mach services are a big surface | **macOS default** |
| **Apple `container`** (macOS 26) | sub-second (not measured) | Linux toolchain, different from the host | Install, image, macOS 26 only | VM boundary, strongest | Opt-in "untrusted" mode |
| Docker Desktop / Lima / OrbStack | seconds | Linux toolchain | Daemon, VM | Shared VM; host bind mounts | Not needed |
| **bubblewrap + seccomp** (Linux) | ms | Full | `bwrap` package; Ubuntu 24.04 userns restriction | Mature, the Codex and Claude Code choice | **Linux default** |
| Landlock (Linux, in-process) | ~0 | Full | None on 5.13+, needs ≥6.7 for TCP | Good for FS and TCP; no FS *view* (cannot redirect writes) | Second layer inside bwrap, or fallback without userns |
| gVisor `runsc` | ~container | Mostly Linux; syscall gaps | Root to install | Strong | Servers or CI |
| Firecracker | ~125 ms + rootfs | Linux guest | KVM, images | Strongest | Server or multi-tenant only |

**macOS-first plan.** Generate an SBPL profile from the policy:

- `(deny default)`.
- Allow reads of the workspace shadow, the toolchain roots (`/usr`, `/opt/homebrew`, `~/.opam`, Xcode) and `/System`.
- **Deny reads** of `~/.ssh`, `~/.aws`, keychains and browser profiles. Claude Code allows these reads by default, so this is a place to be stricter.
- Allow writes only to the shadow and a per-exec `TMPDIR`.
- Deny `network*` except `(remote ip "localhost:PORT")` for the egress proxy, the pattern Codex uses.

Invoke `/usr/bin/sandbox-exec` by absolute path, as Codex does. Keep the profile small and tested, because Apple can change SBPL without notice. The risk is shared with Chrome, Bazel and Nix, and Apple's own replacement for non-App-Store use doesn't exist yet.

**Linux.** Use `bwrap`:

- `--ro-bind / /`, then the overlay for the workspace, then `--tmpfs` for `/tmp`.
- `--unshare-user --unshare-pid --unshare-net --new-session --die-with-parent`.
- Inside, apply Landlock (≥6.7) for defence in depth and a seccomp filter that denies io_uring, `ptrace` and `TIOCSTI`, the same set Codex uses.
- On hosts without user namespaces, fall back to Landlock alone. Without an FS view, writes cannot be redirected, so writable roots are restricted to a clone directory instead.

**Network egress.** The default is no network for `exec`. When a policy allows it (`opam install`, `npm ci`), start a local HTTP CONNECT proxy and let the sandbox reach only that port: through Seatbelt on macOS, through a socket bridged into the netns on Linux, as Claude Code does with socat. The proxy enforces a host allowlist and logs each connection *as an effect* in the session log. State the limits plainly: no TLS inspection, so domain fronting through allowed CDNs and exfiltration to allowed hosts remain possible. A shell with network is still classified **Irreversible**.

**Code placement under Rune's invariants:**

- The sandbox wrappers (profile generation, bwrap argv, harvest walk) are IO and live in `lib/tools`.
- The overlay, policy, budget and harvest-to-effects logic live in `lib/effect` as handlers.
- Landlock or seccomp in-process would need small C stubs. Shelling out to `bwrap`, whose `--seccomp` flag takes a precompiled BPF fd, avoids that at first.

---

## 4. Value for Rune, by plan stage

### What exists *only* because effects are a data tree

1. **Exact speculative planning.** Today the plan handler stubs `Write` with `V_unit` and must cut the plan at the first read-after-write (1.2). With an overlay, the plan handler is just `run` over a *forked overlay*. Reads after writes see the staged content, so speculation is exact and the plan's main risk ("speculating a read after a write returns stale content") disappears. With a contained `exec`, planning can go *past* `dune test`. The user approves a plan that already shows the test result, and approval is just `commit` of that overlay, with no second run. This is the strongest argument for the whole design.
2. **Policy on intent, not syscalls.** Seatbelt sees `file-write-data /path`; Rune sees `Edit {path; old; new}` produced by line N of the program. Harvested process writes enter the same vocabulary.
3. **Forkable computations.** `(task, overlay)` is a value. That gives O(1) branches for subagents, `batch [spawn …]` each with its own overlay, and an explicit typed `merge` effect for conflicts. Docker gives one filesystem per container and a `git worktree` per agent at best.
4. **Replay by structural equality** of typed effects, including shell outputs and their file effects.
5. **One log for conversation, files and shell side effects**, which the plan already identifies as the agent-afk #4271 wish.

### Mapped onto the plan

| Plan item | Mechanism |
| --- | --- |
| Stage 1: visible effects, permissions | Policy wrapper; overlay makes `Write`/`Edit` *pending by construction*; the gate ("no file touched before confirmation") holds structurally because only `commit` writes |
| Stage 1: `rm -fr` blocked by allowlist | `exec` takes argv, so the allowlist is on `argv[0]`. Even an allowed command can only damage the shadow |
| Stage 3: log + resume | Log effects + overlay deltas + journaled commit; `kill -9` mid-batch loses nothing because nothing hit disk |
| Plan mode | `run` over a forked overlay, then discard or commit |
| Diff preview | `delta` rendered |
| All-or-nothing edits | Journaled commit with base-hash conflict check |
| Replay | Log, including harvested exec effects |
| Multi-agent isolation | Overlay per agent (O(1) fork) + shadow dir per agent for exec; explicit merge |
| Network egress control | No network in the language; `http` checked in the handler; `exec` network only via proxy |
| Secrets out of transcript | Deny-read of credential paths in the OS profile; `Secret String` in the heap |

### Honest comparison with "just run the agent in Docker"

| | Agent inside Docker | Rune handler + OS sandbox for `exec` |
| --- | --- | --- |
| Blast radius of a malicious process | Container (shared kernel; on macOS, a shared VM) | Seatbelt/bwrap profile (shared kernel). Comparable on Linux; Docker's VM on macOS is stronger |
| Visibility before running | None | Full plan, typed, with speculative results |
| Rollback | Discard the whole container, or nothing | Per-effect, per-exec, per-branch |
| Damage to the mounted repo | Unrestricted | Staged; policy on every write, including process writes |
| Toolchain on macOS | Linux image; rebuild the switch; VirtioFS I/O costs | Host toolchain, native speed |
| Setup | Daemon, image, mounts | None on macOS; `bwrap` on Linux |
| Multi-agent | Container per agent | Value per agent |

Docker wins on kernel-escape resistance on macOS, where it has a VM boundary, and on running *anything* uniformly. The two are not exclusive: a `container`/Docker/Firecracker backend can sit behind the same `exec` effect for an "untrusted repo" mode, and the overlay and harvest logic still works through a bind-mounted scratch layer.

---

## 5. Recommended design and roadmap

### Layers (outside in)

```
Dartea program   — no ambient authority; Task tree only             (exists)
interp           — step budget                                       (exists)
lib/effect       — budget ∘ policy ∘ log ∘ overlay ∘ run            (handlers, pure logic)
lib/tools        — fs ops, journaled commit, exec via sandbox backend (only IO)
sandbox backend  — Seatbelt | bwrap(+Landlock,+seccomp) | none | vm (later)
egress proxy     — host allowlist, connection log                   (lib/tools)
```

### Roadmap

| Step | Content | Effort | Fits stage | Risks |
| --- | --- | --- | --- | --- |
| **S1. Overlay handler** | Persistent `Path_map` delta, read-your-writes, merged grep, diff render, journaled commit with base-hash conflicts | ~1 week | Stage 1 (makes 1.1/1.2 exact) | Grep over the merged view; binary files; large-file memory, so keep big content on disk by hash |
| **S2. `exec` with argv** | Change `shell : String` to argv; policy on `argv[0]`; add `list`/`stat`/`git`-read effects to shrink exec use | 2–3 days | Stage 1 | Model ergonomics: measure on bench |
| **S3. macOS Seatbelt backend + shadow + harvest** | Clone shadow once per session, incremental sync, generated SBPL, harvest by manifest, cache dirs excluded, harvested writes through policy | ~1–1.5 weeks | Stage 1 → 3 | Clone cost on huge repos (~150 µs/file measured, so ~15 s at 100k files; amortise per session); SBPL drift across macOS versions; toolchains needing mach services |
| **S4. Log + replay of overlay and exec** | Log deltas and harvested effects; resume reconstructs the overlay | ~3–4 days | Stage 3 | Log size, so store content by hash |
| **S5. Linux bwrap backend** | `--overlay` upper dir harvest, netns, seccomp profile, Landlock if available | ~1 week | After stage 3 | Ubuntu userns restriction; detect and fall back to Landlock-only + clone dir |
| **S6. Egress proxy** | Local CONNECT proxy, allowlist, connection log; `http` effect | ~1 week | Stage 4 (with MCP) | Domain fronting; DNS; document the limits |
| **S7. Plan past `exec`** | Plan handler runs contained exec speculatively when the policy class is `Contained`; approval = commit | ~3 days on top of S3 | Stage 1 v2 | Slow tests make planning slow, so add a time budget and a "stop here" fallback |
| **S8. Per-agent overlays + merge** | Fork overlay and shadow per `spawn`; typed 3-way merge effect | ~1 week | Planning and orchestration | Shadow clone per agent on macOS costs disk I/O; share base, clone lazily |
| **S9 (optional). VM backend** | Apple `container` on macOS 26, Firecracker or gVisor on Linux servers | 1–2 weeks | Later | Toolchain mismatch; image maintenance |

### Effect classes this produces

These replace the current two-way split between reversible and irreversible:

- **Pure-read**: `read`, `grep`, `list`, `git status`/`diff`. Speculate freely.
- **Staged**: `write`, `edit`, and the harvested writes of a contained exec. Reversible until commit.
- **Contained**: `exec` with no network and writes harvested. Re-runnable in a fork; replay uses the log.
- **Irreversible**: `exec` with network, `http` with a non-GET method, `git push`, commit itself. Requires approval; replay stops and asks.

Encode these as a variant on the effect, not a boolean, so plan, replay and policy all match on the same constructor.

---

## Unverified or uncertain

- The release in which `sandbox-exec` was first marked deprecated (often said to be macOS 10.12 / 2016; the local man page is dated 2017).
- Apple `container` start latency on this machine; I did not measure it.
- Kernel versions for Landlock ABI v10–v12.
- Whether pi's QuickJS VM exposes `Date` and `Math.random`, which is relevant to the plan's determinism row.
- A primary-source statement that WASI has no process or exec API (inferred from the API surface).
- Amp's sandboxing (no primary source found); OpenCode container options (not searched).
- The Pillar "Week of Sandbox Escapes" day posts were read only through the index and the CSA summary.
- Harvest-by-manifest correctness on macOS when mtime granularity hides a same-second, same-size rewrite. Hash on doubt; untested.
