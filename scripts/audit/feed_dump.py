"""Print the reconstructed change feed. Usage: python3 -I scripts/audit/feed_dump.py <db> [--tz Europe/Berlin]"""
import argparse
import os
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay  # noqa: E402


def load(db, tz_name="Europe/Berlin", now=None):
    conn = replay.connect(db)
    home = replay.detect_home(conn)
    tz = ZoneInfo(tz_name)
    slots = replay.fetch_slots(conn)
    cats = replay.unit_categories(conn)
    if now is None:
        now = datetime.fromtimestamp(os.path.getmtime(db), tz=timezone.utc)
    episodes, week_net = replay.build_feed(slots, now, home, tz, cats)
    return conn, home, tz, slots, episodes, week_net, now


def tilde(path, home):
    return "~" + path[len(home):] if path.startswith(home) else path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--tz", default="Europe/Berlin")
    args = ap.parse_args()
    conn, home, tz, slots, episodes, week_net, _ = load(args.db, args.tz)
    print(f"home={home} slots={len(slots)} rows={len(episodes)} weekNet={week_net / 1e9:.2f} GB")
    for e in sorted(episodes, key=lambda e: (e["day"], -abs(e["net"])), reverse=True):
        building = e["building_since"].strftime("%d") if e["building_since"] else "-"
        print(f"{e['day']:%Y-%m-%d} {e['owner_name'][:20]:20} {e['title'][:42]:42} {e['net'] / 1e9:+8.2f} GB "
              f"{','.join(e['sources']):10} bld={building} {tilde(e['root'], home)}")


if __name__ == "__main__":
    main()
