export function requireAgentAuth(req, res) {
  const expectedToken = process.env.FEEDBACK_AGENT_TOKEN;
  if (!expectedToken) {
    console.error("Feedback agent API is missing FEEDBACK_AGENT_TOKEN");
    res.status(503).json({ error: "Feedback agent API is not configured." });
    return false;
  }

  if (req.headers.authorization !== `Bearer ${expectedToken}`) {
    res.setHeader("WWW-Authenticate", "Bearer");
    res.status(401).json({ error: "Unauthorized." });
    return false;
  }
  return true;
}
