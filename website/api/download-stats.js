import { downloadStats } from "./download-store.js";

const DEFAULT_DAYS = 30;
const MAX_DAYS = 366;

function readDays(value) {
  if (value == null) return DEFAULT_DAYS;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= MAX_DAYS ? parsed : null;
}

function requireStatsAuth(req, res) {
  const tokens = [process.env.DOWNLOAD_STATS_TOKEN, process.env.FEEDBACK_AGENT_TOKEN].filter(Boolean);
  if (tokens.length === 0) {
    console.error("Download stats API is missing DOWNLOAD_STATS_TOKEN and FEEDBACK_AGENT_TOKEN");
    res.status(503).json({ error: "Download stats API is not configured." });
    return false;
  }
  if (!tokens.some((token) => req.headers.authorization === `Bearer ${token}`)) {
    res.setHeader("WWW-Authenticate", "Bearer");
    res.status(401).json({ error: "Unauthorized." });
    return false;
  }
  return true;
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Method not allowed" });
  }
  if (!requireStatsAuth(req, res)) return;

  const days = readDays(req.query?.days);
  if (days == null) return res.status(400).json({ error: `days must be an integer from 1 to ${MAX_DAYS}.` });

  res.setHeader("Cache-Control", "no-store");
  try {
    return res.status(200).json(await downloadStats({ days }));
  } catch (error) {
    console.error("Download stats failed", error);
    return res.status(503).json({ error: "Download storage is unavailable." });
  }
}
