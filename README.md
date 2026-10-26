# sint-ir-poc

Минимальный исполняемый S-expression IR (Lisp-подобный AST):
парсер + интерпретатор + C-генератор на чистом Python.
Цель — быстрая валидация reimplement-функций macOS-фреймворков
(контекст Darling / VibeDarling): интерпретация на мок-корпусе,
сравнение с оригиналом, затем генерация C. Ни один тест не является
захардкоженным кодом — все функции существуют только как Lisp-текст.

## Результат

```
interp tests: 11/11 passed   (sqr, euclidian_distance, centerSizeInRect)
[C] gcc -Wall -Wextra -fsyntax-only: OK
[TIMING] avg 0.217 ms/cycle over 20 runs (parse + 11 tests)
```

Критерий «валидация кандидата < 1 секунды» перекрыт на ~4 порядка.

## Синтаксис IR (плоский)

```lisp
(:function sqr :params (:v CGFloat) :ret CGFloat
  :body (* :v :v))
```

Типы: `CGFloat`→`double`, `NSSize`, `NSPoint`, `NSRect`.
Формы: `:function`, `:if`, `:field`, `:call`; числа и символы различаются
анализом токена (0 обязан выживать).

## Тестируемые функции (эталон из Darling)

- `sqr` — NSGradient.m:346 (3 теста)
- `euclidian_distance` — NSGradient.m:351 (5 тестов)
- `centerSizeInRect` — NSSplitView.m:985 (3 теста)

## Живое доказательство, что это настоящий интерпретатор

Функции, которых никогда не было в коде, исполняются тем же путём
(tokenize → parse → eval):

```lisp
(:function clamp :params (:lo CGFloat :v CGFloat :hi CGFloat) :ret CGFloat
  :body (:if (< :v :lo) :lo (:if (> :v :hi) :hi :v)))
;; clamp(0, -7, 3) = 0.0, clamp(2, 9, 8) = 8.0 — вложенные :if работают
(:function max3 :params (:a CGFloat :b CGFloat :c CGFloat) :ret CGFloat
  :body (:call max :a (:call max :b :c)))
;; max3(1,2,3) = 3.0 — композиция функций работает
```

Кривая формула со случайными аргументами вернула буквально вычисленный
результат, а не «правильный» — критерий настоящего исполнителя.

## Найденные и исправленные баги (все три реальны, каждый ловится тестом)

1. `parse` перезаписывал top-level формы: `tree = node` при новой форме
   терял все предыдущие (`stack, tree = [], None`). Фикс: накапливать
   в `roots`-список. Симптом: `no IR function named 'sqr'`, пустой C.
2. `c_expr` для `:call` брал аргументы из `node[1:]` вместо `node[2:]` —
   callee попадал в аргументы: `sqr(sqr, (ax-bx))`, `{ point, ... }`.
3. `:call midx/midy` в C — это helper-макросы, а не функции: эмиссия
   должна быть uppercase `MIDX(inRect)`, иначе `implicit declaration`.

## Запуск

```sh
python3 sexpr_ir_poc.py                                        # движок 1: Python
SBCL_HOME=/usr/local/sbcl/lib sbcl --load sexexpr_ir_sbcl.lisp \
  --eval "(ir-poc:main)"                                       # движок 2: Common Lisp
```

Движок 2 (SBCL): 11/11, gcc OK, avg 0.056 ms/cycle — native reader
вместо рукописного парсера). Динамический REPL: `SBCL_HOME=... sbcl
--load sexpr_ir_sbcl.lisp --eval "(ir-poc:repl)"`.

## Roadmap

- [x] Порт на Common Lisp (SBCL) — `sexpr_ir_sbcl.lisp`: 11/11 PASS,
      gcc OK, 0.056 ms/cycle; два независимых движка дают бит-в-бит
      одинаковые результаты на одном IR.
- Расширение корпуса: `integralRect` (NSClipView.m:56),
  `computePeriod` (NSTableView.m:3437) — стресс-тест `:if` на реальных
  ветвлениях из Darling.
- Clean room на реальном macOS-приложении: цель выбрана — `kekatar`
  из Keka.app (inline CRC32-таблица с IEEE-полиномом 0xEDB88320,
  подтверждено по данным бинарника: table[1] = 0x77073096 в обоих
  слайсах x86_64/arm64); ground truth — публичный IEEE-спек,
  disassembly-only, без чтения исходников.
