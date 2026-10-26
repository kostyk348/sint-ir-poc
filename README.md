# SINT IR PoC — a multilingual "brick" for reimplement functions

One file, one IR, two engines. A tiny s-expression IR that cheaply states a leaf
function, runs it on both a **Python** interpreter and an **SBCL (Common Lisp)**
interpreter, emits equivalent C, and validates the result against a fixed test
corpus with gcc. The point is method, not scale: the first local proof that a
*clean-room reimplement workflow* can be anchored by a mechanical artifact
rather than prose.

## What you get

```
S-expression IR  ──parse──►  tree  ──eval──►  interpreter    (Python)   (SBCL)
                          │
                          └──c-emit──►  C source  ──gcc -Wall -Wextra──►  OK
```

* Both engines read the SAME IR text and emit the SAME C — the IR is the
  single source of truth.
* Two engines on purpose: Python for speed of hacking, SBCL for a compiled
  runtime so the checks do not stay as a "toy script". Different runtimes,
  identical spec.
* `gcc -Wall -Wextra` has to accept every emitted C — the C text is real, not
  aspirational.

## Features in the IR

* `(:function name :params (:p1 Type :p2 Type) :ret Type :body FORM)`
* arithmetic `(+)`, `(-)`, `(*)`, `(/)`, `sqrt`, `min` / `max` — semantic
  `(max | cd28 | <)`, `abs`, struct `:field` accesses, opaque `:call`s
  (function-call emission).
* **bit operations**, written as words to keep both reader nests cheap
  and Common Lisp portable: `xor` / `and` / `shl` / `shr`
* **state + loops** — `(:let (:a …) stmt…)`, `(:loop N stmt…:last :set)`,
  `(:set name expr)`
* `UInt32` type (`uint32_t` in C; `Logxor/Logand/Ash` in SBCL, same
  two's-complement wrap-around semantics with GNU statement-expressions).

## The CRC32 clean-room marker

The test corpus contains a reimplemented IEEE CRC-32, built ONLY from the
public spec (poly 0xEDB88320, init 0xFFFFFFFF, final xor) — this is the exact
function we detected inside the `kekatar` binary of Keka.app (both x86_64 and
arm64 Mach-O slices carry the table).
No Keka source code was read. The little `.c`
file that gcc accepts at the end is what the clean-room record looks like.

```
(:function crc32_step :params (:crc UInt32 :b UInt32) :ret UInt32
  :body (:let (:crc2 (xor :crc :b))
    (:loop 8
      (:set :crc2 (:if (and :crc2 1)
                    (xor (shr :crc2 1) 3988292384)
                    (shr :crc2 1))))))

(:function crc32_full :params (:b1 UInt32 :b2 UInt32 :b3 UInt32 :b4 UInt32
                               :b5 UInt32 :b6 UInt32 :b7 UInt32 :b8 UInt32
                               :b9 UInt32) :ret UInt32
  :body (xor (:call crc32_step …9 nested… ) 4294967295))
```

Vectors: step `4294967295 + 49 → 2082672712`, `2082672712 + 50 → 2964110130`,
`2964110130 + 51 → 2008521773`; full `49 50 51 52 53 54 55 56 57 → 3421780262`
(zlib.crc32(b"123456789") = 0xCBF43926).

## Run

```
# Python engine
python3 sexpr_ir_poc.py

# SBCL engine (SBCL 2.6.x; if installed to /usr/local/sbcl, set SBCL_HOME)
SBCL_HOME=/usr/local/sbcl/lib sbcl --noinform --load sexpr_ir_sbcl.lisp \
    --eval '(ir-poc:main)' --eval '(sb-ext:exit)'
```

Current status (both engines):

```
interp tests: 15/15 passed
[C]  gcc -Wall -Wextra -fsyntax-only: OK
```

Python: parse + 15 tests ≈ 0.8 ms/cycle. SBCL: ≈ 0.1–0.3 ms/cycle.

## Files

* `sexpr_ir_poc.py` — Python engine: tokenizer, parser, interpreter,
  C emitter, gcc check.
* `sexpr_ir_sbcl.lisp` — the Common Lisp (SBCL) engine, same IR, same C,
  same tests; also gives you a `--eval '(ir-poc:repl)'` for REPL-mode.
* `README.md` — this file.

## Design rules (what makes this a "reimplement brick")

1. **The IR is the ONLY place functions are written by hand.** Everything down
   (C) and everything across (engine 2) is derived.
2. **Tests next to functions.** A function without vectors does not exist.
3. **Numbers over prose.** "PASS", "FAIL", timings printed by the engine.
4. **It's not the target of where this leads — the method is.** SINT's
   reimplement method (disassembly-only clean room → leaf-function IR →
   mechanical check) is what this is a PoC of. Scale-up plans live outside.

## Roadmap

- [x] Python engine: parse, interp, C emit, gcc check — 11/11 basic corpus
- [x] SBCL (Common Lisp) port — full parity of IR, C emission, 11/11, REPL
- [x] Clean-room CRC32 via `:let` / `:loop` / `:set` + `xor/and/shl/shr`
      — 15/15 on both engines, both C emissions gcc-clean
- [x] Second clean-room target confirmed: `kekatar` (Keka.app) carries inline
      IEEE CRC32 (table[1] = 0x77073096, poly 0xEDB88320) — identified from
      binary data only
- [ ] Embed the method into the reimplement workflow
      (`VibeDarling/darling-appkit-gui` as its forked backend: clean-room
      leaf-function checks, AppKit reimplement context).
- [ ] Optional: Ghidra headless BatchRun on clean-room targets for a
      structured loop of RE → IR → test.

## License

Same license as the repository (MIT unless stated otherwise).
