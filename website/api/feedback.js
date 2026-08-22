// Vercel serverless function — relays in-app alpha feedback to Merlin through
// Brevo. The client is the macOS app, so this endpoint intentionally has no
// browser-origin policy. A shared token only deters casual unsolicited traffic;
// it is not a substitute for user authentication.

import { checkSubmissionRateLimit, createFeedback, updateNotificationStatus } from "./feedback-store.js";

const DEFAULT_NOTIFY_EMAIL = "merlinkraemer@gmail.com";
const DEFAULT_SHARED_TOKEN = "prunr-alpha-feedback-v1";

const MAX_BODY_BYTES = 350 * 1024;
const MAX_DIAGNOSTICS_BYTES = 200 * 1024;
const MAX_MESSAGE_LENGTH = 10_000;
const MAX_APP_VERSION_LENGTH = 128;
const MAX_MACOS_VERSION_LENGTH = 64;
const MAX_INSTALL_ID_LENGTH = 64;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export const config = {
  api: {
    bodyParser: { sizeLimit: "350kb" },
  },
};

function brevoHeaders(apiKey) {
  return {
    "api-key": apiKey,
    "content-type": "application/json",
    accept: "application/json",
  };
}

function senderConfig() {
  const senderEmail = process.env.BREVO_SENDER_EMAIL;
  if (!senderEmail) return null;
  return { name: process.env.BREVO_SENDER_NAME || "Merlin", email: senderEmail };
}

function requestIp(req) {
  const forwarded = req.headers?.["x-forwarded-for"];
  if (typeof forwarded !== "string") return "unknown";
  const ip = forwarded.split(",", 1)[0].trim();
  return /^[0-9a-f:.]{1,64}$/i.test(ip) ? ip : "unknown";
}

function bodyByteLength(body) {
  if (typeof body === "string") return Buffer.byteLength(body, "utf8");
  if (Buffer.isBuffer(body)) return body.length;
  return Buffer.byteLength(JSON.stringify(body ?? {}), "utf8");
}

function parseBody(body) {
  if (typeof body !== "string" && !Buffer.isBuffer(body)) return body;
  try {
    return JSON.parse(body.toString());
  } catch (_) {
    return null;
  }
}

function readString(value, maxLength) {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length > 0 && result.length <= maxLength ? result : null;
}

