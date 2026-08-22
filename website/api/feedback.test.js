import assert from "node:assert/strict";
import test from "node:test";

import feedbackHandler from "./feedback.js";
import agentListHandler from "./agent/feedback/index.js";
import agentDetailHandler from "./agent/feedback/[id].js";
import { listFeedback } from "./feedback-store.js";

const store = new Map();
const sortedIds = [];
const sentEmails = [];
let brevoShouldFail = false;

function jsonResponse(result, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => ({ result }) };
}

function installFetchMock() {
  global.fetch = async (url, options = {}) => {
    if (url === "https://api.brevo.com/v3/smtp/email") {
      sentEmails.push(JSON.parse(options.body));
      return { ok: !brevoShouldFail, status: brevoShouldFail ? 503 : 201, json: async () => ({}) };
    }

    if (url === "https://kv.example.test/multi-exec") {
      const commands = JSON.parse(options.body);
      for (const [command, ...args] of commands) {
        if (command === "SET") store.set(args[0], args[1]);
        if (command === "ZADD" && !sortedIds.includes(args[2])) sortedIds.push(args[2]);
      }
      return { ok: true, status: 200, json: async () => commands.map(() => ({ result: "OK" })) };
    }

    assert.equal(url, "https://kv.example.test");
    const [command, ...args] = JSON.parse(options.body);
    if (command === "SET") {
      store.set(args[0], args[1]);
      return jsonResponse("OK");
    }
    if (command === "GET") return jsonResponse(store.get(args[0]) ?? null);
    if (command === "INCR") {
      const value = Number(store.get(args[0]) || 0) + 1;
      store.set(args[0], String(value));
      return jsonResponse(value);
    }
    if (command === "EXPIRE" || command === "ZREMRANGEBYRANK") return jsonResponse(1);
    if (command === "ZADD") {
      if (!sortedIds.includes(args[2])) sortedIds.push(args[2]);
      return jsonResponse(1);
    }
    if (command === "ZREVRANGE") {
      const [start, end] = args.slice(1).map(Number);
      return jsonResponse([...sortedIds].reverse().slice(start, end + 1));
    }
    if (command === "ZCARD") return jsonResponse(sortedIds.length);
    if (command === "EVAL") {
      const [, , key, notificationStatus, updatedAt] = args;
      const record = JSON.parse(store.get(key));
      record.notificationStatus = notificationStatus;
      record.updatedAt = updatedAt;
      store.set(key, JSON.stringify(record));
      return jsonResponse(1);
    }
    throw new Error(`Unhandled Redis command: ${command}`);
  };
}

function response() {
  return {
    headers: {},
    statusCode: null,
    body: null,
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
    end() { return this; },
  };
}

function feedbackRequest(overrides = {}) {
  return {
    method: "POST",
    headers: { "x-forwarded-for": "203.0.113.1" },
    body: {
      token: "public-token",
      message: "The scan feels slow after waking my Mac.",
      email: "tester@example.com",
      appVersion: "0.11.0",
      macOSVersion: "26.0",
      installId: "d2719a21-b42d-4e4e-9c96-58fbe0ab0ea1",
      diagnosticsBase64: Buffer.from("redacted diagnostic log").toString("base64"),
      ...overrides,
    },
  };
}

process.env.KV_REST_API_URL = "https://kv.example.test";
process.env.KV_REST_API_TOKEN = "kv-token";
process.env.FEEDBACK_SHARED_TOKEN = "public-token";
process.env.FEEDBACK_AGENT_TOKEN = "agent-token";
process.env.BREVO_API_KEY = "brevo-key";
process.env.BREVO_SENDER_EMAIL = "feedback@prunr.app";
installFetchMock();

test("feedback is persisted, emailed, and agent-triageable", async () => {
  const submitResponse = response();
  await feedbackHandler(feedbackRequest(), submitResponse);

  assert.equal(submitResponse.statusCode, 202);
  assert.equal(typeof submitResponse.body.id, "string");
  assert.equal(sentEmails.length, 1);

  const listResponse = response();
  await agentListHandler({
    method: "GET",
    headers: { authorization: "Bearer agent-token" },
    query: { status: "new" },
  }, listResponse);
  assert.equal(listResponse.statusCode, 200);
  assert.equal(listResponse.body.feedback.length, 1);
  assert.equal(listResponse.body.feedback[0].hasDiagnostics, true);
  assert.equal(Object.hasOwn(listResponse.body.feedback[0], "diagnosticsBase64"), false);

  const detailResponse = response();
  await agentDetailHandler({
    method: "GET",
    headers: { authorization: "Bearer agent-token" },
    query: { id: submitResponse.body.id },
  }, detailResponse);
  assert.equal(detailResponse.statusCode, 200);
  assert.equal(detailResponse.body.feedback.diagnosticsBase64, Buffer.from("redacted diagnostic log").toString("base64"));

  const patchResponse = response();
  await agentDetailHandler({
    method: "PATCH",
    headers: { authorization: "Bearer agent-token" },
    query: { id: submitResponse.body.id },
    body: { status: "in_progress", labels: ["scan", "performance"], agentSummary: "Reproduce after wake." },
  }, patchResponse);
  assert.equal(patchResponse.statusCode, 200);
  assert.deepEqual(patchResponse.body.feedback.labels, ["scan", "performance"]);
  assert.equal(patchResponse.body.feedback.status, "in_progress");
});

test("agent endpoints require a separate bearer token", async () => {
  const res = response();
  await agentListHandler({ method: "GET", headers: {}, query: {} }, res);
  assert.equal(res.statusCode, 401);
  assert.equal(res.headers["WWW-Authenticate"], "Bearer");
});

test("a noisy installation is rate limited before another email is sent", async () => {
  const installId = "1278aa21-b42d-4e4e-9c96-58fbe0ab0ea1";
  for (let index = 0; index < 5; index += 1) {
    const res = response();
    await feedbackHandler(feedbackRequest({ installId, message: `Message ${index}` }), res);
    assert.equal(res.statusCode, 202);
  }
  const res = response();
  await feedbackHandler(feedbackRequest({ installId, message: "Too many" }), res);
  assert.equal(res.statusCode, 429);
});

test("a Brevo outage does not make an already-persisted submission retry", async () => {
  brevoShouldFail = true;
  const res = response();
  await feedbackHandler(feedbackRequest({
    installId: "2278aa21-b42d-4e4e-9c96-58fbe0ab0ea1",
    message: "Store this even if email is down.",
  }), res);
  brevoShouldFail = false;

  assert.equal(res.statusCode, 202);
  const detailResponse = response();
  await agentDetailHandler({
    method: "GET",
    headers: { authorization: "Bearer agent-token" },
    query: { id: res.body.id },
  }, detailResponse);
  assert.equal(detailResponse.body.feedback.notificationStatus, "failed");
});

test("filtered pagination preserves matches from a partially matching chunk", async () => {
  store.clear();
  sortedIds.length = 0;
  for (let index = 0; index < 50; index += 1) {
    const id = `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
    const status = index >= 30 || index < 25 ? "new" : "resolved";
    store.set(`feedback:${id}`, JSON.stringify({ id, status, labels: [], diagnosticsBase64: null }));
    sortedIds.push(id);
  }

  const firstPage = await listFeedback({ limit: 25, status: "new" });
  assert.equal(firstPage.feedback.length, 25);
  assert.equal(firstPage.nextCursor, 30);

  const secondPage = await listFeedback({ cursor: firstPage.nextCursor, limit: 25, status: "new" });
  assert.equal(secondPage.feedback.length, 20);
  assert.equal(secondPage.nextCursor, null);
});
