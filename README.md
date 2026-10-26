# SINT IR PoC — двуязычный README / bilingual README

---

## РУССКАЯ ВЕРСИЯ

### Что это

Один файл, один IR, два движка. Малое s-expression IR, на котором дёшево
формулируется leaf-функция; два интерпретатора (**Python** и **SBCL / Common
Lisp**) читают один и тот же IR-текст, **эмитят один и тот же C**, и проверяют
результат на фиксированном тест-корпусе через gcc. Метод, а не масштаб:
первый локальный пруф того, что clean-room reimplement workflow может
опираться на механический артефакт, а не на прозу.

```
S-выражение IR ──parse──► дерево ──eval──► интерпретатор  (Python)  (SBCL)
                          │
                          └──c-emit──► C-текст ──gcc -Wall -Wextra──► OK
```

* Оба движка читают ОДИН И ТОТ ЖЕ IR-текст и эмитят ОДИН И ТОТ ЖЕ C — IR
  единственный источник истины.
* Два движка намеренно: Python — скорость прототипирования, SBCL —
  компилируемый рантайм, чтобы проверка не оставалась «игрушечным скриптом».
* `gcc -Wall -Wextra` обязан принять каждый эмитленный C — C-текст реальный,
  не декларативный.

### Возможности IR

* `(:function name :params (:p1 Type :p2 Type) :ret Type :body FORM)`
* арифметика `(+ - * /)`, `sqrt`, `min/max`, сравнения `(> < ==)`, `abs`,
  доступ к полям структуры через `:field`, непрозрачные `:call`
  (эмит вызова функции).
* **битовые операции** — словами (не через `^`/`>>`) для читаемости и
  Common Lisp переносимости: `xor` / `and` / `shl` / `shr`
* **состояние и циклы** — `(:let (:a …) stmt…)`, `(:loop N stmt…, последний
  stmt — `:set`), `(:set name expr)`
* тип `UInt32` → `uint32_t` (в C) / `logxor`+`logand`+`ash` in SBCL,
  та же семантика two's-complement через GNU statement-expressions.

### Чистая комната: CRC32-маркер

Тест-корпус содержит reimplement IEEE CRC-32, собранный ТОЛЬКО из публичной
спеки (poly 0xEDB88320, init 0xFFFFFFFF, final xor 4294967295) — это ровно та
функция, которую мы засекли внутри бинарника `kekatar` из Keka.app (оба
слайса Mach-O x86_64 и arm64 несут таблицу). Исходники Keka НЕ читались.
Сгенерированный C, который принимает gcc, и есть clean-room запись.

```
(:function crc32_step :params (:crc UInt32 :b UInt32) :ret UInt32
  :body (:let (:crc2 (xor :crc :b))
    (:loop 8
      (:set :crc2 (:if (and :crc2 1)
                    (xor (shr :crc2 1) 3988292384)
                    (shr :crc2 1))))))
```

Вектора: step `(4294967295, 49) → 2082672712`, `(2082672712, 50) →
2964110130`, `(2964110130, 51) → 2008521773`; full `49 50 51 52 53 54 55 56 57
→ 3421780262` (= zlib.crc32(b"123456789") = 0xCBF43926).

### Запуск

```
# Python-движок
python3 sexpr_ir_poc.py

# SBCL-движок (SBCL 2.6.x; если установлен в /usr/local/sbcl, нужен SBCL_HOME)
SBCL_HOME=/usr/local/sbcl/lib sbcl --noinform --load sexexpr_ir_sbcl.lisp \
    --eval '(ir-poc:main)' --eval '(sb-ext:exit)'
```

Текущее состояние (оба движка):
```
interp tests: 15/15 passed
[C]  gcc -Wall -Wextra -fsyntax-only: OK
```
Python: parse + 15 тестов ≈ 0.8 мс/цикл. SBCL: ≈ 0.1–0.26 мс/цикл.

### Файлы

* `sexpr_ir_poc.py` — Python-движок: tokenizer, parser, interpreter,
  C-эмиттер, gcc-check.
* `sexexpr_ir_sbcl.lisp` — Common Lisp (SBCL) движок: тот же IR, тот же C,
  те же тесты; плюс `--eval '(ir-poc:repl)'` для REPL-режима.
* `README.md` — двуязычный отчёт (RU + EN).

### Дизайн-правила (что делает это «кирпичом» reimplement)

1. **IR — единственное место, где функции пишутся руками.** Вниз (в C) и
   поперёк (движок 2) всё выводится автоматически.
2. **Тесты рядом с функциями.** Функция без векторв не существует.
3. **Числа вместо прозы.** PASS / FAIL / тайминги печатает движок.
4. **Не «цель», а метод.** Reimplement-метод SINT (disassembly-only clean
   room → leaf-функции в IR → механическая проверка) — то, PoC чего это.

### Roadmap

- [x] Python-движок: parse, interp, C emit, gcc check — 11/11 базовый корпус
- [x] SBCL (Common Lisp) порт — полный паритет IR/C-эмиссии/тестов, 11/11, REPL
- [x] Clean-room CRC32 через `:let` / `:loop` / `:set` + `xor/and/shl/shr`
      — 15/15 на обоих движках, оба C-эмита gcc-чистые
- [x] Вторая clean-room цель подтверждена: `kekatar` (Keka.app) несёт inline
      IEEE CRC32 (table[1] = 0x77073096, poly 0xEDB88320) — определено по
      данным бинарника
- [ ] Встроить метод в reimplement workflow (`VibeDarling/darling-appkit-gui`
      как база forked-цели: clean-room leaf-функции, AppKit reimplement-контекст).
- [ ] Опционально: Ghidra-headless批量 на clean-room целях для цикла RE → IR
      → тест.

---

## ENGLISH VERSION

### What this is

One IR, two engines. A tiny s-expression IR you can cheaply express a
leaf-function in; two interpreters (**Python** and **SBCL / Common Lisp**)
read the same IR text, **emit the same C**, and validate against a fixed test
corpus through gcc. The point is method, not scale: a first local proof that
a clean-room reimplement workflow can be anchored by a mechanical artifact
instead of prose.

```
s-expr IR ──parse──► tree ──eval──► interpreter  (Python) (SBCL)
                   │
                   └──c-emit──► C text ──gcc -Wall -Wextra──► OK