function decodeDiagnostics(value) {
  if (value == null) return { attachment: null };
  if (typeof value !== "string" || value.length === 0 || !BASE64_RE.test(value)) {
    return { error: "Diagnostics must be base64 encoded." };
  }

  const content = Buffer.from(value, "base64");
  // Buffer.from is deliberately permissive, so make a round-trip check before
  // accepting an attachment. This also avoids treating malformed input as a log.
  if (content.toString("base64") !== value || content.length > MAX_DIAGNOSTICS_BYTES) {
    return { error: "Diagnostics attachment is invalid or too large." };
  }

  return {
    attachment: {
      content: value,
      // Brevo rejects .log attachments ("Unsupported file format"); txt is allowed.
      name: "prunr-diagnostics.txt",
    },
  };
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function emailPayload({ sender, notifyEmail, message, email, appVersion, macOSVersion, installId, attachment, receivedAt }) {
  const diagnosticsStatus = attachment ? "Attached" : "Not included";
  const replyToLine = email || "Not supplied";
  const textContent = [
    "Prunr alpha feedback",
    "",
    "Message:",
    message,
    "",
    "App version: " + appVersion,
    "macOS version: " + macOSVersion,
    "Install UUID: " + installId,
    "Diagnostics: " + diagnosticsStatus,
    "Reply-to email: " + replyToLine,
    "Received: " + receivedAt,
  ].join("\n");

  const payload = {
    sender,
    to: [{ email: notifyEmail }],
    subject: "Prunr alpha feedback — " + appVersion + " / macOS " + macOSVersion,
    textContent,
    htmlContent: [
      "<p><strong>Prunr alpha feedback</strong></p>",
      "<p><strong>Message</strong></p>",
      "<pre style=\"white-space: pre-wrap\">" + escapeHtml(message) + "</pre>",
      "<p><strong>App version:</strong> " + escapeHtml(appVersion) + "<br>",
      "<strong>macOS version:</strong> " + escapeHtml(macOSVersion) + "<br>",
      "<strong>Install UUID:</strong> " + escapeHtml(installId) + "<br>",
      "<strong>Diagnostics:</strong> " + diagnosticsStatus + "<br>",
      "<strong>Reply-to email:</strong> " + escapeHtml(replyToLine) + "<br>",
      "<strong>Received:</strong> " + receivedAt + "</p>",
    ].join(""),
  };

  if (attachment) payload.attachment = [attachment];
  if (email) payload.replyTo = { email };
  return payload;
}

async function sendBrevoEmail(apiKey, payload) {
  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: brevoHeaders(apiKey),
    body: JSON.stringify(payload),
  });

  if (response.ok) return;
  console.error("Brevo feedback email error", response.status);
  throw new Error("email send failed");
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  if (bodyByteLength(req.body) > MAX_BODY_BYTES) {
    return res.status(413).json({ error: "Feedback payload is too large." });
  }

  const body = parseBody(req.body);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return res.status(400).json({ error: "Feedback must be a JSON object." });
  }

  const expectedToken = process.env.FEEDBACK_SHARED_TOKEN || DEFAULT_SHARED_TOKEN;
  if (body.token !== expectedToken) {
    return res.status(401).json({ error: "Unauthorized." });
  }

  const message = readString(body.message, MAX_MESSAGE_LENGTH);
  const appVersion = readString(body.appVersion, MAX_APP_VERSION_LENGTH);
  const macOSVersion = readString(body.macOSVersion, MAX_MACOS_VERSION_LENGTH);
  const installId = readString(body.installId, MAX_INSTALL_ID_LENGTH);
  const email = body.email == null || body.email === "" ? null : readString(body.email, 254);

  if (!message) return res.status(400).json({ error: "Feedback message is required." });
  if (!appVersion || !macOSVersion || !installId || !UUID_RE.test(installId)) {
    return res.status(400).json({ error: "App version, macOS version, and install UUID are required." });
  }
  if (body.email != null && !email) {
    return res.status(400).json({ error: "Please enter a valid email address." });
  }
  if (email && !EMAIL_RE.test(email)) {
    return res.status(400).json({ error: "Please enter a valid email address." });
  }

  const diagnostics = decodeDiagnostics(body.diagnosticsBase64);
  if (diagnostics.error) return res.status(400).json({ error: diagnostics.error });

  const apiKey = process.env.BREVO_API_KEY;
  const sender = senderConfig();
  if (!apiKey || !sender) {
    console.error("Feedback endpoint is missing Brevo configuration");
    return res.status(500).json({ error: "Server is not configured." });
  }

  let accepted;
  try {
    if (!await checkSubmissionRateLimit(installId, requestIp(req))) {
      return res.status(429).json({ error: "Too many feedback submissions. Please try again later." });
    }
    accepted = {
      id: crypto.randomUUID(),
      receivedAt: new Date().toISOString(),
      updatedAt: null,
      status: "new",
      labels: [],
      agentSummary: null,
      notificationStatus: "pending",
      message,
      email,
      appVersion,
      macOSVersion,
      installId,
      diagnosticsBase64: body.diagnosticsBase64 || null,
    };
    await createFeedback(accepted);
  } catch (error) {
    console.error("Feedback persistence failed", error);
    return res.status(503).json({ error: "Feedback storage is unavailable. Please try again." });
  }

  const notifyEmail = process.env.NOTIFY_EMAIL || DEFAULT_NOTIFY_EMAIL;
  let notificationStatus;
  try {
    await sendBrevoEmail(apiKey, emailPayload({
      sender,
      notifyEmail,
      message,
      email,
      appVersion,
      macOSVersion,
      installId,
      attachment: diagnostics.attachment,
      receivedAt: accepted.receivedAt,
    }));
    notificationStatus = "sent";
  } catch (error) {
    console.error("Feedback relay failed", error);
    notificationStatus = "failed";
  }

  try {
    await updateNotificationStatus(accepted.id, notificationStatus);
  } catch (error) {
    // The feedback record is already durable. Delivery-state tracking must not
    // turn an accepted submission into a retry.
    console.error("Feedback notification state update failed", error);
  }
  return res.status(202).json({ ok: true, id: accepted.id });
}
