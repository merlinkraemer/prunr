import { redisCommand, redisTransaction } from "./feedback-store.js";

const DAYS_KEY = "download:days";
const EVENTS_KEY = "download:events";
const TOTAL_KEY = "download:total";
const MAX_EVENTS = 10_000;

function dayKey(day) {
  return `download:day:${day}`;
}

export async function recordDownload(event) {
  const day = event.at.slice(0, 10);
  const key = dayKey(day);
  await redisTransaction([
    ["INCR", TOTAL_KEY],
    ["HINCRBY", key, "total", 1],
    ["HINCRBY", key, `src:${event.src}`, 1],
    ["HINCRBY", key, `ua:${event.ua}`, 1],
    ["HINCRBY", key, `ref:${event.ref}`, 1],
    ["ZADD", DAYS_KEY, Date.parse(`${day}T00:00:00Z`), day],
    ["LPUSH", EVENTS_KEY, JSON.stringify(event)],
    ["LTRIM", EVENTS_KEY, 0, MAX_EVENTS - 1],
  ]);
}

function groupDayCounters(flat) {
  const day = { total: 0, src: {}, ua: {}, ref: {} };
  for (let i = 0; i < flat.length; i += 2) {
    const field = flat[i];
    const count = Number(flat[i + 1]);
    if (field === "total") {
      day.total = count;
      continue;
    }
    const separator = field.indexOf(":");
    const group = field.slice(0, separator);
    if (day[group]) day[group][field.slice(separator + 1)] = count;
  }
  return day;
}

function addInto(target, counts) {
  for (const [name, count] of Object.entries(counts)) target[name] = (target[name] || 0) + count;
}

export async function downloadStats({ days }) {
  const [allTime, dates] = await Promise.all([
    redisCommand("GET", TOTAL_KEY),
    redisCommand("ZREVRANGE", DAYS_KEY, 0, days - 1),
  ]);
  const counters = await Promise.all(dates.map((date) => redisCommand("HGETALL", dayKey(date))));
  const totals = { total: 0, src: {}, ua: {}, ref: {} };
  const byDay = dates.map((date, index) => {
    const day = groupDayCounters(counters[index] || []);
    totals.total += day.total;
    addInto(totals.src, day.src);
    addInto(totals.ua, day.ua);
    addInto(totals.ref, day.ref);
    return { date, ...day };
  });
  return { allTime: Number(allTime || 0), days: byDay.length, ...totals, byDay };
}
