"""Extract printable strings from a binary and grep for recon-relevant patterns.

Usage: python scripts/strings-grep.py <binary> [pattern ...]
"""
import re
import sys

PRINTABLE = re.compile(rb"[\x20-\x7e]{6,}")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    pats = [p.lower() for p in argv[2:]] or None
    data = open(path, "rb").read()
    seen = set()
    out = []
    for m in PRINTABLE.finditer(data):
        s = m.group(0).decode("ascii", "replace")
        if s in seen:
            continue
        seen.add(s)
        if pats is None or any(p in s.lower() for p in pats):
            out.append(s)
    for s in out:
        print(s)
    print("---- %d matching strings ----" % len(out), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
