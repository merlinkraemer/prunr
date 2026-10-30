"""Real-data usefulness audit: tag every change-list row with the ways its
drilldown fails to explain the growth, and print counts plus per-row evidence.

Usage: python3 -I scripts/audit/audit.py <slim.db> [--tz Europe/Berlin] [--rows]

Mirrors (see replay.py): GrowthJournalService.changeFeed -> EpisodeBuilder.build,
DatabaseManager.fetchPlaceContents, ChangeFeedDay.groups, FeedPage.soloPlace,
MenuBarManager.soloItemPath. Output paths are shown with the home folder as ~.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict
from datetime import timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import feed_dump  # noqa: E402
import replay  # noqa: E402

GB = 1e9
CLASSES = [
    ("SIZES_NOT_GROWTH", "non-empty page lists sizes only, no per-child change"),
    ("SHRINK", "row is a shrink: the page shows what is left, not what went"),
    ("EMPTY_PAGE", "page is empty (place gone or emptied)"),
    ("NEEDLE", "growth is under 25% of the place now: sizes cannot point at it"),
    ("DEEP", "largest child is a folder bigger than the growth and holds most of the place: growth is below it, app cannot open it"),
    ("REPEATED_PAGE", "same place has several rows, all open the identical page"),
    ("OVERSHOOT", "row says more than the place holds now"),
    ("MOVE_PAIR", "shrink and growth of the same size on the same day, shown as two rows"),
    ("NO_TIME", "only a daily scan saw it: no time on the row, day is the scan day"),
    ("CATCHUP", "scan window over 36 h (Mac was off): row day is the scan day, change spans days"),
    ("FILES_DIRECT", "growth row where files directly in the place hold half the bytes or more"),
    ("MIXED_GROUP", "owner group of the day mixes growth and shrink rows, group amount is the net"),
    ("CATEGORY_GROUP", "owner is a category (generic title) with several rows that day"),
    ("PLACE_NAME", "title is the place fallback or a parent folder used as project name"),
    ("SOLE_CHILD_FINDER", "one child: click jumps to Finder, page never shows"),
    ("EXPLAINED", "page plausibly explains: growth row, one row for the place, a child (or the whole small place) matches the growth"),
]


def tags_for(rows, conn, home):
    root_counts = Counter(r["root"].lower() for r in rows)
    by_day = defaultdict(list)
    for r in rows:
        by_day[r["day"]].append(r)
    groups = defaultdict(list)
    for r in rows:
        groups[(r["day"], r["owner_key"])].append(r)

    for r in rows:
        page = replay.place_contents(conn, r["root"])
        r["page"] = page
        t = set()
        total, kids = page["total"], page["count"]
        top = max(page["all_children"], key=lambda c: c["total"]) if kids else None
        net = r["net"]
        if kids:
            t.add("SIZES_NOT_GROWTH")
        if net < 0:
            t.add("SHRINK")
        if kids == 0:
            t.add("EMPTY_PAGE")
        if net > 0 and total >= 4 * net:
            t.add("NEEDLE")
        if top and top["is_folder"] and top["total"] >= 2 * abs(net) and top["total"] >= 0.5 * total and kids > 1:
            t.add("DEEP")
        if root_counts[r["root"].lower()] > 1:
            t.add("REPEATED_PAGE")
        if net > 0 and net > total * 1.05:
            t.add("OVERSHOOT")
        if r["kind"] == "place" or (r["kind"] == "build-output" and r["title"].endswith(" · dev")):
            t.add("PLACE_NAME")
        if kids == 1 and not page["has_more"]:
            t.add("SOLE_CHILD_FINDER")
        near = [c for c in page["all_children"] if 0.7 * net <= c["total"] <= 1.3 * net]
        if net > 0 and root_counts[r["root"].lower()] == 1 and kids > 0 and (
                near or (total <= 1.3 * net and kids <= 15)):
            t.add("EXPLAINED")
        windows = [(s["first"] - s["observed"]) for s in r["slots"] if s["source"] == "scan" and s["observed"]]
        if windows and max(windows) > timedelta(hours=36):
            t.add("CATCHUP")
        if r["approximate"]:
            t.add("NO_TIME")
        files_bytes = sum(c["total"] for c in page["all_children"] if not c["is_folder"])
        if net > 0 and total and files_bytes >= 0.5 * total:
            t.add("FILES_DIRECT")
        r["tags"] = t

    for members in groups.values():
        signs = {m["net"] > 0 for m in members}
        if len(members) > 1 and len(signs) == 2:
            for m in members:
                m["tags"].add("MIXED_GROUP")
        if len(members) > 1 and members[0]["owner_is_category"]:
            for m in members:
                m["tags"].add("CATEGORY_GROUP")

    for members in by_day.values():
        for a in members:
            for b in members:
                if a is b or a["net"] <= 0 or b["net"] >= 0:
                    continue
                tail = lambda r: r["root"].lower().rsplit("/", 2)[-2:]
                if abs(a["net"] + b["net"]) <= 0.01 * a["net"] and a["unit"] != b["unit"] and tail(a) == tail(b):
                    a["tags"].add("MOVE_PAIR")
                    b["tags"].add("MOVE_PAIR")
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--tz", default="Europe/Berlin")
    ap.add_argument("--rows", action="store_true", help="print the evidence for every row")
    args = ap.parse_args()

    conn, home, tz, slots, rows, week_net, now = feed_dump.load(args.db, args.tz)
    groups = tags_for(rows, conn, home)
    n = len(rows)
    print(f"slots={len(slots)} rows={n} groups={len(groups)} weekNet={week_net / GB:+.2f} GB")
    sources = Counter(s["source"] for s in slots)
    print("slot sources:", dict(sources))
    print()
    total_abs = sum(abs(r["net"]) for r in rows)
    print(f"{'class':20} {'rows':>5} {'share':>6} {'GB':>7} {'GBshare':>8}  meaning")
    for key, meaning in CLASSES:
        tagged = [r for r in rows if key in r["tags"]]
        gb = sum(abs(r["net"]) for r in tagged)
        print(f"{key:20} {len(tagged):5d} {100 * len(tagged) / n:5.0f}% {gb / GB:7.1f} {100 * gb / total_abs:7.0f}%  {meaning}")
    multi = [m for m in groups.values() if len(m) > 1]
    print(f"\nmain-list rows (groups): {len(groups)}; groups with several places: {len(multi)} "
          f"({sum(len(m) for m in multi)} rows); single-place groups open the place page directly: "
          f"{len(groups) - len(multi)}")
    timed = [r for r in rows if not r["approximate"] and r["building_since"] is None]
    print(f"rows that show a time under the title: {len(timed)} of {n}; total |amount| {total_abs / GB:.1f} GB")

    print()
    week_start = replay.local_day(now, tz) - timedelta(days=replay.WEEK_DAYS - 1)
    week_rows = [r for r in rows if r["day"] >= week_start]
    print(f"this week ({week_start:%Y-%m-%d}..): row sum {sum(r['net'] for r in week_rows) / GB:+.2f} GB "
          f"vs header {week_net / GB:+.2f} GB ({len(week_rows)} rows)")
    row_units = {r["unit"] for r in rows}
    week_units = defaultdict(int)
    for s in slots:
        if replay.local_day(s["first"], tz) >= week_start:
            week_units[s["unit"]] += s["net"]
    quiet = {u: v for u, v in week_units.items() if u not in row_units}
    print(f"week places without a row: {len(quiet)} of {len(week_units)}, "
          f"net {sum(quiet.values()) / GB:+.2f} GB, gross {sum(abs(v) for v in quiet.values()) / GB:.2f} GB")

    print()
    print("groups (day, owner): rows, net, positive, negative")
    for (day, owner), members in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1]), reverse=True):
        pos = sum(m["net"] for m in members if m["net"] > 0)
        neg = sum(m["net"] for m in members if m["net"] < 0)
        print(f"  {day:%m-%d} {owner:34} {len(members):2d} {sum(m['net'] for m in members) / GB:+7.2f} "
              f"({pos / GB:+.1f} / {neg / GB:+.1f})")

    kinds = Counter(r["kind"] for r in rows)
    print()
    print("row kinds:", dict(kinds))
    print("owners (rows):", dict(Counter(r["owner_name"] for r in rows).most_common()))

    journal_subs = defaultdict(lambda: defaultdict(int))
    for r in rows:
        for s in r["slots"]:
            journal_subs[r["unit"]][s["sub"] or "-"] += s["net"]
    dominant = 0
    for r in rows:
        subs = journal_subs[r["unit"]]
        total = sum(abs(v) for v in subs.values())
        if len(subs) > 1 and total and max(abs(v) for v in subs.values()) >= 0.7 * total:
            dominant += 1
    print(f"rows whose journal splits growth over several file kinds with one >=70%: {dominant}")

    cover = []
    for r in rows:
        like = r["root"].replace("%", r"\%").replace("_", r"\_") + "/%"
        got = conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(t.sizeBytes),0) FROM workingSetTopEntry t JOIN paths p ON p.id=t.pathId "
            "WHERE p.path LIKE ? ESCAPE '\\'", (like,)).fetchone()
        r["top_files"], r["top_bytes"] = got
        cover.append(got[1] / r["page"]["total"] if r["page"]["total"] else 0)
    have = sum(1 for r in rows if r["top_files"])
    print(f"rows with indexed top files under the place: {have} of {n}; median coverage of place bytes: "
          f"{sorted(cover)[len(cover) // 2]:.0%}")

    if args.rows:
        print()
        for r in sorted(rows, key=lambda r: (r["day"], -abs(r["net"])), reverse=True):
            p = r["page"]
            top = max(p["all_children"], key=lambda c: c["total"]) if p["count"] else None
            print(f"{r['day']:%m-%d} {r['net'] / GB:+7.2f} GB {r['owner_name'][:16]:16} {r['title'][:34]:34} "
                  f"page={p['total'] / GB:7.2f} GB kids={p['count']:3d} "
                  f"top={(top['name'][:18] + ('/' if top['is_folder'] else '')) if top else '-':20} "
                  f"{top['total'] / GB if top else 0:6.2f}  {sorted(r['tags'])}")


if __name__ == "__main__":
    main()
