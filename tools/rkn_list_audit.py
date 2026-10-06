#!/usr/bin/env python3
"""Аудит hostlist-файлов zator: дубли, тени от других списков, базовые домены,
семейства похожих корней, кандидаты в substring-лист.

Usage:
  python tools/rkn_list_audit.py [--repo .] [--out-dir rkn_audit]
      [--fuzzy] [--search СТРОКА] [--min-family 3] [--substring-file FILE]

  --fuzzy       включить нечёткую кластеризацию (нужен pip install rapidfuzz,
                без него — только контейнмент/префиксные семейства)
  --search X    показать все домены листа, содержащие X, и их семейство
  --out-dir     куда писать детальные файлы (по умолчанию rkn_audit/)

Выход: сводка в stdout + файлы в out-dir:
  duplicates.txt, shadowed.txt, base_groups.tsv, families.tsv,
  substring_candidates.txt
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RKN = "extra_strats/TCP/RKN/List.txt"
YT_LISTS = [
    "lists/russia-youtube.txt",
    "lists/russia-youtubeQ.txt",
    "lists/russia-youtube-rtmps.txt",
]
DISCORD = "extra_strats/TCP/RKN/Discord.txt"
CUSTOM = "extra_strats/TCP_Custom.txt"

MULTIPART_TLDS = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "or.jp", "ne.jp",
    "com.au", "net.au", "org.au", "co.nz", "net.nz", "org.nz",
    "com.br", "com.mx", "com.ar", "com.tr", "com.cn", "com.tw",
    "com.hk", "com.sg", "com.ua", "org.ua", "net.ua", "in.ua",
    "co.in", "co.il", "co.za", "com.pl", "com.my", "co.id",
    "com.ph", "com.vn", "com.eg", "com.sa", "com.pk", "com.kz",
    "com.ru", "net.ru", "org.ru", "pp.ru", "msk.ru", "spb.ru",
    "net.ua", "kiev.ua",
}

def load_list(path):
    items, bad = [], []
    full = os.path.join(REPO, path) if not os.path.isabs(path) else path
    if not os.path.exists(full):
        return items, bad
    with open(full, encoding="utf-8", errors="replace") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            s = s.lower().lstrip(".")
            if re.fullmatch(r"[a-z0-9._-]+", s):
                items.append(s)
            else:
                bad.append(s)
    return items, bad

def ancestors(d):
    parts = d.split(".")
    return [".".join(parts[i:]) for i in range(1, len(parts))]

def registrable(d):
    parts = d.split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in MULTIPART_TLDS:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])

def core(d):
    base = registrable(d)
    return base.rsplit(".", 1)[0] if base.count(".") >= 1 else base

class UnionFind:
    def __init__(self):
        self.p = {}
    def find(self, x):
        self.p.setdefault(x, x)
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x
    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[rb] = ra

def ngrams(s, n=5):
    return {s[i:i+n] for i in range(len(s) - n + 1)}

def norm_core(c):
    return c.replace("-", "").replace("_", "")

def norm_core(c):
    return c.replace("-", "").replace("_", "")

def build_families(uniq_cores, fuzzy=False, min_len=6, max_core_len=24):
    """Семейства = контейнмент: ядро A входит в ядро B -> A корень семейства.
    Ищем для каждого ядра самый короткий существующий корень за один проход
    по индексу коротких ядер. Fuzzy-пары (rapidfuzz/difflib) не склеиваются,
    а идут отдельным отчётом: транзитивное замыкание по ratio сливает всё
    в одну кучу."""
    norm_of = {c: norm_core(c) for c in uniq_cores}
    norm_index = defaultdict(list)
    for c, n in norm_of.items():
        if min_len <= len(n) <= max_core_len:
            norm_index[n].append(c)
    uf = UnionFind()
    for c, n in norm_of.items():
        best = None
        ln = len(n)
        for L in range(min_len, min(ln, max_core_len) + 1):
            for i in range(ln - L + 1):
                hit = norm_index.get(n[i:i+L])
                if hit:
                    best = hit[0]
                    break
            if best:
                break
        if best is not None and best != c:
            uf.union(best, c)

    fuzzy_pairs = []
    if fuzzy:
        try:
            from rapidfuzz import fuzz as rf
        except ImportError:
            print("[!] rapidfuzz не установлен (--fuzzy пропущен): pip install rapidfuzz", file=sys.stderr)
        buckets = defaultdict(list)
        for c, n in norm_of.items():
            if len(n) < min_len:
                continue
            for g in ngrams(n, min_len):
                if len(buckets[g]) <= 20:
                    buckets[g].append(c)
        pairs = set()
        for g, items in sorted(buckets.items()):
            if len(items) < 2:
                continue
            items = sorted(set(items))
            for i in range(len(items)):
                for j in range(i + 1, len(items)):
                    pairs.add((items[i], items[j]))
            if len(pairs) > 300000:
                print("[!] fuzzy-пар слишком много, срез по 300k", file=sys.stderr)
                break
        import difflib
        for a, b in pairs:
            na, nb = norm_of[a], norm_of[b]
            if na in nb or nb in na:
                continue
            ratio = rf.ratio(na, nb) if rf is not None else (
                difflib.SequenceMatcher(None, na, nb).ratio() * 100
                if abs(len(na) - len(nb)) <= 3 else 0)
            if ratio >= 87:
                fuzzy_pairs.append((round(ratio), a, b))
    return uf, fuzzy_pairs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="rkn_audit")
    ap.add_argument("--fuzzy", action="store_true")
    ap.add_argument("--search", default=None)
    ap.add_argument("--min-family", type=int, default=3)
    ap.add_argument("--substring-file", default=None)
    args = ap.parse_args()

    rkn, rkn_bad = load_list(RKN)
    yt = []
    for p in YT_LISTS:
        yt.extend(load_list(p)[0])
    discord = load_list(DISCORD)[0]
    custom = load_list(CUSTOM)[0]
    substrings = []
    if args.substring_file:
        substrings = [l.strip().lower() for l in open(args.substring_file, encoding="utf-8", errors="replace")
                      if l.strip() and not l.startswith("#")]

    rkn_set = set(rkn)
    yt_set, discord_set, custom_set = set(yt), set(discord), set(custom)
    print(f"RKN: {len(rkn)} строк ({len(rkn_set)} уникальных, {len(rkn)-len(rkn_set)} дублей-строк)"
          f"{', не-домены: %d' % len(rkn_bad) if rkn_bad else ''}")
    print(f"YT: {len(yt_set)} баз, Discord: {len(discord_set)}, Custom: {len(custom_set)}")

    os.makedirs(args.out_dir, exist_ok=True)

    dup_counts = Counter(rkn)
    dups = {d: c for d, c in dup_counts.items() if c > 1}
    with open(os.path.join(args.out_dir, "duplicates.txt"), "w", encoding="utf-8") as f:
        for d, c in sorted(dups.items()):
            f.write(f"{c}\t{d}\n")
    print(f"\n[1] Точные дубли: {len(dups)} (файл duplicates.txt)")

    shadow_exact, shadow_parent = [], []
    for d in rkn_set:
        if d in yt_set:
            shadow_exact.append((d, "yt"))
        elif d in discord_set:
            shadow_exact.append((d, "discord"))
        elif d in custom_set:
            shadow_exact.append((d, "custom"))
    yt_anc = set()
    for d in yt_set:
        yt_anc.update(ancestors(d))
    for d in rkn_set:
        for a in ancestors(d):
            if a in yt_set:
                shadow_parent.append((d, a, "yt"))
                break
            if a in discord_set:
                shadow_parent.append((d, a, "discord"))
                break
    with open(os.path.join(args.out_dir, "shadowed.txt"), "w", encoding="utf-8") as f:
        for d, w in shadow_exact:
            f.write(f"exact\t{w}\t{d}\n")
        for d, a, w in shadow_parent:
            f.write(f"parent\t{w}\t{d}\t# база {a} в списке {w}\n")
    print(f"[2] Тени: {len(shadow_exact)} точных совпадений + {len(shadow_parent)} поддоменов чужих баз (shadowed.txt)")

    bases = defaultdict(list)
    for d in rkn_set:
        bases[registrable(d)].append(d)
    multi = sorted(((b, ds) for b, ds in bases.items() if len(ds) >= 3),
                   key=lambda x: -len(x[1]))
    with open(os.path.join(args.out_dir, "base_groups.tsv"), "w", encoding="utf-8") as f:
        for b, ds in multi:
            f.write(f"{len(ds)}\t{b}\t{' '.join(sorted(ds))}\n")
    print(f"[3] Баз с 3+ поддоменами: {len(multi)} (base_groups.tsv); топ-5:")
    for b, ds in multi[:5]:
        print(f"      {len(ds)}x {b}")

    core_by_base = {b: core(b) for b in bases}
    uniq_cores = sorted(set(core_by_base.values()))
    uf, fuzzy_pairs = build_families(uniq_cores, fuzzy=args.fuzzy)
    core_members = defaultdict(list)
    for c in uniq_cores:
        core_members[uf.find(c)].append(c)
    doms_by_base = defaultdict(list)
    for d in rkn_set:
        doms_by_base[registrable(d)].append(d)
    base_members = defaultdict(list)
    for b, c in core_by_base.items():
        base_members[uf.find(c)].append(b)
    fam_domains = []
    for root, mem_bases in base_members.items():
        doms = sorted({d for b in mem_bases for d in doms_by_base.get(b, [])})
        if len(doms) >= args.min_family:
            fam_domains.append((sorted(core_members[root]), doms))
    fam_domains.sort(key=lambda x: -len(x[1]))
    with open(os.path.join(args.out_dir, "families.tsv"), "w", encoding="utf-8") as f:
        for members, doms in fam_domains:
            f.write(f"{len(doms)}\t{'/'.join(members[:6])}\t{' '.join(doms)}\n")
    print(f"[4] Семейств похожих корней (>= {args.min_family} доменов): {len(fam_domains)} (families.tsv); топ-5:")
    for members, doms in fam_domains[:5]:
        print(f"      {len(doms)}x {' | '.join(members[:4])}")
    with open(os.path.join(args.out_dir, "fuzzy_pairs.txt"), "w", encoding="utf-8") as f:
        for ratio, a, b in sorted(fuzzy_pairs, reverse=True)[:300]:
            f.write(f"{ratio}\t{a}\t{b}\n")
    print(f"     fuzzy-пары (не склеены, отчёт отдельно): {len(fuzzy_pairs)}")

    covered = []
    if substrings:
        covered = [d for d in rkn_set if any(s in d for s in substrings)]

    def literal_stem(domains, min_len=6):
        """Самая длинная буквальная подстрока, общая для всех доменов:
        substring-матчинг в nfqws2 буквальный, auto-prava не ловится стемом
        autoprava, но ловится стемом prava."""
        regs = sorted(set(domains), key=len)
        a0 = regs[0]
        best = ""
        seen = set()
        for i in range(len(a0) - min_len + 1):
            for j in range(i + min_len, len(a0) + 1):
                s = a0[i:j]
                if s in seen:
                    continue
                seen.add(s)
                if all(s in d for d in regs) and len(s) > len(best):
                    best = s
        return best

    stem_variants = {}
    for members, doms in fam_domains:
        if len(doms) < 5:
            continue
        stem = literal_stem(doms)
        if not stem:
            continue
        variants = {stem}
        for s in (stem[1:], stem[:-1], stem[1:-1]):
            if len(s) >= 6:
                variants.add(s)
        for v in variants:
            stem_variants.setdefault(v, set()).add(stem)

    stems = sorted(stem_variants)
    cnt = {s: 0 for s in stems}
    hit_lists = {s: [] for s in stems}
    try:
        import ahocorasick
        A = ahocorasick.Automaton()
        for s in stems:
            A.add_word(s, s)
        A.make_automaton()
        for d in rkn_set:
            for _, s in A.iter(d):
                cnt[s] += 1
                if len(hit_lists[s]) <= 40:
                    hit_lists[s].append(d)
    except ImportError:
        print("[!] pyahocorasick не установлен, медленный подсчёт: pip install pyahocorasick", file=sys.stderr)
        for d in rkn_set:
            for s in stems:
                if s in d:
                    cnt[s] += 1
                    if len(hit_lists[s]) <= 40:
                        hit_lists[s].append(d)

    covered_by_existing = set()
    if substrings:
        covered_by_existing = {s for s in stems if any(x in s for x in substrings)}
    candidates = []
    for base_stem in {x for vs in stem_variants.values() for x in vs}:
        rows = [(cnt[s], s) for s in stems if base_stem in stem_variants.get(s, set())]
        rows = [r for r in rows if not any(x in r[1] for x in covered_by_existing)]
        if not rows:
            continue
        rows.sort(reverse=True)
        candidates.append((rows[0][0], base_stem, rows))
    candidates.sort(reverse=True)
    with open(os.path.join(args.out_dir, "substring_candidates.txt"), "w", encoding="utf-8") as f:
        for _, base_stem, rows in candidates:
            for n, s in rows:
                f.write(f"{s}\tпокрывает {n}\tсемейство '{base_stem}'\t{' '.join(hit_lists[s])}\n")
            f.write("\n")
    print(f"[5] Кандидатов в substring-лист: {len(candidates)} семейств (substring_candidates.txt, букве в букву); топ-5:")
    for _, base_stem, rows in candidates[:5]:
        top = " / ".join(f"'{s}'={n}" for n, s in rows[:3])
        print(f"      семейство '{base_stem}': {top}")
    print("      (для каждого семейства: точный стем и расширенные варианты с покрытием по всему листу)")

    if args.search:
        q = args.search.lower().replace("-", "").replace("_", "")
        hits = sorted(d for d in rkn_set if q in d.replace("-", "").replace("_", ""))
        print(f"\nПоиск '{q}': {len(hits)} доменов")
        for d in hits[:60]:
            print(f"  {d}")
        if len(hits) > 60:
            print(f"  ... и ещё {len(hits)-60}")

if __name__ == "__main__":
    main()
