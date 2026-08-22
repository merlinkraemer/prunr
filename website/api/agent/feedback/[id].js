import { requireAgentAuth } from "../../agent-feedback-auth.js";
import { feedbackSummary, getFeedback, updateFeedback } from "../../feedback-store.js";

const ID_RE = /^[0-9a-f-]{36}$/i;
const VALID_STATUSES = new Set(["new", "in_progress", "resolved", "ignored"]);
const MAX_LABELS = 20;
const MAX_LABEL_LENGTH = 64;
const MAX_AGENT_SUMMARY_LENGTH = 10_000;

function parseBody(body) {
  if (typeof body !== "string" && !Buffer.isBuffer(body)) return body;
  try {
    return JSON.parse(body.toString());
  } catch (_) {
    return null;
  }
}

function triageChanges(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const changes = {};
  if (Object.hasOwn(body, "status")) {
    if (!VALID_STATUSES.has(body.status)) return null;
    changes.status = body.status;
  }
  if (Object.hasOwn(body, "labels")) {
    if (!Array.isArray(body.labels) || body.labels.length > MAX_LABELS || body.labels.some((label) => typeof label !== "string" || !label.trim() || label.trim().length > MAX_LABEL_LENGTH)) return null;
    changes.labels = [...new Set(body.labels.map((label) => label.trim()))];
  }
  if (Object.hasOwn(body, "agentSummary")) {
    if (typeof body.agentSummary !== "string" || body.agentSummary.trim().length > MAX_AGENT_SUMMARY_LENGTH) return null;
    changes.agentSummary = body.agentSummary.trim();
  }
  return Object.keys(changes).length > 0 ? changes : null;
}

export default async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "PATCH") {
    res.setHeader("Allow", "GET, PATCH");
    return res.status(405).json({ error: "Method not allowed" });
  }
  if (!requireAgentAuth(req, res)) return;
  const id = req.query?.id;
  if (typeof id !== "string" || !ID_RE.test(id)) return res.status(400).json({ error: "Invalid feedback ID." });

  try {
    if (req.method === "GET") {
      const feedback = await getFeedback(id);
      return feedback ? res.status(200).json({ feedback }) : res.status(404).json({ error: "Feedback not found." });
    }

    const changes = triageChanges(parseBody(req.body));
    if (!changes) return res.status(400).json({ error: "Provide valid status, labels, or agentSummary." });
    const feedback = await updateFeedback(id, changes);
    return feedback ? res.status(200).json({ feedback: feedbackSummary(feedback) }) : res.status(404).json({ error: "Feedback not found." });
  } catch (error) {
    console.error("Feedback agent detail failed", error);
    return res.status(503).json({ error: "Feedback storage is unavailable." });
  }
}
