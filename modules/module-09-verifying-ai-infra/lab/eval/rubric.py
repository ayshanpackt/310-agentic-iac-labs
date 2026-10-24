#!/usr/bin/env python3
"""Deterministic rubric: does this Terraform output tag every S3 bucket the way
M04's convention requires? No model involved, exit 0 or 1.

The rubric reads the real `tags = { ... }` attribute of each aws_s3_bucket resource, so
the required names have to appear as keys of that map. A comment that mentions them, a
string value that contains them, or a tags block on a neighbouring resource does not
count. A tags value the rubric cannot read statically (var.x, merge(...), local.tags) is
reported as a violation rather than waved through: the rubric fails closed."""
import re
import sys

REQUIRED_TAGS = ["Environment", "Owner", "ManagedBy"]

# Shadow the source: comments become spaces and string bodies become 'x', so brace
# matching and keyword searches run on a copy that only contains real structure. The
# shadow is the same length as the source, so every index points at the same character
# in both.
def shadow(src):
    out = list(src)
    n = len(src)

    def blank(j):
        if src[j] != "\n":
            out[j] = "x"

    def scan_string(i):
        """i points at an opening quote. Shadow the string body, including any quoted
        strings nested inside ${ } interpolation, and return the index after the closing
        quote."""
        i += 1
        depth = 0
        while i < n:
            ch = src[i]
            if ch == "\\":
                blank(i)
                if i + 1 < n:
                    blank(i + 1)
                i += 2
                continue
            if depth == 0 and ch == '"':
                return i + 1
            if src.startswith("${", i) or src.startswith("%{", i):
                depth += 1
                blank(i)
                blank(i + 1)
                i += 2
                continue
            if depth and ch == '"':
                i = scan_string(i)  # a nested string inside the interpolation
                continue
            if depth and ch == "}":
                depth -= 1
            blank(i)
            i += 1
        return n

    i = 0
    while i < n:
        c = src[i]
        if c == "#" or src.startswith("//", i):
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for j in range(i, end):
                if src[j] != "\n":
                    out[j] = " "
            i = end
        elif c == '"':
            i = scan_string(i)
        else:
            i += 1
    return "".join(out)


def matching_brace(sh, open_idx):
    """Index of the '}' that closes the '{' at open_idx, or -1."""
    depth = 0
    for i in range(open_idx, len(sh)):
        if sh[i] == "{":
            depth += 1
        elif sh[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def top_level_spans(sh, start, end):
    """Yield (a, b) spans of sh[start:end] that sit outside any nested { }."""
    depth, a = 0, start
    for i in range(start, end):
        if sh[i] == "{":
            if depth == 0:
                yield (a, i + 1)  # keep the brace: "tags = {" needs it to be recognised
            depth += 1
        elif sh[i] == "}":
            depth -= 1
            if depth == 0:
                a = i + 1
    yield (a, end)


def find_bucket_blocks(src, sh):
    """(name, body_start, body_end) for every aws_s3_bucket resource."""
    blocks = []
    for m in re.finditer(r'resource\s+"(x+)"\s+"(x+)"\s*\{', sh):
        if src[m.start(1):m.end(1)] != "aws_s3_bucket":
            continue
        name = src[m.start(2):m.end(2)]
        open_idx = m.end() - 1
        close_idx = matching_brace(sh, open_idx)
        if close_idx < 0:
            close_idx = len(sh)
        blocks.append((name, open_idx + 1, close_idx))
    return blocks


def tags_attribute(src, sh, start, end):
    """The tags attribute of a resource body. Returns ("map", keys), ("expr", text)
    for a value that is not a literal map, ("dup", None) for a repeated attribute, or
    (None, None) when there is no tags attribute at the top level of the body."""
    found = []
    for a, b in top_level_spans(sh, start, end):
        for m in re.finditer(r"(?m)^[ \t]*tags[ \t]*=[ \t]*(\S)", sh[a:b]):
            found.append((a + m.start(1), m.group(1)))
    if not found:
        return None, None
    if len(found) > 1:
        return "dup", None
    pos, first = found[0]
    if first != "{":
        line_end = sh.find("\n", pos)
        return "expr", src[pos:line_end if line_end >= 0 else len(src)].strip()
    close = matching_brace(sh, pos)
    if close < 0:
        return "expr", "unterminated map"
    keys = {}
    for a, b in top_level_spans(sh, pos + 1, close):
        for m in re.finditer(r'(?:^|[\s,{])("x+"|[A-Za-z_][\w-]*)\s*[=:]\s*([^\n,}]*)', sh[a:b]):
            key = src[a + m.start(1):a + m.end(1)].strip('"')
            value = src[a + m.start(2):a + m.end(2)].strip()
            keys[key] = value
    return "map", keys


def present(value):
    return value not in ("", '""', "null")


def check(path):
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        return False, [f"file not found: {path}"]
    sh = shadow(src)
    blocks = find_bucket_blocks(src, sh)
    if not blocks:
        return False, ["no aws_s3_bucket resource found"]
    violations = []
    for name, start, end in blocks:
        kind, data = tags_attribute(src, sh, start, end)
        if kind == "expr":
            violations.append(
                f"aws_s3_bucket.{name}: tags is not a literal map ({data}), cannot verify statically"
            )
            continue
        if kind == "dup":
            violations.append(f"aws_s3_bucket.{name}: tags attribute appears more than once")
            continue
        keys = data or {}
        missing = [t for t in REQUIRED_TAGS if not present(keys.get(t, ""))]
        if missing:
            violations.append(f"aws_s3_bucket.{name}: missing tags {missing}")
    return (not violations), violations


def main():
    if len(sys.argv) != 2:
        print("usage: rubric.py <path-to-terraform-file>", file=sys.stderr)
        return 2

    ok, violations = check(sys.argv[1])
    if ok:
        print(f"PASS: every bucket in {sys.argv[1]} carries {REQUIRED_TAGS}")
        return 0
    print(f"FAIL: {sys.argv[1]} does not meet the tagging rubric")
    for v in violations:
        print(" -", v)
    return 1


if __name__ == "__main__":
    sys.exit(main())
