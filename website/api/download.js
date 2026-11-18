import { recordDownload } from "./download-store.js";

const REPO = "merlinkraemer/prunr";
export const FALLBACK_URL = `https://github.com/${REPO}/releases/latest`;
const RELEASE_CACHE_MS = 5 * 60 * 1000;
const RELEASE_LOOKUP_TIMEOUT_MS = 3_000;

const SRC_RE = /^[a-z0-9_-]{1,32}$/;
const HOSTNAME_RE = /^[a-z0-9.-]{1,253}$/;
const BOT_RE = /bot|crawl|spider|preview|facebookexternalhit|slack|discord|telegram|whatsapp|curl|wget|python|go-http/i;
const IOS_RE = /iPhone|iPad|iPod/;
const MAC_RE = /Macintosh|Mac OS X/;
const BREW_RE = /^Homebrew\//;
const VERSION_RE = /^\d+(?:\.\d+)+(?:-[a-z]+\.\d+)?$/;
const BUILD_RE = /^\d{1,6}$/;

let cachedRelease = null;

export function resetReleaseCache() {
  cachedRelease = null;
}

function pickAsset(assets) {
  return assets.find((asset) => /-macos\.dmg$/i.test(asset.name))
    || assets.find((asset) => /-macos\.zip$/i.test(asset.name) && !/dsym/i.test(asset.name));
}

export function pinnedDownloadUrl(version, build) {
  if (typeof version !== "string" || typeof build !== "string") return null;
  if (!VERSION_RE.test(version) || !BUILD_RE.test(build)) return null;
  return `https://github.com/${REPO}/releases/download/v${version}/Prunr-${version}-build${build}-macos.dmg`;
}

async function latestDownloadUrl() {
  if (cachedRelease && cachedRelease.expiresAt > Date.now()) return cachedRelease.url;
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "prunr-web" },
      signal: AbortSignal.timeout(RELEASE_LOOKUP_TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`GitHub releases lookup failed (${response.status}).`);
    const asset = pickAsset((await response.json()).assets || []);
    if (!asset) throw new Error("Latest release has no macOS DMG or ZIP asset.");
    cachedRelease = { url: asset.browser_download_url, expiresAt: Date.now() + RELEASE_CACHE_MS };
    return cachedRelease.url;
  } catch (error) {
    console.error("Download release lookup failed", error);
    return FALLBACK_URL;
  }
}

export function sourceTag(value) {
  if (value == null || value === "") return "direct";
  const src = String(value).toLowerCase();
  return SRC_RE.test(src) ? src : "other";
}

export function referrerHost(value) {
  if (typeof value !== "string" || value === "") return "none";
  try {
    const host = new URL(value).hostname.toLowerCase();
    return HOSTNAME_RE.test(host) ? host : "other";
  } catch (_) {
    return "other";
  }
}

export function userAgentClass(value) {
  if (typeof value !== "string" || value === "") return "other";
  if (BREW_RE.test(value)) return "brew";
  if (BOT_RE.test(value)) return "bot";
  if (IOS_RE.test(value)) return "other";
  return MAC_RE.test(value) ? "mac" : "other";
}

export default async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const pinned = pinnedDownloadUrl(req.query?.v, req.query?.b);
  const ua = userAgentClass(req.headers?.["user-agent"]);
  const counts = req.method === "GET" || ua === "brew";
  const [target] = await Promise.all([
    pinned ?? latestDownloadUrl(),
    counts
      ? recordDownload({
        at: new Date().toISOString(),
        src: sourceTag(req.query?.src),
        ref: referrerHost(req.headers?.referer),
        ua,
      }).catch((error) => console.error("Download count failed", error))
      : null,
  ]);

  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Location", target);
  return res.status(302).end();
}
