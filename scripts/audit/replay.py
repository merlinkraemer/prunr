"""Python mirror of the Prunr change feed, for auditing a real DB snapshot.

Each function names the Swift code it mirrors. Read-only: opens the DB with
mode=ro. Run with `python3 -I`.
"""
import re
import sqlite3
from collections import defaultdict
from datetime import datetime, timedelta, timezone

SLOT_SECONDS = 30 * 60
ROW_THRESHOLD = 1_000_000_000
LARGE_GROWTH = 5_000_000_000
HISTORY_DAYS = 30
WEEK_DAYS = 7
MAX_RUN_SLOT_STEP = 2
TRASH_MOVE_PERCENT = 90
APPROX_AFTER = 3600


def connect(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def parse_ts(text):
    return datetime.strptime(text[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)


# DatabaseManager.fetchJournalSlots (DatabaseManager.swift:1951)
def fetch_slots(conn):
    rows = conn.execute(
        """
        SELECT unitKey, category, subcategory, source,
               CAST(CAST(strftime('%s', bucketStart) AS INTEGER) / ? AS INTEGER) AS slot,
               SUM(deltaBytes), SUM(ABS(deltaBytes)), MIN(bucketStart), MIN(observedSince)
        FROM growthJournalBucket
        GROUP BY unitKey, category, subcategory, source, slot
        """,
        (SLOT_SECONDS,),
    ).fetchall()
    return [
        dict(unit=r[0], category=r[1], sub=r[2], source=r[3], slot=r[4], net=r[5], gross=r[6],
             first=parse_ts(r[7]), observed=parse_ts(r[8]) if r[8] else None)
        for r in rows
    ]


# UnitResolver.swift / UnitNamer.swift (UnitKey, sanitize, displayComponent, ...)
def split_unit_key(raw):
    kind, _, root = raw.partition("|")
    return kind, root


def components(path):
    return [p for p in path.split("/") if p and p != "."]


def rel(path, home):
    c, h = components(path), components(home)
    if len(c) >= len(h) and all(a.lower() == b.lower() for a, b in zip(c, h)):
        return c[len(h):]
    return None


BUNDLE_RE = re.compile(
    r"(?i)\b(?:com|org|net|io|group|us|de|co|app|dev|me|company|uk|eu|ch|at|nl|fr|jp|tv|ai)\.[a-z0-9_-]+(?:\.[a-z0-9_-]+)+")
UUID_RE = re.compile(r"[-_.]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
HEX_RE = re.compile(r"[-_.]?[0-9A-Fa-f]{32,}")

KNOWN_APP_NAMES = {
    "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "org.mozilla.firefox": "Firefox",
    "com.microsoft.VSCode": "Visual Studio Code", "com.spotify.client": "Spotify", "com.apple.mail": "Mail",
    "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord", "com.apple.dt.Xcode": "Xcode",
    "com.docker.docker": "Docker", "com.brave.Browser": "Brave", "com.dropbox.Dropbox": "Dropbox",
    "com.notion.id": "Notion", "com.figma.Desktop": "Figma", "us.zoom.xos": "Zoom",
    "org.telegram.desktop": "Telegram", "com.apple.MobileSMS": "Messages", "com.apple.Photos": "Photos",
}


def cache_app_display_name(key):
    if key in KNOWN_APP_NAMES:
        return KNOWN_APP_NAMES[key]
    last = key.split(".")[-1] if key.split(".") else key
    words = last.replace("-", " ").replace("_", " ")
    return words or key


def sanitize(text):
    result = text
    for m in reversed(list(BUNDLE_RE.finditer(result))):
        result = result[:m.start()] + cache_app_display_name(m.group(0)) + result[m.end():]
    result = UUID_RE.sub("", result)
    result = HEX_RE.sub("", result)
    result = result.replace("  ", " ")
    return result.strip(" ·-")


def display_component(component):
    cleaned = sanitize(component)
    if not any(ch.isalpha() or ch.isdigit() for ch in cleaned):
        return None
    if cleaned.startswith(".") and not component.startswith("."):
        return None
    return cleaned


IDENT_EXT = {"plist", "savedstate", "binarycookies", "log", "db", "sqlite", "json", "lock"}
HELPER_SEGMENTS = {"shipit", "shared", "group", "launcher", "renderer", "gpu", "plugin", "xpc", "mac", "desktop", "app"}
HELPER_SUFFIXES = ("helper", "extension", "widget", "agent")


def bare_name(item):
    ident = item
    if ident.lower().startswith("group."):
        ident = ident[len("group."):]
    ident = re.sub(r"^[A-Z0-9]{10}\.", "", ident)
    if "." in ident and ident.rsplit(".", 1)[1].lower() in IDENT_EXT:
        ident = ident.rsplit(".", 1)[0]
    return ident or item


def is_identifier(segments, minimum):
    return len(segments) >= minimum and all(
        s and all(ch.isalnum() or ch in "-_" for ch in s) for s in segments)


def canonical_app_id(item):
    segs = bare_name(item).split(".")
    if not is_identifier(segs, 3):
        return None
    while len(segs) > 3 and (segs[-1].lower() in HELPER_SEGMENTS or segs[-1].lower().endswith(HELPER_SUFFIXES)):
        segs.pop()
    return ".".join(segs)


def app_fallback_name(ident):
    name = cache_app_display_name(ident)
    return name[:1].upper() + name[1:] if name[:1].islower() else name


MACHINE_RELEASE = {"release", "candidate", "rc", "beta", "alpha", "universal", "arm64", "x64", "x86", "intel"}


def is_machine_token(tok):
    low = tok.lower()
    if low in MACHINE_RELEASE:
        return True
    if re.fullmatch(r"v?[0-9]+[a-z]?", low) or re.fullmatch(r"(rc|beta|alpha|b)[0-9]+", low):
        return True
    return len(low) >= 8 and all(c in "0123456789abcdef" for c in low) and any(c.isdigit() for c in low)


def plain_stem(text):
    without = UUID_RE.sub(" ", text)
    tokens = [t for t in re.split(r"[-_. ]", without) if t]
    kept = [t for t in tokens if not is_machine_token(t)]
    if not (len(kept) < len(tokens) or without != text) or not kept:
        return None
    return " ".join(kept)


CATEGORY_NAMES = {
    "developer": "Developer", "audioProduction": "Audio Production", "applications": "Applications",
    "mediaAndDocuments": "Media & Documents", "downloads": "Downloads", "cachesAndSystem": "Apps & System",
    "trash": "Trash", "other": "Other",
}
APP_AREA_TITLES = {
    "application support": "App data", "containers": "App data", "caches": "Cache",
    "group containers": "Shared data", "webkit": "Website data", "httpstorages": "Website data",
    "cookies": "Cookies", "logs": "Logs", "saved application state": "Saved windows",
}
VENDORS = {"google", "adobe", "microsoft", "mozilla", "jetbrains", "epic", "unity"}


class Name:
    def __init__(self, title, owner, category, short=None):
        self.title, self.owner, self.category, self.short = title, owner, category, short


def library_name(root, home, category):
    r = rel(root, home)
    area_owner = ("system", None) if category == "cachesAndSystem" else ("category", category)
    if not r or r[0].lower() != "library":
        return None
    if len(r) < 2:
        return Name("Library files", area_owner, category)
    area = r[1].lower()
    area_name = display_component(r[1]) or "Library files"
    if area == "mail":
        return Name("Mailboxes", ("app", "com.apple.mail"), category)
    if area == "messages":
        return Name("Chat history", ("app", "com.apple.MobileSMS"), category)
    if len(r) < 3:
        return Name(area_name, area_owner, category)
    item = r[2]
    kind_title = APP_AREA_TITLES.get(area)
    if kind_title is None:
        return Name(area_name, area_owner, category)
    title = kind_title
    if len(r) >= 4 and item.lower() in VENDORS and display_component(r[3]):
        owner = ("named", display_component(r[3]), display_component(item))
    elif canonical_app_id(item):
        owner = ("app", canonical_app_id(item))
        if owner[1] == "com.apple.wallpaper":
            title = "Aerial wallpapers"
    elif plain_stem(bare_name(item)):
        stem = plain_stem(bare_name(item))
        owner = ("named", stem, None)
        title = stem
    elif display_component(bare_name(item)):
        owner = ("named", display_component(bare_name(item)), None)
    else:
        return Name(area_name, area_owner, category)
    return Name(title, owner, category)


def place_name(root, home, category):
    parts = rel(root, home)
    outside = parts is None
    if outside:
        parts = components(root)
    readable = [d for d in (display_component(p) for p in parts[-2:]) if d]
    if len(readable) == 2:
        return Name(f"{readable[1]} · {readable[0]}", ("category", category), category, readable[1])
    if len(readable) == 1:
        return Name(readable[0], ("category", category), category)
    return Name("Disk" if outside else "Home folder", ("category", category), category)


def name_unit(raw, home, category):
    """UnitNamer.name(forKey:) for the kinds present in real data. Category is the
    one stored in the journal (the app recomputes it from the path; they agree for
    nearly all units)."""
    kind, root = split_unit_key(raw)
    r = rel(root, home) or []
    dev = ("category", "developer")
    if kind == "trash":
        return Name("Trash", ("category", "trash"), "trash")
    if kind == "download":
        item = r[1] if len(r) >= 2 else None
        for suf in (".crdownload", ".download", ".part"):
            if item and item.lower().endswith(suf) and len(item) > len(suf):
                item = item[:-len(suf)]
        disp = display_component(item) if item else None
        if not disp:
            return Name("Downloads", ("category", "downloads"), "downloads")
        return Name(f"Downloads · {disp}", ("category", "downloads"), "downloads", disp)
    if kind == "library":
        return library_name(root, home, category) or place_name(root, home, category)
    if kind == "steam-game":
        game = display_component(r[5]) if len(r) >= 6 else None
        return Name(game or "Games", ("named", "Steam", None), "applications")
    if kind == "xcode-build":
        proj = None
        if len(r) >= 5 and r[3].lower() == "deriveddata":
            m = re.search(r"-[a-z]{20,}$", r[4])
            proj = display_component(r[4][:m.start()]) if m else None
        elif not (len(r) >= 4 and r[3].lower() == "deriveddata"):
            proj = display_component(r[-1])
        title = f"Xcode build files · {proj}" if proj else "Xcode build files"
        return Name(title, dev, "developer", proj)
    if kind == "xcode-devicesupport":
        return Name("Device support", dev, "developer")
    if kind in ("xcode-archives", "xcode-simulator"):
        return Name("Xcode archives" if kind == "xcode-archives" else "Simulators", dev, "developer")
    if kind in ("python-env", "build-output", "git", "node-modules"):
        titles = {"python-env": ("Python env", "Python environments"), "build-output": ("Build files", "Build files"),
                  "git": ("Git history", "Git history"), "node-modules": ("node_modules", "node_modules")}[kind]
        parts = r if r else components(root)
        project = display_component(parts[-2]) if len(parts) >= 2 else None
        if not project:
            return Name(titles[1], dev, "developer")
        return Name(f"{titles[0]} · {project}", dev, "developer", project)
    if kind == "package-cache":
        first = r[0].lower() if r else ""
        fixed = {".npm": "npm cache", ".gradle": "Gradle cache", ".cargo": "Cargo cache", ".m2": "Maven cache"}
        if first in fixed:
            return Name(fixed[first], dev, "developer")
        tool = display_component(r[1]) if len(r) >= 2 else None
        return Name(f"{tool} cache" if tool else "Cache files", dev, "developer")
    if kind == "model-store":
        return Name("Ollama models" if r and r[0] == ".ollama" else "Hugging Face models", dev, "developer")
    if kind == "tool":
        folder = r[-1] if r else ""
        disp = display_component(folder.lstrip("."))
        if not disp:
            return Name("Tool data", dev, "developer")
        nm = disp[:1].upper() + disp[1:] if len(disp) > 3 else disp
        return Name(f"{nm} data", dev, "developer", nm)
    if kind == "photos-library":
        stem = display_component(components(root)[-1][:-len(".photoslibrary")])
        t = "Photos library" if not stem or stem.lower() in ("photos library", "photos") else f"Photos library · {stem}"
        return Name(t, ("category", "mediaAndDocuments"), "mediaAndDocuments")
    if kind in ("icloud-drive", "icloud-container"):
        return Name("iCloud Drive" if kind == "icloud-drive" else "iCloud", ("category", "mediaAndDocuments"), "mediaAndDocuments")
    if kind == "ableton-project":
        last = components(root)[-1]
        name = display_component(last[:-len(" project")]) if last.lower().endswith(" project") else display_component(last)
        return Name(f"Ableton project · {name}", ("category", "audioProduction"), "audioProduction")
    if kind == "ableton-library":
        return Name("Ableton library", ("category", "audioProduction"), "audioProduction")
    if kind in ("mail-attachments", "messages-attachments"):
        app = "com.apple.mail" if kind == "mail-attachments" else "com.apple.MobileSMS"
        return Name("Attachments", ("app", app), category)
    return place_name(root, home, category)


def resolve_owner(owner):
    """AppCatalog.empty.resolve (AppCatalog.swift:~95): no installed-app catalog, so
    helper ids are not merged into the installed app and unknown names stay split."""
    typ = owner[0]
    if typ == "app":
        if owner[1].lower().startswith("com.apple."):
            return "system", "System"
        return f"app:{owner[1].lower()}", app_fallback_name(owner[1])
    if typ == "named":
        return f"name:{owner[1].lower()}", owner[1]
    if typ == "system":
        return "system", "System"
    return f"category:{owner[1]}", CATEGORY_NAMES[owner[1]]


# EpisodeBuilder.build (EpisodeBuilder.swift:345)
def local_day(moment, tz):
    return moment.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)


def group_by_run_start_day(slots, tz):
    ordered = sorted(slots, key=lambda s: (s["slot"], s["first"]))
    result, run = defaultdict(list), []

    def close():
        if not run:
            return
        start = min(s["first"] for s in run)
        result[local_day(start, tz)].extend(run)
        run.clear()

    for s in ordered:
        if run and s["slot"] - run[-1]["slot"] > MAX_RUN_SLOT_STEP:
            close()
        run.append(s)
    close()
    return result


def build_feed(slots, now, home, tz, categories):
    today = local_day(now, tz)
    oldest = today - timedelta(days=HISTORY_DAYS - 1)
    week_start = today - timedelta(days=WEEK_DAYS - 1)
    trash_growth = defaultdict(int)
    for s in slots:
        if split_unit_key(s["unit"])[0] == "trash":
            trash_growth[s["slot"]] += s["net"]
    trash_growth = {k: v for k, v in trash_growth.items() if v > 0}

    by_unit = defaultdict(list)
    for s in slots:
        by_unit[s["unit"]].append(s)

    week_net = 0
    episodes = []
    for unit, uslots in by_unit.items():
        is_trash = split_unit_key(unit)[0] == "trash"
        count = gross = 0
        count_start = None
        days = sorted((d, v) for d, v in group_by_run_start_day(uslots, tz).items() if d >= oldest)
        for day, dslots in days:
            day_net = sum(s["net"] for s in dslots)
            if day >= week_start:
                week_net += day_net
            counted = sum(min(s["net"], 0) for s in dslots) if is_trash else day_net
            if counted == 0:
                continue
            if count_start is None:
                count_start = day
            count += counted
            gross += sum(s["gross"] for s in dslots)
            if count == 0:
                count_start, gross = None, 0
                continue
            if abs(count) < ROW_THRESHOLD:
                continue
            episodes.append(make_episode(unit, day, dslots, count, gross, count_start, is_trash,
                                         trash_growth, home, categories))
            count = gross = 0
            count_start = None
    return episodes, week_net


def make_episode(unit, day, dslots, net, gross, count_start, is_trash, trash_growth, home, categories):
    by_slot = defaultdict(list)
    for s in dslots:
        by_slot[s["slot"]].append(s)
    net_of_slot = {k: sum(x["net"] for x in v) for k, v in by_slot.items()}
    peak = max(net_of_slot, key=lambda k: (abs(net_of_slot[k]), k))
    peak_slots = by_slot[peak]
    peak_net = net_of_slot[peak]
    time = min(s["first"] for s in peak_slots)
    one_go = count_start == day or abs(peak_net) * 2 > abs(net)

    def approx(s):
        if s["source"] != "scan":
            return False
        if s["observed"] is None:
            return True
        return (s["first"] - s["observed"]).total_seconds() > APPROX_AFTER

    approximate = one_go and all(approx(s) for s in peak_slots)
    nm = name_unit(unit, home, categories.get(unit, "other"))
    title = "Trash emptied" if is_trash else nm.title
    moved_to_trash = False
    if net < 0 and not is_trash:
        trash_in = sum(trash_growth.get(sl, 0) for sl in {s["slot"] for s in dslots})
        moved_to_trash = trash_in * 100 >= -net * TRASH_MOVE_PERCENT
    owner_key, owner_name = resolve_owner(nm.owner)
    kind, root = split_unit_key(unit)
    return dict(
        unit=unit, kind=kind, root=root, day=day, time=time,
        net=net, gross=gross, title=title, category=nm.category, owner_key=owner_key, owner_name=owner_name,
        owner_is_category=owner_key.startswith("category:"), approximate=approximate,
        building_since=None if one_go else count_start, moved_to_trash=moved_to_trash,
        estimated=all(s["source"] == "files" for s in dslots), slots=dslots,
        sources=sorted({s["source"] for s in dslots}),
    )


# DatabaseManager.fetchPlaceContents (DatabaseManager+Drilldown.swift:896), ids.count == 1 path
def place_contents(conn, root, limit=50):
    rows = conn.execute(
        """SELECT name, isFolder, totalBytes, fileCount FROM workingSetPlaceChild
           WHERE unitRoot = ? ORDER BY totalBytes DESC, name LIMIT ?""",
        (root, limit + 1),
    ).fetchall()
    all_rows = conn.execute(
        "SELECT name, isFolder, totalBytes, fileCount FROM workingSetPlaceChild WHERE unitRoot = ?", (root,)
    ).fetchall()
    return dict(
        children=[dict(name=n or root.rsplit("/", 1)[-1], is_folder=bool(f), total=t, files=c)
                  for n, f, t, c in rows[:limit]],
        has_more=len(rows) > limit,
        total=sum(r[2] for r in all_rows), count=len(all_rows),
        all_children=[dict(name=n, is_folder=bool(f), total=t, files=c) for n, f, t, c in all_rows],
    )


def detect_home(conn):
    counts = defaultdict(int)
    for (u,) in conn.execute("SELECT DISTINCT unitKey FROM growthJournalBucket"):
        m = re.match(r"^[a-z-]+\|(/Users/[^/]+)", u)
        if m:
            counts[m.group(1)] += 1
    return max(counts, key=counts.get)


def unit_categories(conn):
    """Most common stored category per unit (the app recomputes it from the path)."""
    rows = conn.execute(
        "SELECT unitKey, category, SUM(ABS(deltaBytes)) w FROM growthJournalBucket GROUP BY unitKey, category").fetchall()
    best = {}
    for u, c, w in rows:
        if u not in best or w > best[u][1]:
            best[u] = (c, w)
    return {u: c for u, (c, _) in best.items()}
