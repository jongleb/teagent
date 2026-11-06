# Rune

Coding agent на OCaml. Модель пишет программу на Dartea (Elm-like, vendor/dartea),
харнесс её тайпчекает → планирует → выполняет → логирует. Единица обмена с моделью —
типизированная программа, не тул-колл. Все эффекты — через `Task`. Полный план: docs/PLAN.md.

## Инварианты (не нарушать)
- Архитектура TEA: в Elm нет сайд-эффектов. Программа модели — чистое значение-описание (`Task`/`Cmd`), харнесс — её рантайм. Kernel `Agent_*`/`Task_*` и `interp` только строят описание и никогда не выполняют IO; выполняет только handler.
- Эффекты выполняются ТОЛЬКО через handler в lib/effect. Никаких Unix/Lwt_io вне lib/tools.
- `Handler.staged` держит write/edit в overlay до `Tools.commit`. Процесс `shell` всегда видит тот же вид файлов, что и программа: в режиме `Contained` (по умолчанию) он идёт в APFS-клоне с overlay под Seatbelt (нет сети, запись только в клон), и всё записанное возвращается в overlay; в `Open` — только при пустом overlay, иначе `Blocked` и остаток задачи; `Disabled` — код 126.
- Интерпретируем Ir.Ast (vendor/dartea/lib/ir), не typed AST.
- Правки в vendor/dartea — только Data.Kernel, lib/prelude и public_name в dune. Прелюдия Agent живёт в Rune (lib/agent/Agent.elm), не в Dartea. Тесты Dartea (`dune test --root .` из vendor/dartea) должны оставаться зелёными.
- Своя реализация LLM-клиента. Никаких внешних AI-библиотек.
- Код: минимальный, без single-use функций, без `assert false`, illegal states unrepresentable.

## Сборка
opam switch test54 (OCaml 5.4, есть ppx_jane и menhir).
dune build 2>&1 | head -50   # vendored_dirs vendor
dune test

## Ориентиры в Dartea
- Compiler.compile_modules → Ir.Of_optimized.convert → Ir.Ast.declaration list
- Data.Kernel: `agent` (Agent_* / Task_*) — platform-kernel, резолвится бэкендом в lib/lang; в IR это `Platform {name}`, обратно через `Data.Kernel.agent_of_name`
- lib/prelude/prelude.ml + lib/prelude/dune: Elm-source строки прелюдии
- Reporting.Report: ошибки как есть идут модели
