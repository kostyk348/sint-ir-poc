#!/usr/bin/env python3
"""Minimal S-expression IR PoC: parser + interpreter + C generator.

Goal: validate a candidate reimplementation against a mock corpus in <1s,
before touching any real C/ObjC artifact (Darling reimplementation workflow).
Reference functions: sqr (NSGradient.m:346), euclidian_distance (:351),
centerSizeInRect (NSSplitView.m:985).
"""
import math
import os
import subprocess
import tempfile
import time

# --- reference corpus as IR (open syntax: :function name :params (:a CGFloat ...) :ret t :body (...))
IR_SOURCE = """
(:function sqr :params (:v CGFloat) :ret CGFloat
  :body (* :v :v))

(:function euclidian_distance
  :params (:ax CGFloat :ay CGFloat :bx CGFloat :by CGFloat)
  :ret CGFloat
  :body (sqrt (+ (:call sqr (- :ax :bx)) (:call sqr (- :ay :by)))))

(:function centerSizeInRect
  :params (:innerSize NSSize :inRect NSRect)
  :ret NSPoint
  :body (:call point
    (+ (:field :inRect :x)
       (max (- (:call midx :inRect) (/ (:field :innerSize :width) 2)) 0))
    (+ (:field :inRect :y)
       (max (- (:call midy :inRect) (/ (:field :innerSize :height) 2)) 0))))
"""

# --- parser -----------------------------------------------------------------


def tokenize(src):
    return src.replace("(", " ( ").replace(")", " ) ").split()


def _num_or_sym(tok):
    """0 must survive: try int, then float, else keep the token string."""
    if tok.startswith(":"):
        return tok
    try:
        return int(tok)
    except ValueError:
        pass
    try:
        return float(tok)
    except ValueError:
        pass
    return tok


def parse(src):
    stack, roots = [], []
    for tok in tokenize(src):
        if tok == "(":
            node = []
            if stack:
                stack[-1].append(node)
            else:
                roots.append(node)
            stack.append(node)
        elif tok == ")":
            if not stack:
                raise SyntaxError("unbalanced ')'")
            stack.pop()
        else:
            if not stack:
                raise SyntaxError("token outside form: %r" % tok)
            stack[-1].append(_num_or_sym(tok))
    if stack:
        raise SyntaxError("unbalanced '('")
    return roots


def split_form(form):
    """form[0]==':function' -> (name, [(param, type)...], ret, body)"""
    name = form[1].lstrip(":")
    params, ret, body = [], None, None
    i = 2
    while i < len(form):
        key = form[i]
        if key == ":params":
            plist = form[i + 1]
            for j in range(0, len(plist) - 1, 2):
                params.append((plist[j].lstrip(":"), plist[j + 1]))
            i += 2
        elif key == ":ret":
            ret = form[i + 1]
            i += 2
        elif key == ":body":
            body = form[i + 1]
            i += 2
        else:
            raise ValueError("unknown key in form: %r" % (key,))
    return name, params, ret, body


# --- interpreter -------------------------------------------------------------


OPS = {
    "+": lambda a: math.fsum(a),
    "-": lambda a: -a[0] if len(a) == 1 else a[0] - math.fsum(a[1:]),
    "*": lambda a: math.prod(a),
    "/": lambda a: a[0] / a[1],
    "max": lambda a: max(a),
    "min": lambda a: min(a),
    "sqrt": lambda a: math.sqrt(a[0]),
    "abs": lambda a: abs(a[0]),
    "<": lambda a: a[0] < a[1],
    ">": lambda a: a[0] > a[1],
    "==": lambda a: a[0] == a[1],
    "point": lambda a: (float(a[0]), float(a[1])),
    "midx": lambda a: a[0]["x"] + a[0]["width"] / 2.0,
    "midy": lambda a: a[0]["y"] + a[0]["height"] / 2.0,
}


def function_forms(tree):
    return [f for f in tree if isinstance(f, list) and f and f[0] == ":function"]


