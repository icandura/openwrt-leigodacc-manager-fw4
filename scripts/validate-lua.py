#!/usr/bin/env python3
"""Rough structural validator for the embedded LuCI Lua files.

There is no Lua interpreter in this workspace, so this checks the things that
break hand-edited Lua: unbalanced block keywords, parentheses and braces,
and stray long-string markers.

Block model:
  openers : function / if / do / repeat     (for/while are closed by their `do`)
  closers : end / until
  `elseif` / `else` neither open nor close.

Usage:
  python scripts/validate-lua.py luci-fw4-patch/luasrc/controller/acc.lua [...]
Exit code 0 = clean, 1 = problems.
"""
import re
import sys

OPENERS = {"function", "if", "do", "repeat"}
CLOSERS = {"end", "until"}
NEUTRAL = {"elseif", "else", "then"}


def strip_lua(line, state):
    """Remove -- comments and quoted strings. state carries long-bracket state."""
    out = []
    i = 0
    n = len(line)
    while i < n:
        if state.get("long"):
            end = state["long"]
            j = line.find(end, i)
            if j < 0:
                i = n
                break
            i = j + len(end)
            state["long"] = None
            continue
        c = line[i]
        if line.startswith("--", i):
            m = re.match(r"--\[(=*)\[", line[i:])
            if m:
                state["long"] = "]" + m.group(1) + "]"
                i += m.end()
                continue
            break
        if c in "\"'":
            q = c
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == q:
                    i += 1
                    break
                i += 1
            continue
        m = re.match(r"\[(=*)\[", line[i:])
        if m:
            state["long"] = "]" + m.group(1) + "]"
            i += m.end()
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(path):
    problems = []
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("BOM at file start")
    text = raw.decode("utf-8", "replace")
    if "\r\n" in text:
        problems.append("CRLF line endings")

    state = {}
    stack = []
    depth_par = 0
    for lineno, line in enumerate(text.split("\n"), 1):
        code = strip_lua(line, state)
        depth_par += code.count("(") - code.count(")")
        depth_par += code.count("{") - code.count("}")
        for tok in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", code):
            w = tok.group(0)
            if w in OPENERS:
                stack.append((w, lineno))
            elif w in CLOSERS:
                if not stack:
                    problems.append("line %d: %r without opener" % (lineno, w))
                    continue
                opener, oline = stack.pop()
                if (w == "end" and opener == "repeat") or (w == "until" and opener != "repeat"):
                    problems.append(
                        "line %d: %r closes %r opened at line %d" % (lineno, w, opener, oline))
        if state.get("long") is None:
            state.clear()

    for opener, oline in stack:
        problems.append("unclosed %r opened at line %d" % (opener, oline))
    if depth_par != 0:
        problems.append("unbalanced ()/{} : %+d" % depth_par)
    return problems


def main(argv):
    rc = 0
    for path in argv[1:]:
        problems = check(path)
        print("%s: %s" % (path, "OK" if not problems else "%d problem(s)" % len(problems)))
        for p in problems:
            print("  - " + p)
        if problems:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
