#!/usr/bin/env bash
set -euo pipefail

MAC_HOST=${MAC_HOST:-mbp}
REMOTE_DIR=${REMOTE_DIR:-/tmp/PrunrSnapshots}
DEST=${1:-$HOME/dev/projects/prunr-data/review}

mkdir -p "$DEST"
rsync -a --delete "$MAC_HOST:$REMOTE_DIR/" "$DEST/"

python3 -I - "$DEST" <<'PY'
import html, os, sys, time

dest = sys.argv[1]
sections = []
for name in sorted(os.listdir(dest)):
    folder = os.path.join(dest, name)
    if not os.path.isdir(folder):
        continue
    pngs = sorted(f for f in os.listdir(folder) if f.endswith(".png"))
    docs = sorted(f for f in os.listdir(folder) if f.endswith((".txt", ".json")))
    cards = "".join(
        f'<figure><a href="{name}/{p}"><img loading="lazy" src="{name}/{p}"></a>'
        f"<figcaption>{html.escape(p[:-4])}</figcaption></figure>"
        for p in pngs
    )
    links = " ".join(f'<a href="{name}/{d}">{html.escape(d)}</a>' for d in docs)
    sections.append(f"<h2>{html.escape(name)}</h2><p>{links}</p><div class=grid>{cards}</div>")

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Prunr snapshots</title>
<style>
:root {{ color-scheme: light dark; }}
body {{ font: 15px -apple-system, system-ui, sans-serif; margin: 0; padding: 16px; }}
h1 {{ font-size: 20px; }} h2 {{ font-size: 16px; margin-top: 28px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 12px; }}
figure {{ margin: 0; }} img {{ width: 100%; height: auto; border-radius: 8px; }}
figcaption {{ font-size: 12px; opacity: .7; text-align: center; }}
</style></head><body>
<h1>Prunr snapshots</h1>
<p>Fetched {time.strftime("%Y-%m-%d %H:%M")}</p>
{"".join(sections) or "<p>No snapshots yet.</p>"}
</body></html>
"""
with open(os.path.join(dest, "index.html"), "w") as handle:
    handle.write(page)
PY
echo "snapshots: $DEST/index.html"
