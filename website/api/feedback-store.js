const FEEDBACK_TTL_SECONDS = 90 * 24 * 60 * 60;
const INDEX_KEY = "feedback:received";
const MAX_INDEX_ENTRIES = 1_000;
const RATE_LIMIT_WINDOW_SECONDS = 15 * 60;
const RATE_LIMIT_MAX_SUBMISSIONS = 5;
const IP_RATE_LIMIT_MAX_SUBMISSIONS = 10;
const GLOBAL_RATE_LIMIT_WINDOW_SECONDS = 24 * 60 * 60;
const GLOBAL_RATE_LIMIT_MAX_SUBMISSIONS = 200;

function redisConfig() {
  const url = process.env.KV_REST_API_URL;
  const token = process.env.KV_REST_API_TOKEN;
  if (!url || !token) throw new Error("Feedback storage is not configured.");
  return { url: url.replace(/\/$/, ""), token };
}

async function redisCommand(...command) {
  const { url, token } = redisConfig();
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(command),
  });

  if (!response.ok) throw new Error(`Feedback storage request failed (${response.status}).`);
  const payload = await response.json();
  if (payload.error) throw new Error(`Feedback storage error: ${payload.error}`);
  return payload.result;
}

async function redisTransaction(commands) {
  const { url, token } = redisConfig();
  const response = await fetch(`${url}/multi-exec`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(commands),
  });

  if (!response.ok) throw new Error(`Feedback storage transaction failed (${response.status}).`);
  const payload = await response.json();
  if (!Array.isArray(payload) || payload.some((entry) => entry.error)) {
    throw new Error("Feedback storage transaction failed.");
  }
}

function feedbackKey(id) {
  return `feedback:${id}`;
}

export function feedbackSummary(record) {
  const { diagnosticsBase64, ...summary } = record;
  return {
    ...summary,
    hasDiagnostics: Boolean(diagnosticsBase64),
  };
}

async function incrementRateLimit(key, windowSeconds) {
  const count = await redisCommand("INCR", key);
  if (count === 1) await redisCommand("EXPIRE", key, windowSeconds);
  return count;
}

export async function checkSubmissionRateLimit(installId, sourceIp) {
  const [installCount, ipCount, globalCount] = await Promise.all([
    incrementRateLimit(`feedback:rate:install:${installId}`, RATE_LIMIT_WINDOW_SECONDS),
    incrementRateLimit(`feedback:rate:ip:${sourceIp || "unknown"}`, RATE_LIMIT_WINDOW_SECONDS),
    incrementRateLimit("feedback:rate:global", GLOBAL_RATE_LIMIT_WINDOW_SECONDS),
  ]);
  return installCount <= RATE_LIMIT_MAX_SUBMISSIONS
    && ipCount <= IP_RATE_LIMIT_MAX_SUBMISSIONS
    && globalCount <= GLOBAL_RATE_LIMIT_MAX_SUBMISSIONS;
}

export async function createFeedback(record) {
  const key = feedbackKey(record.id);
  await redisTransaction([
    ["SET", key, JSON.stringify(record), "EX", FEEDBACK_TTL_SECONDS],
    ["ZADD", INDEX_KEY, Date.parse(record.receivedAt), record.id],
    ["ZREMRANGEBYRANK", INDEX_KEY, 0, -(MAX_INDEX_ENTRIES + 1)],
  ]);
}

export async function getFeedback(id) {
  const value = await redisCommand("GET", feedbackKey(id));
  return value ? JSON.parse(value) : null;
}

export async function listFeedback({ cursor = 0, limit = 25, status = null }) {
  const feedback = [];
  let offset = cursor;
  while (feedback.length < limit) {
    const remaining = limit - feedback.length;
    const ids = await redisCommand("ZREVRANGE", INDEX_KEY, offset, offset + remaining - 1);
    if (ids.length === 0) break;
    offset += ids.length;
    const records = (await Promise.all(ids.map(getFeedback))).filter(Boolean);
    feedback.push(...records.filter((record) => !status || record.status === status).map(feedbackSummary));
    if (ids.length < remaining) break;
  }
  const total = await redisCommand("ZCARD", INDEX_KEY);
  return {
    feedback,
    nextCursor: offset < total ? offset : null,
  };
}

export async function updateFeedback(id, changes) {
  const record = await getFeedback(id);
  if (!record) return null;
  const updated = { ...record, ...changes, updatedAt: new Date().toISOString() };
  await redisCommand("SET", feedbackKey(id), JSON.stringify(updated), "KEEPTTL");
  return updated;
}

export async function updateNotificationStatus(id, notificationStatus) {
  const script = [
    "local value = redis.call('GET', KEYS[1])",
    "if not value then return 0 end",
    "local record = cjson.decode(value)",
    "record.notificationStatus = ARGV[1]",
    "record.updatedAt = ARGV[2]",
    "redis.call('SET', KEYS[1], cjson.encode(record), 'KEEPTTL')",
    "return 1",
  ].join("\n");
  return redisCommand("EVAL", script, 1, feedbackKey(id), notificationStatus, new Date().toISOString());
}