```

* Both engines read the SAME IR text and emit the SAME C — the IR is the
  single source of truth.
* Two engines on purpose: Python for hacking speed, SBCL for a compiled
  runtime so checks don't stay a "toy script".
* gcc has to accept every emitted C — the C text is real, not aspirational.

### IR features

* `(:function name :params (:p1 Type :p2 Type) :ret Type :body FORM)`
* arithmetic `(+ - * /)`, `sqrt`, `min/max`, comparisons `(> < ==)`, `abs`,
  struct `:field` access, opaque `:call` (emitted as function calls).
* **bit-wise ops** written as words (not `^`/`>>`) for readability and CL
  portability: `xor` / `and` / `shl` / `shr`
* **state and loops** — `(:let (:a …) stmt…)`, `(:loop N stmt…; last stmt must
  be `:set`), `(:set name expr)`
* type `UInt32` → `uint32_t` (C) / `logxor`+`logand`+`ash` (SBCL), same
  two's-complement semantics via GNU statement expressions.

### Clean-room marker: CRC32

The corpus includes a reimplemented IEEE CRC-32 built from the public spec
only (poly 0xEDB88320, init 0xFFFFFFFF, final xor) — exactly the function we
detected inside `kekatar` (Keka.app; both Mach-O slices carry the table).
Keka source was never read. The C that gcc accepts IS the clean-room record.

Vectors: step `(4294967295, 49) → 2082672712`, `(2082672712, 50) →
2964110130`, `(2964110130, 51) → 2008521773`; full `49 50 51 52 53 54 55 56 57
→ 3421780262` (= zlib.crc32(b"123456789") = 0xCBF43926).

### Run

```
python3 sexpr_ir_poc.py
SBCL_HOME=/usr/local/sbcl/lib sbcl --noinform --load sexpr_ir_sbcl.lisp \
    --eval '(ir-poc:main)' --eval '(sb-ext:exit)'
```

Current status (both engines):
```
interp tests: 15/15 passed
[C]  gcc -Wall -Wextra -fsyntax-only: OK
```
Python: parse + 15 tests ≈ 0.8 ms/cycle. SBCL: ≈ 0.1–0.26 ms/cycle.

### Files

* `sexpr_ir_poc.py` — Python engine (tokenizer, parser, interpreter, C emitter,
  gcc check).
* `sexexpr_ir_sbcl.lisp` — Common Lisp (SBCL) engine: same IR, same C, same
  tests; plus `--eval '(ir-poc:repl)'` for REPL mode.
* `README.md` — this bilingual report (RU + EN).

### Design rules

1. **The IR is the only place functions are written by hand.** Down (C),
   across (engine 2) — everything is derived.
2. **Tests next to functions.** A function without vectors does not exist.
3. **Numbers over prose.** PASS / FAIL / timings printed by the engine.
4. **Not the goal, the method.** SINT reimplement method (disassembly-only
   clean room → leaf-function IR → mechanical check) is what this is a PoC of.

### Roadmap

- [x] Python engine: parse, interp, C emit, gcc check — 11/11 base corpus
- [x] SBCL (Common Lisp) port — full parity of IR / C emission / tests, 11/11,
      REPL
- [x] Clean-room CRC32 via `:let` / `:loop` / `:set` + `xor/and/shl/shr`
      — 15/15 on both engines, both C emissions gcc-clean
- [x] Second clean-room target confirmed: `kekatar` (Keka.app) carries inline
      IEEE CRC32 (table[1] = 0x77073096, poly 0xEDB88320) — identified from
      binary data only
- [ ] Embed the method into the reimplement workflow
      (`VibeDarling/darling-appkit-gui` as backend: clean-room leaf-function
      checks, AppKit reimplement context).
- [ ] Optional: Ghidra headless batch on clean-room targets for a loop of
      RE → IR → test.
