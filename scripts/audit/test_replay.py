"""Tests for replay.py's checkpoint carries and window-slide check, on synthetic journals."""
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

import replay

TZ = timezone.utc
HOME = "/Users/tester"
MB = 1_000_000
GB = 1_000_000_000
DAY0 = datetime(2026, 1, 1, 12, 0, tzinfo=TZ)


def build_db(path, rows):
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE growthJournalBucket (
               unitKey TEXT NOT NULL, category TEXT NOT NULL, subcategory TEXT,
               source TEXT NOT NULL, bucketStart DATETIME NOT NULL,
               deltaBytes INTEGER NOT NULL, observedSince DATETIME)"""
    )
    conn.executemany(
        "INSERT INTO growthJournalBucket VALUES (?, ?, NULL, ?, ?, ?, ?)",
        [(u, c, s, t.strftime("%Y-%m-%d %H:%M:%S"), d, t.strftime("%Y-%m-%d %H:%M:%S"))
         for u, c, s, t, d in rows],
    )
    conn.commit()
    conn.close()


def daily(unit, category, source, start_offset, days, delta):
    return [(unit, category, source, DAY0 + timedelta(days=start_offset + i), delta(i)) for i in range(days)]


GROWER = f"tool|{HOME}/.slowgrower"
BURSTY = f"tool|{HOME}/.bursty"
SHRINKER = f"tool|{HOME}/.shrinker"
TRASH = "trash|" + HOME + "/.Trash"


class ReplayTestCase(unittest.TestCase):
    def load(self, rows):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = os.path.join(directory.name, "journal.db")
        build_db(path, rows)
        conn = replay.connect(path)
        self.addCleanup(conn.close)
        return replay.fetch_slots(conn), replay.unit_categories(conn)

    def now(self, offset):
        return DAY0 + timedelta(days=offset)


class SlideTests(ReplayTestCase):
    def setUp(self):
        self.rows = daily(GROWER, "developer", "files", 0, 110, lambda i: 250 * MB)
        self.slots, self.categories = self.load(self.rows)
        self.first, self.last = self.now(45), self.now(105)

    def test_without_checkpoints_slow_grower_rows_shift(self):
        changes, units = replay.slide_check(self.slots, self.first, self.last, HOME, TZ, self.categories, False)
        self.assertGreater(changes, 0)
        self.assertEqual(units, {GROWER})

    def test_with_checkpoints_no_in_window_row_changes(self):
        self.assertGreaterEqual((self.last - self.first).days, 60)
        changes, units = replay.slide_check(self.slots, self.first, self.last, HOME, TZ, self.categories, True)
        self.assertEqual(changes, 0)
        self.assertEqual(units, set())

    def test_every_fourth_day_is_a_row_with_full_history(self):
        episodes, _ = replay.build_feed(self.slots, self.now(60), HOME, TZ, self.categories)
        days = sorted((e["day"] - replay.local_day(DAY0, TZ)).days for e in episodes)
        self.assertEqual([d % 4 for d in days], [3] * len(days))
        self.assertTrue(all(e["net"] == GB for e in episodes))


class CheckpointedEqualsFullHistoryTests(ReplayTestCase):
    def test_every_day_matches_full_history(self):
        rows = (
            daily(GROWER, "developer", "files", 0, 100, lambda i: 120 * MB)
            + daily(BURSTY, "developer", "scan", 0, 100, lambda i: 2 * GB if i % 17 == 0 else 30 * MB)
            + daily(SHRINKER, "developer", "files", 0, 100, lambda i: 400 * MB if i < 20 else -180 * MB)
            + daily(TRASH, "trash", "files", 0, 100, lambda i: (900 * MB if i % 9 == 0 else -350 * MB))
        )
        slots, categories = self.load(rows)
        carries, folded_until = {}, None
        mismatches = 0
        compared = 0
        for offset in range(40, 100):
            now = self.now(offset)
            oldest = replay.local_day(now, TZ) - timedelta(days=replay.HISTORY_DAYS - 1)
            todo = [s for s in slots if s["first"] < oldest and (folded_until is None or s["first"] >= folded_until)]
            carries = replay.prune_carries(carries, todo, oldest, TZ)
            folded_until = oldest
            visible = [s for s in slots if oldest <= s["first"] < now + timedelta(days=1)]
            episodes, _ = replay.build_feed(visible, now, HOME, TZ, categories, carries)
            checkpointed = {replay.row_key(e) for e in episodes}
            full = replay.full_history_rows(slots, now, HOME, TZ, categories)
            mismatches += len(checkpointed ^ full)
            compared += len(full)
        self.assertGreater(compared, 0)
        self.assertEqual(mismatches, 0)


class CrossingAndExpiryTests(ReplayTestCase):
    def slots_for(self, deltas, unit=GROWER):
        rows = [(unit, "developer", "files", DAY0 + timedelta(days=i), d) for i, d in enumerate(deltas)]
        slots, _ = self.load(rows)
        return slots

    def days_of(self, slots):
        return replay.group_by_run_start_day([s for s in slots], TZ)

    def test_crossing_at_one_gb_emits_and_resets(self):
        slots = self.slots_for([400 * MB, 400 * MB, 200 * MB, 100 * MB])
        state, crossings, pending = replay.fold(None, self.days_of(slots), False)
        self.assertEqual(len(crossings), 1)
        day, _, count, gross, start = crossings[0]
        self.assertEqual(count, GB)
        self.assertEqual(gross, GB)
        self.assertEqual(start, replay.local_day(DAY0, TZ))
        self.assertEqual(day, replay.local_day(DAY0 + timedelta(days=2), TZ))
        self.assertEqual(state["count"], 100 * MB)
        self.assertEqual(state["start"], replay.local_day(DAY0 + timedelta(days=3), TZ))

    def test_just_under_threshold_does_not_cross(self):
        slots = self.slots_for([999_999_999])
        state, crossings, _ = replay.fold(None, self.days_of(slots), False)
        self.assertEqual(crossings, [])
        self.assertEqual(state["count"], 999_999_999)

    def test_negative_crossing_resets(self):
        slots = self.slots_for([-600 * MB, -600 * MB, -50 * MB])
        state, crossings, _ = replay.fold(None, self.days_of(slots), False)
        self.assertEqual([c[2] for c in crossings], [-1_200 * MB])
        self.assertEqual(state["count"], -50 * MB)

    def test_carry_seeds_the_next_crossing(self):
        carry = dict(count=900 * MB, gross=900 * MB, start=replay.local_day(DAY0, TZ) - timedelta(days=5),
                     last=replay.local_day(DAY0, TZ) - timedelta(days=1))
        slots = self.slots_for([200 * MB])
        state, crossings, _ = replay.fold(carry, self.days_of(slots), False)
        self.assertEqual(len(crossings), 1)
        self.assertEqual(crossings[0][2], 1_100 * MB)
        self.assertEqual(crossings[0][4], carry["start"])
        self.assertEqual(state["count"], 0)
        self.assertIsNone(state["start"])

    def test_count_back_to_zero_resets_start(self):
        slots = self.slots_for([300 * MB, -300 * MB])
        state, crossings, _ = replay.fold(None, self.days_of(slots), False)
        self.assertEqual(crossings, [])
        self.assertEqual(state["count"], 0)
        self.assertIsNone(state["start"])
        self.assertEqual(state["gross"], 0)

    def test_trash_counts_shrinks_only(self):
        rows = [(TRASH, "trash", "files", DAY0 + timedelta(days=i), d) for i, d in enumerate([5 * GB, -400 * MB])]
        slots, _ = self.load(rows)
        state, _, _ = replay.fold(None, self.days_of(slots), True)
        self.assertEqual(state["count"], -400 * MB)

    def carry(self, last_day, count=300 * MB):
        return dict(count=count, gross=count, start=last_day, last=last_day)

    def test_expiry_drops_carry_older_than_90_days(self):
        cutoff = replay.local_day(DAY0, TZ) + timedelta(days=200)
        stale = self.carry(cutoff - timedelta(days=91))
        edge = self.carry(cutoff - timedelta(days=90))
        fresh = self.carry(cutoff - timedelta(days=5))
        kept = replay.prune_carries({"stale": stale, "edge": edge, "fresh": fresh}, [], cutoff, TZ)
        self.assertEqual(set(kept), {"edge", "fresh"})

    def test_zero_counts_are_not_stored(self):
        cutoff = replay.local_day(DAY0, TZ) + timedelta(days=10)
        slots = self.slots_for([300 * MB, -300 * MB])
        kept = replay.prune_carries({}, slots, cutoff, TZ)
        self.assertNotIn(GROWER, kept)

    def test_prune_folds_slots_into_carry_and_keeps_last_active_day(self):
        cutoff = replay.local_day(DAY0, TZ) + timedelta(days=10)
        slots = self.slots_for([300 * MB, 300 * MB, 0, 100 * MB])
        kept = replay.prune_carries({}, slots, cutoff, TZ)
        self.assertEqual(kept[GROWER]["count"], 700 * MB)
        self.assertEqual(kept[GROWER]["last"], replay.local_day(DAY0 + timedelta(days=3), TZ))

    def test_woken_place_after_expiry_starts_from_zero(self):
        old = self.slots_for([500 * MB])
        wake_day = replay.local_day(DAY0, TZ) + timedelta(days=130)
        cutoff = wake_day - timedelta(days=29)
        carries = replay.prune_carries({}, old, DAY0 + timedelta(days=1), TZ)
        self.assertIn(GROWER, carries)
        carries = replay.prune_carries(carries, [], cutoff, TZ)
        self.assertNotIn(GROWER, carries)


if __name__ == "__main__":
    unittest.main()