def eval_body(body, env, tree):
    """body[0] is a string op/symbol -> single expression; list -> statements."""
    if isinstance(body[0], str):
        return eval_node(body, env, tree)
    result = None
    for expr in body:
        result = eval_node(expr, env, tree)
    return result


def eval_node(node, env, tree):
    if isinstance(node, (int, float)) or not isinstance(node, list):
        if isinstance(node, str) and node.startswith(":"):
            return env[node.lstrip(":")]
        return node
    op = node[0]
    if op == ":if":
        return eval_node(node[2] if eval_node(node[1], env, tree) else node[3], env, tree)
    if op == ":field":
        recv = eval_node(node[1], env, tree)
        return recv[node[2].lstrip(":")]
    if op == ":call":
        callee = node[1].lstrip(":")
        if callee == "point":
            args = [eval_node(a, env, tree) for a in node[2:]]
            return point(args)
        if callee not in OPS:
            return call_fn(tree, callee, [eval_node(a, env, tree) for a in node[2:]])
        args = [eval_node(a, env, tree) for a in node[2:]]
        return OPS[callee](args)
    if op not in OPS:
        raise LookupError("unsupported op in IR: %r" % (op,))
    args = [eval_node(a, env, tree) for a in node[1:]]
    return OPS[op](args)


def point(args):
    return (float(args[0]), float(args[1]))


def call_fn(tree, name, argv):
    for form in function_forms(tree):
        fname, params, _ret, body = split_form(form)
        if fname != name:
            continue
        env = dict(zip([p for p, _t in params], argv))
        return eval_body(body, env, tree)
    raise LookupError("no IR function named %r" % (name,))


# --- test corpus + tolerance check -------------------------------------------

TESTS = {
    "sqr": [
        ([2.0], 4.0),
        ([-3.0], 9.0),
        ([2.5], 6.25),
    ],
    "euclidian_distance": [
        ([0.0, 0.0, 3.0, 4.0], 5.0),
        ([0.0, 0.0, 1.0, 1.0], math.sqrt(2.0)),
        ([1.0, 1.0, 2.0, 2.0], math.sqrt(2.0)),
        ([1.5, 2.5, 4.5, 6.5], 5.0),
        ([0.0, 0.0, 0.0, 0.0], 0.0),
    ],
    "centerSizeInRect": [
        (
            [{"width": 8.0, "height": 6.0}, {"x": 0.0, "y": 0.0, "width": 12.0, "height": 10.0}],
            (2.0, 2.0),
        ),
        (
            [{"width": 16.0, "height": 10.0}, {"x": 0.0, "y": 0.0, "width": 12.0, "height": 10.0}],
            (0.0, 0.0),
        ),
        (
            [{"width": 2.0, "height": 2.0}, {"x": 0.0, "y": 0.0, "width": 4.0, "height": 4.0}],
            (1.0, 1.0),
        ),
    ],
}
TOLERANCE = 1e-9


def _close(got, want):
    if isinstance(want, tuple):
        return isinstance(got, tuple) and all(
            abs(g - w) <= TOLERANCE for g, w in zip(got, want)
        )
    return abs(got - want) <= TOLERANCE


def run_tests(tree):
    results = []
    for name, cases in TESTS.items():
        for argv, want in cases:
            want_str = "point%s" % (want,) if isinstance(want, tuple) else repr(want)
            try:
                got = call_fn(tree, name, argv)
                got_str = "point%s" % (got,) if isinstance(got, tuple) else repr(got)
                results.append((name, want_str, got_str, _close(got, want)))
            except Exception as exc:
                results.append((name, want_str, "EXC: %s" % exc, False))
    return results


# --- C generator -------------------------------------------------------------

PREAMBLE = """\
/* generated from s-expression IR (PoC): parse_IR -> emit_C */
#include <math.h>
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#define MIDX(r) ((r).x + (r).width / 2.)
#define MIDY(r) ((r).y + (r).height / 2.)
typedef double CGFloat;
typedef struct { CGFloat x, y; } NSPoint;
typedef struct { CGFloat width, height; } NSSize;
typedef struct { CGFloat x, y, width, height; } NSRect;
"""

