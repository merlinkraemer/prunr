import assert from "node:assert/strict";
import test from "node:test";

import downloadHandler, { FALLBACK_URL, resetReleaseCache, userAgentClass } from "./download.js";
import statsHandler from "./download-stats.js";

const DMG_URL = "https://github.com/merlinkraemer/prunr/releases/download/v0.12.0/Prunr-0.12.0-build42-macos.dmg";
const MAC_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15";

const counters = new Map();
const hashes = new Map();
const days = new Map();
const events = [];
let githubCalls = 0;
let githubResponse = () => ({
  ok: true,
  status: 200,
  json: async () => ({
    tag_name: "v0.12.0",
    assets: [
      { name: "Prunr-0.12.0-build42-dSYMs.zip", browser_download_url: "https://example.test/dsym.zip" },
      { name: "Prunr-0.12.0-build42-macos.dmg", browser_download_url: DMG_URL },
    ],
  }),
});
let storageShouldFail = false;

function runRedis(command, args) {
  if (command === "INCR") {
    counters.set(args[0], (counters.get(args[0]) || 0) + 1);
    return counters.get(args[0]);
  }
  if (command === "GET") return counters.has(args[0]) ? String(counters.get(args[0])) : null;
  if (command === "HINCRBY") {
    const hash = hashes.get(args[0]) || new Map();
    hash.set(args[1], (hash.get(args[1]) || 0) + Number(args[2]));
    hashes.set(args[0], hash);
    return hash.get(args[1]);
  }
  if (command === "HGETALL") {
    return [...(hashes.get(args[0]) || new Map())].flatMap(([field, value]) => [field, String(value)]);
  }
  if (command === "ZADD") {
    days.set(args[2], Number(args[1]));
    return 1;
  }
  if (command === "ZREVRANGE") {
    const [start, end] = args.slice(1).map(Number);
    return [...days].sort((a, b) => b[1] - a[1]).map(([day]) => day).slice(start, end + 1);
  }
  if (command === "LPUSH") {
    events.unshift(args[1]);
    return events.length;
  }
  if (command === "LTRIM") return "OK";
  throw new Error(`Unhandled Redis command: ${command}`);
}

global.fetch = async (url, options = {}) => {
  if (url === "https://api.github.com/repos/merlinkraemer/prunr/releases/latest") {
    githubCalls += 1;
    return githubResponse();
  }
  if (storageShouldFail) return { ok: false, status: 503, json: async () => ({}) };
  if (url === "https://kv.example.test/multi-exec") {
    const commands = JSON.parse(options.body);
    return { ok: true, status: 200, json: async () => commands.map(([command, ...args]) => ({ result: runRedis(command, args) })) };
  }
  assert.equal(url, "https://kv.example.test");
  const [command, ...args] = JSON.parse(options.body);
  return { ok: true, status: 200, json: async () => ({ result: runRedis(command, args) }) };
};

process.env.KV_REST_API_URL = "https://kv.example.test";
process.env.KV_REST_API_TOKEN = "kv-token";
process.env.FEEDBACK_AGENT_TOKEN = "agent-token";

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

function downloadRequest({ query = {}, headers = {}, method = "GET" } = {}) {
  return { method, query, headers: { "user-agent": MAC_UA, ...headers } };
}

test("download counts one event and redirects to the latest DMG", async () => {
  const res = response();
  await downloadHandler(downloadRequest({
    query: { src: "Reddit" },
    headers: { referer: "https://www.reddit.com/r/macapps/comments/abc?utm=1", "x-forwarded-for": "203.0.113.9" },
  }), res);

  assert.equal(res.statusCode, 302);
  assert.equal(res.headers.Location, DMG_URL);
  assert.equal(res.headers["Cache-Control"], "no-store");
  assert.equal(events.length, 1);

  const event = JSON.parse(events[0]);
  assert.deepEqual(Object.keys(event).sort(), ["at", "ref", "src", "ua"]);
  assert.equal(event.src, "reddit");
  assert.equal(event.ref, "www.reddit.com");
  assert.equal(event.ua, "mac");
  assert.equal(JSON.stringify(event).includes("203.0.113.9"), false);
});

test("release lookup is cached between downloads", async () => {
  const before = githubCalls;
  await downloadHandler(downloadRequest({ query: { src: "site" } }), response());
  assert.equal(githubCalls, before);
});

test("download sanitizes src and referrer and ignores HEAD for counting", async () => {
  const before = events.length;
  await downloadHandler(downloadRequest({ query: { src: "<script>" }, headers: { referer: "not a url" } }), response());
  const event = JSON.parse(events[0]);
  assert.equal(event.src, "other");
  assert.equal(event.ref, "other");

  await downloadHandler(downloadRequest({ method: "HEAD" }), response());
  assert.equal(events.length, before + 1);
});

test("download still redirects when storage or GitHub fails", async () => {
  resetReleaseCache();
  storageShouldFail = true;
  const original = githubResponse;
  githubResponse = () => ({ ok: false, status: 403, json: async () => ({}) });
  try {
    const res = response();
    await downloadHandler(downloadRequest(), res);
    assert.equal(res.statusCode, 302);
    assert.equal(res.headers.Location, FALLBACK_URL);
  } finally {
    storageShouldFail = false;
    githubResponse = original;
    resetReleaseCache();
  }
});

test("user agent classes are coarse", () => {
  assert.equal(userAgentClass(MAC_UA), "mac");
  assert.equal(userAgentClass("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"), "other");
  assert.equal(userAgentClass("Twitterbot/1.0"), "bot");
  assert.equal(userAgentClass(undefined), "other");
});

test("download stats require the agent token", async () => {
  const res = response();
  await statsHandler({ method: "GET", headers: {}, query: {} }, res);
  assert.equal(res.statusCode, 401);
  assert.equal(res.headers["WWW-Authenticate"], "Bearer");
});

test("download stats return totals by day and source", async () => {
  const res = response();
  await statsHandler({ method: "GET", headers: { authorization: "Bearer agent-token" }, query: { days: "7" } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.allTime, 3);
  assert.equal(res.body.total, 3);
  assert.deepEqual(res.body.src, { reddit: 1, site: 1, other: 1 });
  assert.equal(res.body.ua.mac, 3);
  assert.equal(res.body.ref["www.reddit.com"], 1);
  assert.equal(res.body.byDay.length, 1);
  assert.equal(res.body.byDay[0].date, new Date().toISOString().slice(0, 10));
  assert.equal(res.body.byDay[0].total, 3);
});

test("download stats reject invalid day ranges", async () => {
  const res = response();
  await statsHandler({ method: "GET", headers: { authorization: "Bearer agent-token" }, query: { days: "0" } }, res);
  assert.equal(res.statusCode, 400);
});
