#!/usr/bin/env python3
"""Аудит hostlist-файлов zator: дубли, тени от других списков, базовые домены,
семейства похожих корней, словарь ключевых слов, кандидаты в substring-лист,
генерация xlsx-отчёта.

Usage:
  python tools/rkn_list_audit.py [--repo .] [--out-dir rkn_audit]
      [--fuzzy] [--search СТРОКА] [--min-family 3] [--substring-file FILE]
      [--exclude casino,bet,...] [--xlsx]

  --fuzzy       нечёткие пары в отчёт (нужен rapidfuzz, без него difflib)
  --search X    домены листа, содержащие X (дефисы/подчёркивания игнорируются)
  --exclude     подстроки-фильтры: семейства и ключевые слова с ними уходят
                в excluded-отчёт (мусорные темы типа casino)
  --xlsx        собрать report.xlsx (нужен openpyxl)

Опциональные зависимости: rapidfuzz, pyahocorasick, openpyxl, english-words.
Без них работает всё, кроме ускорений и xlsx.

Выход: сводка в stdout + файлы в out-dir:
  duplicates.txt, shadowed.txt, base_groups.tsv, families.tsv,
  fuzzy_pairs.txt, keywords.tsv, substring_candidates.txt, report.xlsx
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
    "kiev.ua",
}
SUFFIX_LIKE = re.compile(r"\.(com|net|org|gov|edu|ru|ua|uk|co|info|biz|online|store|site|pro|buzz|top|xyz|market|me)\.?$")


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


def norm_core(c):
    return c.replace("-", "").replace("_", "")


def ngrams(s, n=6):
    return {s[i:i + n] for i in range(len(s) - n + 1)}


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


def build_families(uniq_cores, fuzzy=False, min_len=6, max_core_len=24):
    """Семейства = контейнмент: короткое ядро входит в длинное -> корень.
    Fuzzy-пары не склеиваются (транзитивное замыкание сливает всё в кучу),
    а идут отдельным отчётом."""
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
                hit = norm_index.get(n[i:i + L])
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
            rf = None
        if rf is not None:
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
            for a, b in pairs:
                na, nb = norm_of[a], norm_of[b]
                if na in nb or nb in na:
                    continue
                if rf.ratio(na, nb) >= 87:
                    fuzzy_pairs.append((round(rf.ratio(na, nb)), a, b))
    return uf, fuzzy_pairs


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


def tokens_of(core_name):
    return [t for t in re.split(r"[^a-z]+", core_name) if len(t) >= 4]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="rkn_audit")
    ap.add_argument("--fuzzy", action="store_true")
    ap.add_argument("--search", default=None)
    ap.add_argument("--min-family", type=int, default=3)
    ap.add_argument("--substring-file", default=None)
    ap.add_argument("--exclude", default="",
                    help="подстроки-фильтры через запятую (casino,bet,porno,...)")
    ap.add_argument("--xlsx", action="store_true")
    args = ap.parse_args()
    excludes = [x.strip().lower() for x in args.exclude.split(",") if x.strip()]

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
    if excludes:
        print(f"Фильтры исключения: {excludes}")

    os.makedirs(args.out_dir, exist_ok=True)

    dup_counts = Counter(rkn)
    dups = {d: c for d, c in dup_counts.items() if c > 1}
    with open(os.path.join(args.out_dir, "duplicates.txt"), "w", encoding="utf-8") as f:
        for d, c in sorted(dups.items()):
            f.write(f"{c}\t{d}\n")
    print(f"\n[1] Точные дубли: {len(dups)}")

    shadow_exact, shadow_parent = [], []
    for d in rkn_set:
        if d in yt_set:
            shadow_exact.append((d, "yt"))
        elif d in discord_set:
            shadow_exact.append((d, "discord"))
        elif d in custom_set:
            shadow_exact.append((d, "custom"))
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
    print(f"[2] Тени: {len(shadow_exact)} точных + {len(shadow_parent)} поддоменов чужих баз")

    doms_by_base = defaultdict(list)
    for d in rkn_set:
        doms_by_base[registrable(d)].append(d)
    bases = set(doms_by_base)
    multi = sorted(((b, ds) for b, ds in doms_by_base.items() if len(ds) >= 3),
                   key=lambda x: -len(x[1]))
    with open(os.path.join(args.out_dir, "base_groups.tsv"), "w", encoding="utf-8") as f:
        for b, ds in multi:
            f.write(f"{len(ds)}\t{b}\t{' '.join(sorted(ds))}\n")
    print(f"[3] Баз с 3+ поддоменами: {len(multi)}; топ-5:")
    for b, ds in multi[:5]:
        print(f"      {len(ds)}x {b}")

    core_by_base = {b: core(b) for b in bases}
    uniq_cores = sorted(set(core_by_base.values()))
    uf, fuzzy_pairs = build_families(uniq_cores, fuzzy=args.fuzzy)
    core_members = defaultdict(list)
    for c in uniq_cores:
        core_members[uf.find(c)].append(c)
    base_members = defaultdict(list)
    for b, c in core_by_base.items():
        base_members[uf.find(c)].append(b)
    fam_domains = []
    for root, mem_bases in base_members.items():
        doms = sorted({d for b in mem_bases for d in doms_by_base.get(b, [])})
        if len(doms) >= args.min_family:
            fam_domains.append((root, sorted(core_members[root]), doms))
    fam_domains.sort(key=lambda x: -len(x[1]))
    fam_excluded, fam_kept = [], []
    for root, members, doms in fam_domains:
        (fam_excluded if any(x in root for x in excludes) else fam_kept).append((root, members, doms))
    with open(os.path.join(args.out_dir, "families.tsv"), "w", encoding="utf-8") as f:
        for root, members, doms in fam_kept:
            f.write(f"{len(doms)}\t{'/'.join(members[:6])}\t{' '.join(doms)}\n")
    with open(os.path.join(args.out_dir, "families_excluded.tsv"), "w", encoding="utf-8") as f:
        for root, members, doms in fam_excluded:
            f.write(f"{len(doms)}\t{'/'.join(members[:6])}\t{' '.join(doms)}\n")
    print(f"[4] Семейств (>= {args.min_family} доменов): {len(fam_kept)} + исключено фильтрами {len(fam_excluded)}; топ-5:")
    for root, members, doms in fam_kept[:5]:
        print(f"      {len(doms)}x {' | '.join(members[:4])}")
    with open(os.path.join(args.out_dir, "fuzzy_pairs.txt"), "w", encoding="utf-8") as f:
        for ratio, a, b in sorted(fuzzy_pairs, reverse=True)[:300]:
            f.write(f"{ratio}\t{a}\t{b}\n")
    print(f"     fuzzy-пары (не склеены): {len(fuzzy_pairs)}")

    covered_by_existing = set(substrings)

    stem_variants = {}
    for root, members, doms in fam_kept:
        if len(doms) < 5:
            continue
        stem = literal_stem(doms)
        if not stem or any(x in stem for x in excludes):
            continue
        variants = {stem} | {s for s in (stem[1:], stem[:-1]) if len(s) >= 6}
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
                if len(hit_lists[s]) <= 25:
                    hit_lists[s].append(d)
    except ImportError:
        print("[!] pyahocorasick не установлен, медленный подсчёт: pip install pyahocorasick", file=sys.stderr)
        for d in rkn_set:
            for s in stems:
                if s in d:
                    cnt[s] += 1
                    if len(hit_lists[s]) <= 25:
                        hit_lists[s].append(d)

    candidates = []
    for base_stem in {x for vs in stem_variants.values() for x in vs}:
        rows = [(cnt[s], s) for s in stems
                if base_stem in stem_variants.get(s, set())
                and not any(x in s for x in covered_by_existing)]
        if not rows:
            continue
        rows.sort(key=lambda r: (-len(r[1]), -r[0]))
        informative = []
        prev = None
        for n, s in rows:
            if prev is None or n > prev:
                informative.append((n, s))
                prev = n
        if informative:
            candidates.append((informative[0][0], base_stem, informative))
    candidates.sort(reverse=True)
    cand_excluded = [c for c in candidates if any(x in c[1] for x in excludes)]
    cand_kept = [c for c in candidates if not any(x in c[1] for x in excludes)]
    with open(os.path.join(args.out_dir, "substring_candidates.txt"), "w", encoding="utf-8") as f:
        for _, base_stem, rows in cand_kept:
            for n, s in rows:
                flag = "\t!!! суффикс-подобный, в подстроки не добавлять" if SUFFIX_LIKE.search(s) else ""
                f.write(f"{s}\tпокрывает {n}\tсемейство '{base_stem}'\t{' '.join(hit_lists[s])}{flag}\n")
            f.write("\n")
    with open(os.path.join(args.out_dir, "substring_candidates_excluded.txt"), "w", encoding="utf-8") as f:
        for _, base_stem, rows in cand_excluded:
            for n, s in rows:
                f.write(f"{s}\tпокрывает {n}\tсемейство '{base_stem}'\t{' '.join(hit_lists[s])}\n")
            f.write("\n")
    print(f"[5] Кандидатов в substring-лист: {len(cand_kept)} семейств"
          f" (+{len(cand_excluded)} отфильтровано); топ-5:")
    for _, base_stem, rows in cand_kept[:5]:
        top = " / ".join(f"'{s}'={n}" for n, s in rows[:3])
        print(f"      семейство '{base_stem}': {top}")

    eng = set()
    try:
        from english_words import get_english_words_set
        eng = {w.lower() for w in get_english_words_set(["web2"], lower=True)}
    except ImportError:
        print("[!] english-words не установлен — колонка 'english' пустует: pip install english-words", file=sys.stderr)
    kw_counter = Counter()
    kw_examples = defaultdict(list)
    for b, c in core_by_base.items():
        for t in tokens_of(c):
            kw_counter[t] += 1
            if len(kw_examples[t]) < 12:
                kw_examples[t].append(doms_by_base[b][0])
    kw_rows, kw_excluded = [], []
    for t, n in kw_counter.most_common():
        row = (t, n, "yes" if (eng and t in eng) else "", " ".join(kw_examples[t][:8]))
        if excludes and any(x in t for x in excludes):
            kw_excluded.append(row)
        else:
            kw_rows.append(row)
    with open(os.path.join(args.out_dir, "keywords.tsv"), "w", encoding="utf-8") as f:
        f.write("keyword\tbases\tenglish\texamples\n")
        for t, n, e, ex in kw_rows:
            f.write(f"{t}\t{n}\t{e}\t{ex}\n")
    with open(os.path.join(args.out_dir, "keywords_excluded.tsv"), "w", encoding="utf-8") as f:
        f.write("keyword\tbases\tenglish\texamples\n")
        for t, n, e, ex in kw_excluded:
            f.write(f"{t}\t{n}\t{e}\t{ex}\n")
    print(f"[6] Ключевых слов: {len(kw_rows)} (+{len(kw_excluded)} отфильтровано); английских: "
          f"{sum(1 for r in kw_rows if r[2])}; топ-10:")
    for t, n, e, _ in kw_rows[:10]:
        print(f"      {t} = {n}{' *' if e else ''}")

    if args.search:
        q = args.search.lower().replace("-", "").replace("_", "")
        hits = sorted(d for d in rkn_set if q in d.replace("-", "").replace("_", ""))
        print(f"\nПоиск '{q}': {len(hits)} доменов")
        for d in hits[:60]:
            print(f"  {d}")
        if len(hits) > 60:
            print(f"  ... и ещё {len(hits)-60}")

    if args.xlsx:
        try:
            from openpyxl import Workbook
            from openpyxl.styles import Font
            from openpyxl.utils import get_column_letter
        except ImportError:
            print("[!] openpyxl не установлен: pip install openpyxl", file=sys.stderr)
            return
        wb = Workbook()
        hdr = Font(bold=True)

        def sheet(name, header, rows, widths):
            ws = wb.create_sheet(name)
            ws.append(list(header))
            for c in ws[1]:
                c.font = hdr
            for r in rows:
                ws.append(list(r))
            for i, w in enumerate(widths, 1):
                ws.column_dimensions[get_column_letter(i)].width = w
            ws.freeze_panes = "A2"
            return ws

        ws = wb.active
        ws.title = "Summary"
        for k, v in [
            ("RKN строк", len(rkn)), ("уникальных", len(rkn_set)), ("дублей", len(dups)),
            ("теней точных", len(shadow_exact)), ("теней-поддоменов", len(shadow_parent)),
            ("баз с 3+ поддоменами", len(multi)),
            ("семейств", len(fam_kept)), ("семейств отфильтровано", len(fam_excluded)),
            ("substring-кандидатов", len(cand_kept)), ("ключевых слов", len(kw_rows)),
        ]:
            ws.append([k, v])
        ws.column_dimensions["A"].width = 28

        sheet("Duplicates", ("count", "domain"), sorted(dups.items()), [8, 40])
        sheet("Shadowed", ("type", "list", "domain", "note"),
              [(t, w, d, "") for d, w in shadow_exact] + [(t, w, d, f"база {a}") for d, a, w in shadow_parent],
              [8, 10, 42, 24])
        sheet("BaseGroups", ("subdomains", "base", "domains"),
              [(len(ds), b, " ".join(sorted(ds))) for b, ds in multi], [11, 24, 120])
        sheet("Families", ("domains", "cores", "all_domains"),
              [(len(d), "/".join(m[:6]), " ".join(d)) for r, m, d in fam_kept], [9, 40, 120])
        sheet("SubstringCandidates", ("stem", "coverage", "family", "sample_domains"),
              [(s, n, fam, " ".join(hit_lists[s][:25]))
               for _, fam, rows in cand_kept for n, s in rows], [20, 10, 24, 100])
        sheet("Keywords", ("keyword", "bases", "english", "examples"),
              kw_rows, [20, 8, 9, 80])
        sheet("ExcludedKeywords", ("keyword", "bases", "english", "examples"),
              kw_excluded, [20, 8, 9, 80])
        wb.save(os.path.join(args.out_dir, "report.xlsx"))
        print(f"\nXLSX: {os.path.join(args.out_dir, 'report.xlsx')}")


if __name__ == "__main__":
    main()
