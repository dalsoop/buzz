"""Find untranslated user-visible English in desktop agent surfaces.

1. JSX text nodes and common display props that are raw English (not wrapped
   in uiT()/t()).
2. uiT("...") sources with no Korean entry in the ui catalog.
3. String values in data/copy modules (catalogs, presets) that look like UI
   copy but never pass through uiT().
"""
import json, re, sys, pathlib

args = sys.argv[1:]
baseline = None
if args[:1] == ["--baseline"]:
    baseline, args = pathlib.Path(args[1]), args[2:]
root = pathlib.Path(args[0])            # desktop/src
paths = args[1:]
keys = json.load(open(root / "locales/ui-keys.json"))
ko_ui = json.load(open(root / "locales/ko.ui.json"))

def norm(s): return re.sub(r"\s+", " ", s).strip()

PROP = r"(?:title|description|placeholder|label|aria-label|ariaLabel|tooltip|helperText|emptyText|confirmLabel|cancelLabel|subtitle|hint)"
jsx_text = re.compile(r"(?<![A-Za-z])>\s*(?!Promise)([A-Z][A-Za-z'’,.!?:;()\- ]{2,}[a-z.!?)])\s*<")
prop_lit = re.compile(PROP + r'=\s*"([A-Z][^"{}]{2,})"')
obj_lit = re.compile(r'\b' + PROP + r':\s*"([A-Z][^"]{2,})"')
uit = re.compile(r'uiT\(\s*"((?:[^"\\]|\\.)*)"')

raw, missing, data_copy = [], [], []
files = []
for p in paths:
    pp = root / p
    files += sorted(pp.rglob("*.ts*")) if pp.is_dir() else [pp]
for f in files:
    if re.search(r"\.(test|jsdom-test)\.|\.d\.ts$", f.name):
        continue
    src = f.read_text()
    rel = f.relative_to(root)
    for i, line in enumerate(src.splitlines(), 1):
        if "uiT(" in line or re.search(r"\bt\(", line):
            pass
        for m in jsx_text.finditer(line):
            raw.append((rel, i, m.group(1)))
        for m in prop_lit.finditer(line):
            raw.append((rel, i, m.group(1)))
        if f.suffix == ".ts":
            for m in obj_lit.finditer(line):
                data_copy.append((rel, i, m.group(1)))
    for m in uit.finditer(src):
        s = norm(json.loads('"' + m.group(1) + '"'))
        k = keys.get(s)
        if not k or not ko_ui.get(k):
            line = src[: m.start()].count("\n") + 1
            missing.append((rel, line, s))

if baseline is not None:
    # Machine mode: one "path<TAB>text" line per finding; fail on any finding
    # not already accepted in the baseline (known names, type params, examples).
    found = sorted({f"{r[0]}\t{r[2]}" for r in raw + missing + data_copy})
    known = set(baseline.read_text().splitlines()) if baseline.exists() else set()
    new = [x for x in found if x not in known]
    for x in new:
        print(x)
    sys.exit(1 if new else 0)

def show(title, rows, limit=60):
    print(f"\n## {title}: {len(rows)}")
    by = {}
    for r in rows: by.setdefault(str(r[0]), []).append(r)
    for f, rs in sorted(by.items(), key=lambda x: -len(x[1])):
        print(f"  {f} ({len(rs)})")
        for _, ln, s in rs[:4]:
            print(f"    L{ln}: {s[:90]}")
show("raw English in JSX/props (not wrapped)", raw)
show("uiT() with no Korean translation", missing)
show("copy-like strings in .ts data modules", data_copy)