TYPE_MAP = {"CGFloat": "double", "NSSize": "NSSize", "NSPoint": "NSPoint", "NSRect": "NSRect"}


def c_num(node):
    return "%r" % float(node)


def c_expr(node):
    if isinstance(node, (int, float)):
        return c_num(node)
    if not isinstance(node, list):
        return node.lstrip(":")
    op = node[0]
    a = [c_expr(x) for x in node[1:]]
    if op == ":field":
        return "%s.%s" % (c_expr(node[1]), node[2].lstrip(":"))
    if op == ":call":
        callee = node[1].lstrip(":")
        args = [c_expr(x) for x in node[2:]]  # node[1] is the callee, not an argument
        if callee == "point":
            return "((NSPoint){ %s, %s })" % (args[0], args[1])
        if callee in ("midx", "midy"):
            return "%s(%s)" % (callee.upper(), ", ".join(args))
        return "%s(%s)" % (callee, ", ".join(args))
    if op == ":if":
        return "(%s ? %s : %s)" % (a[0], a[1], a[2])
    if op == "+":
        return "(%s)" % " + ".join(a)
    if op == "*":
        return "(%s)" % " * ".join(a)
    if op == "-":
        if len(a) <= 1:
            return "(-%s)" % a[0]
        return "(%s - %s)" % (a[0], " - ".join(a[1:]))
    if op == "/":
        return "(%s / %s)" % (a[0], a[1])
    if op in ("max", "min"):
        return "%s(%s, %s)" % (op.upper(), a[0], a[1])
    if op == "sqrt":
        return "sqrt(%s)" % a[0]
    if op in ("abs", "fabs"):
        return "fabs(%s)" % a[0]
    if op in ("<", ">", "=="):
        return "(%s %s %s)" % (a[0], op, a[1])
    raise ValueError("no C emission for op: %r" % (op,))


def gen_c(tree):
    lines = [PREAMBLE]
    for form in function_forms(tree):
        name, params, ret, body = split_form(form)
        decls = ", ".join("%s %s" % (TYPE_MAP[t], p) for p, t in params)
        lines.append("static %s %s(%s);" % (TYPE_MAP[ret], name, decls))
    for form in function_forms(tree):
        name, params, ret, body = split_form(form)
        decls = ", ".join("%s %s" % (TYPE_MAP[t], p) for p, t in params)
        lines.append("")
        lines.append("static %s %s(%s) {" % (TYPE_MAP[ret], name, decls))
        lines.append("    return %s;" % c_expr(body))
        lines.append("}")
    return "\n".join(lines) + "\n"


def compile_check(source):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "poc.c")
        with open(path, "w") as f:
            f.write(source)
        proc = subprocess.run(
            ["gcc", "-Wall", "-Wextra", "-fsyntax-only", path],
            capture_output=True,
            text=True,
        )
        return proc.returncode == 0, (proc.stderr or "").strip()


# --- driver ------------------------------------------------------------------


def main():
    tree = parse(IR_SOURCE)

    results = run_tests(tree)
    passed = 0
    print("== interpreter vs mock corpus ==")
    for name, want, got, ok in results:
        mark = "PASS" if ok else "FAIL"
        passed += ok
        print("[%s] %-18s want=%-24s got=%-24s" % (mark, name, want, got))
    total = len(results)
    print("interp tests: %d/%d passed" % (passed, total))

    source = gen_c(tree)
    print()
    print("== emitted C ==")
    print(source)

    ok, err = compile_check(source)
    print("[C]  gcc -Wall -Wextra -fsyntax-only: %s%s" % ("OK" if ok else "FAIL", "" if not err else "  stderr: " + err))

    times = []
    for _ in range(20):
        t0 = time.perf_counter()
        parse(IR_SOURCE)
        run_tests(tree)
        times.append(time.perf_counter() - t0)
    print("[TIMING] avg %.3f ms/cycle over 20 runs (parse + %d tests)" % (sum(times) / len(times) * 1000.0, total))


if __name__ == "__main__":
    main()
