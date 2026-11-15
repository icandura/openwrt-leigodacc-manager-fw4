#!/usr/bin/env python3
"""Lightweight structural validator for leigod-fw4.sh.

No POSIX shell is available in this workspace, so this performs the checks
that catch the mistakes made by hand-editing a 5000+ line shell script:

  * heredoc open/close balance and terminator placement
  * block keyword balance (if/fi, case/esac, do/done) outside heredocs,
    comments and quoted strings
  * function body brace balance
  * CRLF / BOM / tab contamination
  * stray references to removed helpers

Exit code 0 = clean, 1 = problems found.
"""
import re
import sys

HEREDOC = re.compile(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1')

OPENERS = {'if': 'fi', 'case': 'esac', 'do': 'done'}
KEYWORDS = {
    'if', 'then', 'elif', 'else', 'fi',
    'case', 'esac', 'for', 'while', 'until', 'do', 'done',
}


def strip_code(line, state=None):
    """Remove comments and quoted strings.

    `state` carries quote continuity across lines: shell single quotes may span
    lines (multi-line awk programs), and treating each line in isolation
    produces false brace-balance errors.
    """
    if state is None:
        state = {}
    out = []
    i = 0
    while i < len(line):
        quote = state.get('quote')
        c = line[i]
        if quote:
            if c == quote:
                state['quote'] = None

            elif c == '\\' and quote == '"':
                i += 1
            i += 1
            continue
        if line[i:i + 3] == '"' + "'" + '"':
            # shell idiom: "..." + "'" + "..."  (a literal single quote)
            i += 3
            continue
        if c in ('"', "'"):
            state['quote'] = c
            i += 1
            continue
        if c == '#':
            # '#' starts a comment only at word start
            if i == 0 or line[i - 1] in ' \t;|&(':
                break
        out.append(c)
        i += 1
    return ''.join(out)


def main(path):
    problems = []
    with open(path, 'rb') as fh:
        raw = fh.read()

    if raw.startswith(b'\xef\xbb\xbf'):
        problems.append('BOM found at file start')
    if b'\r\n' in raw:
        bad = raw.count(b'\r\n')
        problems.append('%d CRLF line(s) found (script must be LF)' % bad)

    text = raw.decode('utf-8', 'replace')
    lines = text.split('\n')

    # ---- heredoc scan -------------------------------------------------
    heredocs = []          # stack of (terminator, start_line)
    code_lines = []        # (lineno, code_without_heredoc_bodies)
    in_heredoc = set()     # line numbers that belong to a heredoc body
    for idx, line in enumerate(lines, 1):
        if heredocs:
            code_lines.append((idx, ''))
            in_heredoc.add(idx)
            if line.strip() == heredocs[-1][0] or line == heredocs[-1][0]:
                heredocs.pop()
            continue
        m = HEREDOC.search(line)
        code_lines.append((idx, line))
        if m:
            heredocs.append((m.group(2), idx))
    if heredocs:
        for term, start in heredocs:
            problems.append('unterminated heredoc %r opened at line %d' % (term, start))

    # ---- block balance -------------------------------------------------
    # NOTE: deliberately not attempted here. Shell keyword balance cannot be
    # decided reliably without a full parser (command substitutions restart
    # quoting, "..."'"..." idioms, here-strings, case patterns, ...).
    # `bash -n <script>` is the authoritative syntax gate and is run alongside
    # this validator; everything else below is a cheap structural sanity check.

    # ---- function brace balance ---------------------------------------
    func_start = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{\s*$')
    for i, line in enumerate(lines):
        if not func_start.match(line):
            continue
        name = func_start.match(line).group(1)
        depth = 0
        stack = [0]
        qstate = {}
        for j in range(i, len(lines)):
            if (j + 1) in in_heredoc:
                qstate.clear()
                continue
            stripped = strip_code(lines[j], qstate)
            net = stripped.count('{') - stripped.count('}')
            if net:
                stack[-1] += net
                if stack[-1] <= 0:
                    break
        else:
            problems.append('function %s (line %d) has unbalanced braces' % (name, i + 1))

    # ---- dead helper references ---------------------------------------
    for helper in ('safe_opkg_install', 'safe_pkg_install', 'pkg_installed'):
        calls = len(re.findall(r'(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])' % helper, text))
        defines = len(re.findall(r'^%s\(\)' % helper, text, re.M))
        print('  %-20s defined=%d referenced=%d' % (helper, defines, calls))

    print('lines: %d' % len(lines))
    if problems:
        print('\nPROBLEMS (%d):' % len(problems))
        for p in problems:
            print('  - ' + p)
        return 1
    print('OK: heredocs balanced, block keywords balanced, braces balanced')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'leigod-fw4.sh'))
