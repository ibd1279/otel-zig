#!/usr/bin/env python3
"""Audit src/semconv/*.zig against the semantic-conventions model YAML.

Handles both on-disk shapes:
  v1.41.x : groups: -> - id: <name>   (weaver v1)
  v1.44+  : attributes: -> - key: <name>   (file_format: definition/2)
Enum members are a nested `members:` map under `type:`; deprecated attributes
carry a `deprecated:` block, usually with `renamed_to:`.
"""
import os, re, sys, json, collections

ATTR_TYPES = {"string", "int", "double", "boolean", "string[]", "int[]",
              "double[]", "boolean[]", "enum", "map", "any"}
GROUP_TYPES = {"attribute_group", "span", "metric", "event", "entity",
               "metric_group", "scope", "resource", "metric_ref"}

ENTRY_RE = re.compile(r"^(\s*)-\s+(id|ref|key):\s*(\S+)\s*$")
TYPE_RE = re.compile(r"^(\s+)type:\s*(\S.*?)?\s*$")
VAL_RE = re.compile(r"^\s+value:\s*(.+?)\s*$")
MEMBERS_RE = re.compile(r"^(\s+)members:\s*$")
DEP_RE = re.compile(r"^(\s+)deprecated:\s*$")
RENAMED_RE = re.compile(r"^\s+renamed_to:\s*(\S+)\s*$")


