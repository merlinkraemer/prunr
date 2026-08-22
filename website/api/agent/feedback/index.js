import { requireAgentAuth } from "../../agent-feedback-auth.js";
import { listFeedback } from "../../feedback-store.js";

const VALID_STATUSES = new Set(["new", "in_progress", "resolved", "ignored"]);

function readPositiveInteger(value, fallback, maximum) {
  if (value == null) return fallback;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 && parsed <= maximum ? parsed : null;
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Method not allowed" });
  }
  if (!requireAgentAuth(req, res)) return;

  const cursor = readPositiveInteger(req.query?.cursor, 0, 10_000);
  const limit = readPositiveInteger(req.query?.limit, 25, 100);
  const status = req.query?.status || null;
  if (cursor == null || limit == null || limit === 0 || (status && !VALID_STATUSES.has(status))) {
    return res.status(400).json({ error: "Invalid cursor, limit, or status." });
  }

  try {
    return res.status(200).json(await listFeedback({ cursor, limit, status }));
  } catch (error) {
    console.error("Feedback agent list failed", error);
    return res.status(503).json({ error: "Feedback storage is unavailable." });
  }
}
