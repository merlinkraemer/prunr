// Vercel serverless function — adds an email to a Brevo contact list and sends
// a welcome email with the alpha download link (transactional template).
//
// Brevo note: disable "Authorized IPs" for serverless egress.
// Setup: docs/brevo-welcome-email.md

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const DEFAULT_DOWNLOAD_URL = "https://merlinkraemer.github.io/prunr/download.html";

const ALLOWED_ORIGINS = new Set([
  "https://merlinkraemer.github.io",
  "http://localhost:5173",
  "http://localhost:5174",
]);

function pickOrigin(req) {
  const origin = req.headers.origin;
  if (origin && ALLOWED_ORIGINS.has(origin)) return origin;
  return "https://merlinkraemer.github.io";
}

function brevoHeaders(apiKey) {
  return {
    "api-key": apiKey,
    "content-type": "application/json",
    accept: "application/json",
  };
}

async function addContact(apiKey, listId, email) {
  const r = await fetch("https://api.brevo.com/v3/contacts", {
    method: "POST",
    headers: brevoHeaders(apiKey),
    body: JSON.stringify({ email, listIds: [listId], updateEnabled: true }),
  });

  if (r.ok) return { ok: true, duplicate: false };

  let data = {};
  try { data = await r.json(); } catch (_) {}

  if (r.status === 400 && data.code === "duplicate_parameter") {
    return { ok: true, duplicate: true };
  }

  if (r.status === 401 && data.code === "unauthorized") {
    console.error("Brevo rejected request — disable Authorized IPs:", data.message);
  } else {
    console.error("Brevo contact error", r.status, data);
  }

  return { ok: false, status: r.status, data };
}

async function sendWelcomeEmail(apiKey, email) {
  const templateId = Number(process.env.BREVO_WELCOME_TEMPLATE_ID || 0);
  if (!templateId) {
    console.info("Welcome email skipped — BREVO_WELCOME_TEMPLATE_ID not set");
    return;
  }

  const senderEmail = process.env.BREVO_SENDER_EMAIL;
  if (!senderEmail) {
    console.error("BREVO_SENDER_EMAIL is not set — cannot send welcome email");
    return;
  }

  const downloadUrl = process.env.DOWNLOAD_PAGE_URL || DEFAULT_DOWNLOAD_URL;
  const senderName = process.env.BREVO_SENDER_NAME || "Merlin";

  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: brevoHeaders(apiKey),
    body: JSON.stringify({
      sender: { name: senderName, email: senderEmail },
      to: [{ email }],
      templateId,
      params: { DOWNLOAD_URL: downloadUrl },
    }),
  });

  if (r.ok) return;

  let data = {};
  try { data = await r.json(); } catch (_) {}
  console.error("Brevo welcome email error", r.status, data);
  throw new Error("welcome email failed");
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", pickOrigin(req));
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Vary", "Origin");

  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const apiKey = process.env.BREVO_API_KEY;
  const listId = Number(process.env.BREVO_LIST_ID || 6);
  if (!apiKey) {
    console.error("BREVO_API_KEY is not set");
    return res.status(500).json({ error: "Server is not configured." });
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (_) { body = {}; }
  }
  const email = (body && body.email ? String(body.email) : "").trim().toLowerCase();

  if (!EMAIL_RE.test(email)) {
    return res.status(400).json({ error: "Please enter a valid email address." });
  }

  try {
    const contact = await addContact(apiKey, listId, email);
    if (!contact.ok) {
      return res.status(502).json({ error: "Couldn’t reach the signup service. Please try again." });
    }

    try {
      await sendWelcomeEmail(apiKey, email);
    } catch (err) {
      // Contact is saved — don’t fail signup if email delivery hiccups.
      console.error("Welcome email failed after contact add", err);
    }

    return res.status(contact.duplicate ? 409 : 200).json({ ok: true, duplicate: contact.duplicate });
  } catch (err) {
    console.error("Subscribe failed", err);
    return res.status(502).json({ error: "Couldn’t reach the signup service. Please try again." });
  }
}
