// Vercel serverless function — adds an email to a Brevo contact list.
// The Brevo API key is a server-side secret, read from the BREVO_API_KEY env var.
// It must never be exposed to the client.
//
// Brevo note: disable "Authorized IPs" in Brevo security settings for serverless
// (Vercel egress IPs are dynamic). https://app.brevo.com/security/authorised_ips

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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

  // Vercel parses JSON bodies automatically; fall back to manual parse just in case.
  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (_) { body = {}; }
  }
  const email = (body && body.email ? String(body.email) : "").trim().toLowerCase();

  if (!EMAIL_RE.test(email)) {
    return res.status(400).json({ error: "Please enter a valid email address." });
  }

  try {
    const r = await fetch("https://api.brevo.com/v3/contacts", {
      method: "POST",
      headers: {
        "api-key": apiKey,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({ email, listIds: [listId], updateEnabled: true }),
    });

    if (r.ok) return res.status(200).json({ ok: true });

    let data = {};
    try { data = await r.json(); } catch (_) {}

    // Already a contact — treat as success so the user sees the confirmation.
    if (r.status === 400 && data.code === "duplicate_parameter") {
      return res.status(409).json({ ok: true, duplicate: true });
    }

    if (r.status === 401 && data.code === "unauthorized") {
      console.error("Brevo rejected request — disable Authorized IPs:", data.message);
    } else {
      console.error("Brevo error", r.status, data);
    }

    return res.status(502).json({ error: "Couldn’t reach the signup service. Please try again." });
  } catch (err) {
    console.error("Brevo request failed", err);
    return res.status(502).json({ error: "Couldn’t reach the signup service. Please try again." });
  }
}
