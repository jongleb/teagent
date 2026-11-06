# Rune — план

Nov 6, 2026 · @Mr

Rune — coding agent на OCaml: модель пишет программу на Dartea, харнесс её тайпчекает, планирует, показывает, выполняет и реплеит. Pi кладёт JS в клетку; у нас язык, из которого не выйти, и поэтому мы видим всё, что он собирается сделать.

## Тезис

Модель пишет не тул-коллы и не скрипт в песочнице, а программу на Dartea. Все эффекты в Dartea проходят через `Task` — других дверей в языке нет: ни FFI, ни `eval`, ни unsafe. Из этого одного факта следуют одновременно **изоляция** (программу нельзя обойти) и **видимость** (все эффекты можно собрать до запуска). Plan mode, пермишены, детерминированная компакция, replay — не фичи, а разные интерпретаторы одной и той же программы.

Pi строит клетку (QuickJS-WASM) вокруг языка, который изоляции не хочет, и клетка течёт. У нас изоляция — семантика языка, и именно поэтому мы видим всё.

| Что обеспечивает песочница | QuickJS в pi | Dartea |
| --- | --- | --- |
| нет fs / сети / процессов | убрали глобалы из рантайма | в языке нет способа выразить эффект, кроме `Task` |
| перехват всех эффектов | колбэки `tools.*`; `eval` и `Function` работают | `Task` — единственная дверь, в руках интерпретатора |
| детерминизм | нет (`Date`, `Math.random`, порядок промисов) | чистые функции → replay корректен, не «в основном» |
| остановить зацикленную программу | interrupt handler, который builtin'ы на Bun не опрашивают | счётчик шагов в `eval` |
| ограничить память | `memoryLimitBytes` у WASM-кучи | куча своя, в OCaml |
| ошибки | `throw` чего угодно | `Result` / `Task e`, exhaustiveness заставляет обработать |
| аргументы тулов | JSON, который salvage-ится (pi #10897) | типизированные значения после тайпчека |

В pi изоляция и видимость программы — две разные подсистемы (WASM и TS-декларации в промпте). У нас это одно свойство: опасная программа не блокируется — она не типизируется.

Свой LLM-клиент. Никаких внешних AI-зависимостей.

## Что берём из Dartea

Интерпретируем **IR**, не AST. `lib/ir` — ANF с decision trees (`T_switch` / `T_join` / `T_jump`), атомы, `B_kernel`. Maranget уже отработал до нас.

| Модуль Dartea | Роль в Rune |
| --- | --- |
| `Compiler.compile_modules` → `Ir.Of_optimized.convert` | `Lang.compile : string -> (Ir.Ast.declaration list, report) result` |
| `Data.Kernel` (`unary` / `binary` / `nullary`) | тулы и `Task`-комбинаторы — новая группа вариантов `Agent_*` / `Task_*` |
| `Reporting.Report` | Elm-style ошибки как есть — это промпт для следующего раунда модели |
| `lib/prelude` (Elm-source строки) | модуль `Agent`; `Platform` / `Cmd` / `Sub` / `Browser` выключены в режиме агента |

Правки в Dartea на этапе 0 — только `Data.Kernel` и прелюдия. Dartea остаётся отдельной репой; в Rune она git-сабмодулем в \`vendor/dartea\` с \`(vendored\_dirs vendor)\` — правки в Kernel и прелюдии видны сразу, одним \`dune build\`, без opam.

## Структура репы

```
rune/
  lib/lang/      прелюдия Agent; compile : string -> (Ir.Ast.declaration list, report) result
  lib/value/     runtime values + heap с хэндлами
  lib/interp/    eval по Ir.Ast, бюджет шагов
  lib/effect/    effect, 'a task, handlers: run | plan | replay
  lib/tools/     read / write / edit / grep / shell на Lwt
  lib/llm/       свой клиент: Anthropic Messages + OpenAI-compatible, ~300 строк
  lib/session/   JSONL-лог эффектов, resume
  lib/driver/    цикл
  bin/rune.ml    CLI (stdin/stdout, без TUI)
  bench/         20 задач, эталонные программы, счётчик раундов
```

`lib/llm` без внешних AI-зависимостей: `messages → text`, retry на 429/5xx, abort через `Lwt.cancel`. OpenAI-compatible покрывает OpenRouter, llama.cpp, vLLM, Ollama. Тул-коллов в протоколе нет — нам нужен только текст программы.

## Этап 0 — спайк (≈1 неделя)

Ворота: медиана раундов тайпчека ≤ 2 на задачу на 20 задачах bench. Это измерение — продукт этапа.

### 0.1 `lang` — прелюдия

```elm
module Agent exposing (..)
type Task e a                     -- opaque, kernel
type IoErr = NotFound String | Denied String | Conflict String
type alias Match = { path : String, line : Int, text : String }

read  : String -> Task IoErr String
write : String -> String -> Task IoErr ()
edit  : { path : String, old : String, new : String } -> Task IoErr ()
grep  : { pattern : String, glob : String } -> Task Never (List Match)
shell : String -> Task Never { out : String, code : Int }

succeed : a -> Task e a
fail    : e -> Task e a
andThen : (a -> Task e b) -> Task e a -> Task e b
map     : (a -> b) -> Task e a -> Task e b
mapErr  : (e -> f) -> Task e a -> Task f a
onError : (e -> Task f a) -> Task e a -> Task f a
batch   : List (Task e a) -> Task e (List a)
```

Контракт программы: модуль `Main` с `main : Task e a`. Все `Task`-функции и тулы — kernel-операции (`Agent_read`, `Task_and_then`, …). Do-нотацию пока не делаем: сначала смотрим, как модели пишут `|> andThen (\x -> ...)`. Проверка: 10 эталонных программ компилируются в IR.

### 0.2 `value` + `interp`

```ocaml
type value =
  | V_int of int | V_float of float | V_string of string | V_char of string
  | V_unit | V_list of value list | V_tuple of value list
  | V_record of (string * value) list
  | V_constr of Data.Name.t * value list
  | V_closure of { params : string list; env : env; body : Ir.Ast.term }
  | V_partial of { callee : Data.Name.t; args : value list; missing : int }
  | V_task of task                         (* реифицированный эффект *)
```

`eval : env -> Ir.Ast.term -> value` по атомам / биндам / термам; `T_join` — локальная таблица меток; `B_kernel` — диспатч в `Kernel_impl`. Бюджет: `steps : int ref`, проверка в `eval`, превышение → `Error Budget`. Проверка: эталонные программы дают ожидаемое `V_task`-дерево без выполнения эффектов.

### 0.3 `effect`

```ocaml
type effect =
  | Read of string | Write of string * string | Edit of { path; old_; new_ }
  | Grep of { pattern; glob } | Shell of string
  | Batch of effect list

type task =
  | Pure of value
  | Fail of value
  | Bind of effect * (value -> task)        (* продолжение — замыкание из interp *)

val interp : handler -> task -> (value, value) result Lwt.t
```

Handler на этапе 0 один — `run`.

### 0.4 `tools`

read / write / edit / grep / shell на Lwt, в cwd, без пермишенов (этап 1). `edit` — exact-match replace, ошибка если `old` не найден или не уникален.

### 0.5 `llm` + `driver`

System prompt = прелюдия как есть + 3 эталонные программы + правила («один модуль Main», «обработай все ошибки»).

```
prompt → llm → text → Lang.compile
  Error report → history += report → llm   (≤ K=4 раунда)
  Ok ir → interp → task → Effect.interp run → результат → history
```

Результат пока в контекст текстом с усечением; хэндлы — этап 2.

### 0.6 `bench`

20 задач: 5 чтение/поиск, 5 edit одного файла, 5 multi-file рефакторинг, 5 shell + интерпретация вывода. Для каждой — эталонная программа руками. Скрипт гоняет задачи через driver, считает раунды тайпчека и успех. Прогоны: Sonnet, Opus, одна локальная (Qwen) — чтобы знать границу.

Если медиана 5+ — не идти дальше, чинить: формат ошибок (чаще всего виноват он), few-shot, лексику. Индентер — не святыня: если отступы валят модели, рассматриваем ML-синтаксис с явными `in`.

## Этап 1 — эффекты видимы (≈1 неделя)

Ворота: на 20 задачах ни одна не трогает файл до подтверждения; `rm -fr` не проходит не потому что матчится регексом, а потому что `rm` не в allowlist.

**1.1 `plan` handler.** Классификация эффектов в прелюдии: `Read | Grep` — safe, выполняются спекулятивно, чтобы раскрыть продолжение; `Write | Edit` — pending, в план, возвращают `V_unit` (законно по типам); `Shell` — irreversible, в план, стоп раскрытия. Выход: `effect list` + отметка «раскрыто до N / остановлено на irreversible».

```ocaml
let handle_plan = function
  | (Read _ | Grep _) as e -> plan := e :: !plan; Real.run e          (* спекуляция *)
  | (Write _ | Edit _) as e -> plan := e :: !plan; Lwt.return V_unit  (* заглушка *)
  | Shell _ as e -> plan := e :: !plan; raise Plan_stop
  | Batch es -> ...
```

**1.2 Детекция write→read.** Если после `Write p` / `Edit p` в плане встречается `Read p` или `Grep` с glob, покрывающим `p`, — план режется на фазу 1 (до записи) и «фаза 2 не раскрыта». Честно, без спекуляции на старом содержимом.

**1.3 Подтверждение.** CLI показывает план по типу эффекта с путями, `Shell` с ⚠. Ответы: `a` (всё), `s` (по шагам: run до первого pending, показать diff, спросить), `n`. После `a` — `run` той же `task`.

**1.4 Политика.** `policy : effect -> Allow | Ask | Deny` — над эффектом, не над строкой. `Shell`: allowlist по argv\[0\], остальное `Ask`. `Write` / `Edit`: пути внутри cwd, иначе `Deny`. `Deny` — ошибка в программу (`Denied path`), модель переписывает.

**1.5 Do-нотация** — только если метрика этапа 0 сказала, что нужна. `let x <- e` в `parser.mly` → `andThen`; правка в индентере.

## Этап 2 — типизированный контекст (≈1 неделя)

Ворота: токены на 20 задачах против pi 1.x на тех же задачах. Если не бьём их заявленные 40% на batch-задачах — неправильная политика превью.

**2.1 Heap.** Результаты эффектов — в `heap : (handle, value * Type.t) Hashtbl`. В контекст модели — `r3 : List Match (14)` + превью по политике типа: `String` → первые 40 строк, `List a` → первые 10 + count, запись → поля.

**2.2 `inspect`.** Прелюдия: `inspect : Handle a -> Task Never a`, `Agent.ref : String -> Handle a`. Модель ссылается на прошлые результаты без повторного чтения. Тоже эффект — проходит через план.

**2.3 Компакция.** GC: хэндлы, на которые история не ссылается последние N ходов, усекаются до типа и count. Ноль LLM-вызовов; префикс не переписывается, кэш провайдера живёт.

## Этап 3 — лог и resume (≈3–4 дня)

JSONL: `{seq, effect, result_handle, ts}`. `replay` handler: эффект с тем же `seq` и структурно равным `effect` → результат из лога; иначе выполняем и дописываем. `Shell` получает тег `Irreversible` → replay на нём останавливается и спрашивает, даже если в логе есть.

Тест: kill -9 посреди `batch [edit ×7]` → restart → 3 edit'а из лога, 4 выполнены, ни один не повторён. Детерминизм языка делает это корректным, не «в основном».

## Этапы 4–5 — MCP, TUI, расширения

**4. MCP (≈1 неделя).** JSON Schema тулов → Dartea-типы через jsonkit (обратный deriving). MCP-тул — kernel-эффект `Mcp of server * name * value`, в прелюдии сгенерированная сигнатура. Большая схема → запись с row-переменной `{ r | known fields }`, не `unknown` (как у pi при >16k символов). Политика: все MCP — `Ask` по умолчанию, per-server allow.

**5. TUI и расширения.** Notty / Nottui. Расширение = Dartea-модуль (чистая логика, тайпчекается) + OCaml-handler (эффекты). Не `.ts` в `~/.pi`.

## Практики и хотелки → интерпретатор

Сводка по Claude Code, Codex CLI, OpenCode, pi, oh-my-pi, Aider, Gemini CLI, Hermes, OpenHands (источники в конце). Правило: берём поведение, не код; каждая практика реализуется как свойство программы или ещё один handler, а не как отдельная подсистема. Если для практики нужна подсистема рядом с интерпретатором — это сигнал, что мы её неправильно поняли.

### Безопасность и обратимость

| Практика | Откуда | В Rune |
| --- | --- | --- |
| Checkpoints / rewind | Claude Code `/rewind`, OpenCode undo | Лог эффектов + replay до seq N. Claude Code трекает только свои edit'ы, не bash; у нас `Shell` — тоже эффект в логе, с тегом Irreversible |
| Сессия-дерево, ветвление | pi `/tree` | Лог — дерево; ветка = replay до узла + новая программа |
| Хотелка: единый rewind для разговора, файлов и bash-побочек | agent-afk #4271 | Естественно: все три — записи одного лога |
| Preview-then-accept для деструктивных операций | omp | Plan handler: это и есть preview |
| Многослойные пермишены (Starlark policy + hooks + LLM-reviewer + OS sandbox) | Codex | Один слой: `policy : effect -> Allow\|Ask\|Deny` над типизированным эффектом. OS sandbox как вторая сетка для `Shell` |
| Policy floor, который не перебивает auto-approve | Hermes | `Deny` в policy не отключается режимом; режим трогает только `Ask` |
| Syntax-aware пермишены для bash (tree-sitter) | OpenCode | Для `Shell` — парсим argv, allowlist по argv\[0\]; не регекс |
| Секреты вне транскрипта | Claude Code #32733 (178👍) | Значения в heap, в контекст только хэндл + тип; тип `Secret String` с превью-политикой «никогда» |
| Изоляция через fs-clone / overlayfs | omp (APFS, btrfs, overlayfs) | Ещё один handler: `Write`/`Edit` в overlay, commit по подтверждению. Стыкуется с идеей транзакционного overlayfs из terminal-клиента |

### Контекст и память

| Практика | Откуда | В Rune |
| --- | --- | --- |
| Auto-compaction по порогу | все (7 из 11 систем) | GC хэндлов по достижимости, детерминированно, без LLM; проверка после каждого эффекта, не после хода (закрывает pi #5512/#2871) |
| Anchored incremental summaries | OpenCode | Не нужны: саммари = тип + count, префикс не переписывается, кэш живёт |
| Прунинг tool-call деревьев | pi-context-prune, omp | То же GC; оригиналы в heap, доступны через `inspect` |
| Проектный файл инструкций | AGENTS.md (Claude Code #6235, 5189👍 — самая реактируемая хотелка) | Читаем `AGENTS.md`, `CLAUDE.md`; \~100 строк как карта (OpenAI: большой файл провалился) |
| Cross-session memory | Claude Code, omp Hindsight, Codex | Этап 5+. Память = типизированные значения в персистентном heap, не markdown |
| Детерминированный поиск (ripgrep, tree-sitter), не RAG | все 11 систем | `grep` как эффект; семантический индекс не делаем |
| Контроль памяти пользователем | SO 2026: 53.6% хотят контроль | Heap виден и редактируем (`/heap`, `/drop r3`) |

### Редактирование и интеллект кода

| Практика | Откуда | В Rune |
| --- | --- | --- |
| Exact-match `edit`, ошибка если не уникален | pi, Claude Code | Берём как есть — модели знают |
| Hash-anchored (hashline) edits — отбить stale patch | omp | `edit` принимает `expectHash : Maybe String`; план сравнивает с текущим файлом до подтверждения |
| 13 edit-форматов, fuzzy cascade | Aider | Нет: типизированный аргумент вместо угадывания формата из текста |
| LSP: diagnostics, rename, references | Claude Code, OpenCode, omp | Эффекты `Lsp.diagnostics : String -> Task Never (List Diag)`, `Lsp.rename`. Типизированный выход — модель фильтрует в программе, не в контексте |
| AST-aware rewrites (ast-grep) | omp | Эффект позже; для OCaml-проектов — ppxlib-бэкенд |
| Форматтер/линтер как guardrail, ошибки с инструкцией по исправлению | OpenAI harness post | Handler `after_write`: после каждого `Edit` гоним линтер, результат — значение, доступное программе |
| Debugger (DAP) | omp | Эффекты `Dap.*`, позже |

### Планирование и оркестрация

| Практика | Откуда | В Rune |
| --- | --- | --- |
| Read-only plan mode | Claude Code, Gemini #4666, pi-plan | Plan handler, не режим: каждая программа сначала планируется |
| Steerability: прервать, поправить, не спрашивать 7 раз | Microsoft study: 67% | Одно подтверждение на план; бюджет шагов = прерывание в любой точке без потери лога |
| Субагенты, fork контекста | все | `spawn : Prompt -> Task Never (Handle a)` — эффект. Субагент = вложенный driver с своим heap; результат — типизированный хэндл в родителе, не текст |
| Параллельные worktrees | Claude Code, Grok Build | `batch [spawn ...]` + overlay-handler на каждый; merge — явный эффект |
| Second-model oversight (Advisor) | omp, Amp oracle | Ещё один handler перед `run`: план как структура отдаётся дешёвой модели на ревью; ревьюит план, не транскрипт |
| Background tasks, job control | Claude Code, omp | `Shell` с `detach : Bool` → `Task Never Job`; `Job.wait`, `Job.kill` — эффекты |
| Durable execution, checkpoint каждого шага | pi-durable | Лог эффектов — уже он; неидемпотентность — тип, не флаг в рантайме |
| Verify-on-stop guards, test-driven loop | Hermes, OpenAI | Последний эффект программы имеет тип `Task e Verified`; программа без проверки не типизируется (опциональный режим) |

### Расширяемость и среда

| Практика | Откуда | В Rune |
| --- | --- | --- |
| Hooks на lifecycle | Claude Code (оригинатор), Codex, omp | Handler-композиция: hook = `handler -> handler`. Не события, а обёртки над эффектом |
| Mid-stream rules: abort и correct output | omp | Тайпчек до запуска делает это для всей программы, не для стрима |
| Skills (SKILL.md), deferred loading | 9 из 11 систем | Skill = Dartea-модуль с сигнатурами; подключается в прелюдию по запросу (`import`), тайпчекается. Supply-chain: чистый модуль не может навредить |
| MCP (8 из 11) | все | Этап 4, схемы → типы |
| Tool search / deferred tools | Claude Code (43 тула), pi | Прелюдия модульная; в system prompt — сигнатуры базовых, остальные по `import` |
| Role-based model routing (default/smol/plan/commit) | omp, Codex | Driver выбирает модель по фазе: написать программу / исправить тайп-ошибку / ревью плана |
| Headless `-p`, RPC/SDK, ACP | все | CLI первым; RPC = тот же driver по NDJSON; ACP позже |
| Локальные модели | OpenCode, omp, pi | OpenAI-compatible клиент + grammar-constrained decoding из Menhir-грамматики |
| Live token/cost | omp, Codex | Считаем по ответам провайдера; показываем и размер heap |
| Project-local knowledge, docs как system of record | OpenAI | Читаем `docs/`, `ARCHITECTURE.md` по указателям из AGENTS.md; сами так ведём репу Rune |

### Чего не делаем

Семантический индекс/RAG (никто из 11 не делает, и не зря). TS/JS-расширения. LLM-компакцию. Regex-пермишены. Песочницу для кода модели (язык и есть песочница). Десктоп/web-поверхности до того, как ядро пройдёт ворота этапа 2.

### Источники

- [Harness Engineering: Source-Code Study of Eleven Systems (arXiv 2609.00006)](https://arxiv.org/html/2609.00006v1)
- [State of CLI Coding Agents, Mid-2026](https://blog.arcbjorn.com/state-of-cli-coding-agents-2026)
- [Most sought-after coding-agent features (henchman-ai #10)](https://github.com/mlg151/henchman-ai/issues/10)
- [Harness engineering: leveraging Codex (OpenAI)](https://openai.com/index/harness-engineering/)
- [Enabling Claude Code to work more autonomously (Anthropic)](https://www.anthropic.com/news/enabling-claude-code-to-work-more-autonomously)
- [Oh My Pi vs Pi: what the fork adds](https://standardcompute.com/best-ai-agent/oh-my-pi-vs-pi)
- [Unified /rewind for conversation, files, bash (agent-afk #4271)](https://github.com/griffinwork40/agent-afk/issues/4271)
- [What is Codemode (Ronacher)](https://lucumr.pocoo.org/2026/10/6/codemode/)
- [pi issues: #5512, #2871, #10897](https://github.com/earendil-works/pi/issues)

## Риски

| Риск | Проверка | План Б |
| --- | --- | --- |
| Модели плохо пишут Elm-синтаксис (мало в обучающих данных, отступы) | метрика этапа 0 | ML-синтаксис с явными `in`; grammar-constrained decoding из Menhir-грамматики |
| Спекуляция read после write даёт старое содержимое | детекция 1.2 | двухфазный план |
| Мелкие модели галлюцинируют вызовы | bench на Qwen | целевая аудитория — frontier; локальные через constrained decoding |
| Dartea-прелюдия тянет Elm-рантайм (`Scheduler`, `Platform`) | режим `--agent` в прелюдии | форк прелюдии в Rune, Dartea — только компилятор |
| Тайпчек не ловит семантически неверную, но типизированную программу | — | вторая сетка: план показывается человеку до выполнения |

## День 1

1. `rune/` с dune-project; \`git submodule add\` dartea в \`vendor/\`, корневой \`dune\` с \`(vendored\_dirs vendor)\`.
2. `Data.Kernel`: группа `Agent_*` / `Task_*`, 12 вариантов.
3. `Agent.elm` прелюдия, подключить в `Prelude`, выключить `Platform`.
4. Три эталонные программы, добиться `compile → IR` на них. Здесь уйдёт больше всего — вылезет всё, что в прелюдии завязано на Elm-рантайм.
5. `value.ml` + `interp.ml` скелет: атомы, `T_let`, `T_return`, `B_kernel`-диспатч на `Task_succeed` / `Task_and_then`.

Эталонная программа №1 — «переименуй Foo.bar в Foo.baz, прогони тесты»:

```elm
module Main exposing (main)
import Agent exposing (..)

type Err = EditFailed IoErr

main : Task Err { out : String, code : Int }
main =
  grep { pattern = "Foo\\.bar", glob = "**/*.ml" }
    |> andThen (\matches ->
         matches
           |> List.map .path
           |> List.unique
           |> List.map (\p -> edit { path = p, old = "Foo.bar", new = "Foo.baz" })
           |> batch
           |> mapErr EditFailed)
    |> andThen (\_ -> shell "dune test")
```