def parse_model(root):
    attrs, enums, formats, metrics = {}, collections.defaultdict(set), collections.Counter(), set()
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            if not fn.endswith(".yaml"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
            formats["v2" if any(l.startswith("file_format: definition/2") for l in lines) else "v1"] += 1
            cur = None

            def flush():
                nonlocal cur
                if not cur:
                    return
                indent, ident, block = cur
                cur = None
                t, is_enum, dep, renamed = None, False, False, None
                child = indent + 2
                for b in block:
                    if MEMBERS_RE.match(b):        # members: lives one level under type:
                        is_enum = True
                        continue
                    if len(b) - len(b.lstrip()) != child:
                        continue
                    if DEP_RE.match(b):
                        dep = True
                        continue
                    m = TYPE_RE.match(b)
                    if m and m.group(2):
                        t = m.group(2).split("#")[0].strip()
                if dep:                            # renamed_to sits under deprecated:
                    for b in block:
                        if len(b) - len(b.lstrip()) > child:
                            r = RENAMED_RE.match(b)
                            if r:
                                renamed = r.group(1).strip("'\"")
                                break
                if is_enum:
                    t = "enum"
                if t == "metric" and ident.startswith("metric."):
                    metrics.add(ident[len("metric."):])
                if not t or t in GROUP_TYPES or "." not in ident:
                    return
                if t not in ATTR_TYPES and not t.startswith("template["):
                    return
                attrs.setdefault(ident, {"file": rel, "type": t, "deprecated": dep, "renamed_to": renamed})
                if t == "enum":
                    for b in block:
                        mv = VAL_RE.match(b)
                        if mv:
                            enums[ident].add(mv.group(1).strip().strip("'\""))

            def is_group_block():
                for b in cur[2]:
                    mm = TYPE_RE.match(b)
                    if mm and mm.group(2) and mm.group(2).split("#")[0].strip() in GROUP_TYPES:
                        return True
                return False

            for line in lines:
                m = ENTRY_RE.match(line)
                if m:
                    indent = len(m.group(1))
                    if cur and indent > cur[0]:
                        if is_group_block():
                            flush()
                            if m.group(2) in ("id", "key"):
                                cur = (indent, m.group(3), [])
                            continue
                        cur[2].append(line)  # enum member
                        continue
                    if cur:
                        flush()
                    if m.group(2) in ("id", "key"):
                        cur = (indent, m.group(3), [])
                    continue
                if cur is not None:
                    cur[2].append(line)
            flush()
    return attrs, enums, formats, metrics


ZIG_CONST_RE = re.compile(r'pub const \w+\s*=\s*"([^"]*)"')
ZIG_VAL_RE = re.compile(r'^\s*\w+\s*=\s*"([^"]*)"')


def parse_zig(path):
    lit = set()
    for line in open(path, encoding="utf-8"):
        if line.lstrip().startswith("//"):
            continue
        lit.update(m.group(1) for m in ZIG_CONST_RE.finditer(line))
        m = ZIG_VAL_RE.match(line)
        if m:
            lit.add(m.group(1))
    return lit


def main():
    new_root, old_root, zig_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    new_attrs, new_enums, new_fmt, new_metrics = parse_model(new_root)
    old_attrs, old_enums, old_fmt, old_metrics = parse_model(old_root)
    files = sorted(f for f in os.listdir(zig_dir) if f.endswith(".zig"))
    ours = {f: parse_zig(os.path.join(zig_dir, f)) for f in files}
    our_keys = {k for s in ours.values() for k in s if "." in k and k[0].islower()}
    prefixes = {k.split(".")[0] for k in our_keys}

    print("MODEL FORMAT   v1.41: %s   v1.45: %s" % (dict(old_fmt), dict(new_fmt)))
    print("ATTRIBUTES     %d -> %d   (+%d / -%d)" % (len(old_attrs), len(new_attrs),
                                                     len(set(new_attrs) - set(old_attrs)),
                                                     len(set(old_attrs) - set(new_attrs))))
    print("DEPRECATED     %d -> %d" % (sum(a["deprecated"] for a in old_attrs.values()),
                                       sum(a["deprecated"] for a in new_attrs.values())))

    added = [a for a in sorted(set(new_attrs) - set(old_attrs)) if a.split(".")[0] in prefixes]
    removed = [a for a in sorted(set(old_attrs) - set(new_attrs)) if a.split(".")[0] in prefixes]
    print("\nIN-SCOPE ADDED (%d): %s" % (len(added), ", ".join(added)))
    print("IN-SCOPE REMOVED (%d): %s" % (len(removed), ", ".join(removed) or "-"))

    print("\nENUM MEMBER CHANGES in attrs we define:")
    n = 0
    for a in sorted(set(new_enums) | set(old_enums)):
        if a.split(".")[0] not in prefixes:
            continue
        o, w = set(old_enums.get(a, ())), set(new_enums.get(a, ()))
        if o != w:
            n += 1
            print("  %-38s +%s -%s" % (a, sorted(w - o), sorted(o - w)))
    if not n:
        print("  none")

    print("\nPER-FILE (deprecated spec attrs excluded from MISSING)")
    totals = collections.Counter()
    for f in files:
        mine = {k for k in ours[f] if "." in k and k[0].islower()}
        if not mine:
            continue
        prefs = tuple({k.split(".")[0] for k in mine})
        spec = {a for a in new_attrs if a.startswith(tuple(p + "." for p in prefs))}
        miss_cur = sorted(a for a in spec - mine if not new_attrs[a]["deprecated"])
        miss_dep = len(spec - mine) - len(miss_cur)
        stale = sorted(k for k in mine if k not in new_attrs)
        stale_ren = {k.split(".")[0]: 0 for k in []}
        print("%-15s have=%-3d  current-gap=%-3d deprecated-gap=%-3d stale=%-3d" % (f, len(mine), len(miss_cur), miss_dep, len(stale)))
        totals["current_gap"] += len(miss_cur); totals["stale"] += len(stale)
        if miss_cur:
            print("   GAP: " + ", ".join(miss_cur[:20]) + (" ..." if len(miss_cur) > 20 else ""))
        if stale:
            print("   STALE: " + ", ".join(stale[:12]))
    print("\nTOTALS current-gap=%d stale=%d" % (totals["current_gap"], totals["stale"]))
    print("METRICS %d -> %d" % (len(old_metrics), len(new_metrics)))
    mm = {k for k in ours.get("metrics.zig", set()) if "." in k}
    print("metrics.zig: have=%d  current-gap=%d  stale=%d" % (len(mm), len(new_metrics - mm), len(mm - new_metrics)))
    print("  missing: " + ", ".join(sorted(new_metrics - mm)[:12]))
    print("  stale  : " + ", ".join(sorted(mm - new_metrics)[:12]))

    json.dump(new_attrs, open("/var/db/hermes/cache/scratch/semconv_attrs_v145.json", "w"), indent=1)


if __name__ == "__main__":
    main()
