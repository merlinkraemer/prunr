// Vercel serverless function — adds an email to a Brevo contact list and sends
// a welcome email with the alpha download link (transactional template).
//
// Brevo note: disable "Authorized IPs" for serverless egress.
// Setup: docs/brevo-welcome-email.md

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const DEFAULT_DOWNLOAD_URL = "https://merlinkraemer.github.io/prunr/download.html";
const DEFAULT_NOTIFY_EMAIL = "merlinkraemer@gmail.com";

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

function senderConfig() {
  const senderEmail = process.env.BREVO_SENDER_EMAIL;
  if (!senderEmail) return null;
  return { name: process.env.BREVO_SENDER_NAME || "Merlin", email: senderEmail };
}

async function sendBrevoEmail(apiKey, payload) {
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: brevoHeaders(apiKey),
    body: JSON.stringify(payload),
  });
  if (r.ok) return;
  let data = {};
  try { data = await r.json(); } catch (_) {}
  console.error("Brevo email error", r.status, data);
  throw new Error("email send failed");
}

async function sendWelcomeEmail(apiKey, email) {
  const templateId = Number(process.env.BREVO_WELCOME_TEMPLATE_ID || 0);
  if (!templateId) {
    console.info("Welcome email skipped — BREVO_WELCOME_TEMPLATE_ID not set");
    return;
  }

  const sender = senderConfig();
  if (!sender) {
    console.error("BREVO_SENDER_EMAIL is not set — cannot send welcome email");
    return;
  }

  const downloadUrl = process.env.DOWNLOAD_PAGE_URL || DEFAULT_DOWNLOAD_URL;
  await sendBrevoEmail(apiKey, {
    sender,
    to: [{ email }],
    templateId,
    params: { DOWNLOAD_URL: downloadUrl },
  });
}

async function sendOwnerNotification(apiKey, signupEmail) {
  const notifyEmail = process.env.NOTIFY_EMAIL || DEFAULT_NOTIFY_EMAIL;
  const sender = senderConfig();
  if (!sender) {
    console.error("BREVO_SENDER_EMAIL is not set — cannot send owner notification");
    return;
  }

  const when = new Date().toISOString();
  await sendBrevoEmail(apiKey, {
    sender,
    to: [{ email: notifyEmail }],
    subject: `Prunr alpha signup: ${signupEmail}`,
    textContent: `New alpha signup\n\nEmail: ${signupEmail}\nTime: ${when}\n`,
    htmlContent: `<p>New alpha signup</p><p><strong>Email:</strong> ${signupEmail}<br><strong>Time:</strong> ${when}</p>`,
  });
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
      console.error("Welcome email failed after contact add", err);
    }

    if (!contact.duplicate) {
      try {
        await sendOwnerNotification(apiKey, email);
      } catch (err) {
        console.error("Owner notification failed after contact add", err);
      }
    }

    return res.status(contact.duplicate ? 409 : 200).json({ ok: true, duplicate: contact.duplicate });
  } catch (err) {
    console.error("Subscribe failed", err);
    return res.status(502).json({ error: "Couldn’t reach the signup service. Please try again." });
  }
}
