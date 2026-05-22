#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import process from "node:process";

const BUNDLE_ID = "com.prunr.app";
const PROCESS_NAME = "Prunr";
const APP_SUPPORT_DIR = `${os.homedir()}/Library/Application Support/Prunr`;
const DB_PATH = `${APP_SUPPORT_DIR}/prunr.db`;
const MAIN_BASE_PATH_ID = "B9E2C9D6-7A6C-4A8C-9A73-9DBA3DE27B57";
const EXPECTED_CATEGORY_COUNT = 8;
const DEFAULT_INTERVAL_SECONDS = 5;
const DEFAULT_LOG_LOOKBACK_MINUTES = 15;
const LOG_REFRESH_INTERVAL_SECONDS = 30;
const CATEGORY_STALE_WARNING_SECONDS = 30;
const CATEGORY_INFLATION_RATIO = 1.02;
const HIGH_CPU_PERCENT = 120;
const HIGH_RSS_BYTES = 1.5 * 1024 * 1024 * 1024;
const RSS_LEAK_DELTA_BYTES = 256 * 1024 * 1024;
const STALL_WARNING_SAMPLES = 3;

function parseArgs(argv) {
  const options = {
    intervalSeconds: DEFAULT_INTERVAL_SECONDS,
    samples: null,
    logLookbackMinutes: DEFAULT_LOG_LOOKBACK_MINUTES,
    json: false,
    freshnessProbe: false,
    freshnessTimeoutSeconds: 90,
    freshnessProbeBytes: 8 * 1024 * 1024,
    freshnessProbeDir: null
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    switch (argument) {
    case "--interval":
      options.intervalSeconds = positiveNumber(argv[++index], "--interval");
      break;
    case "--samples":
      options.samples = positiveInteger(argv[++index], "--samples");
      break;
    case "--log-lookback-minutes":
      options.logLookbackMinutes = positiveInteger(argv[++index], "--log-lookback-minutes");
      break;
    case "--json":
      options.json = true;
      break;
    case "--freshness-probe":
      options.freshnessProbe = true;
      break;
    case "--freshness-timeout":
      options.freshnessTimeoutSeconds = positiveInteger(argv[++index], "--freshness-timeout");
      break;
    case "--freshness-size":
      options.freshnessProbeBytes = positiveInteger(argv[++index], "--freshness-size");
      break;
    case "--freshness-dir":
      options.freshnessProbeDir = argv[++index];
      break;
    case "--help":
      printHelp();
      process.exit(0);
    default:
      throw new Error(`Unknown argument: ${argument}`);
    }
  }

  return options;
}

function positiveNumber(value, flag) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${flag} expects a positive number`);
  }
  return parsed;
}

function positiveInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} expects a positive integer`);
  }
  return parsed;
}

function printHelp() {
  console.log(`Usage: npm run monitor -- [options]

Options:
  --interval <seconds>            Polling interval (default: ${DEFAULT_INTERVAL_SECONDS})
  --samples <count>               Stop after N samples
  --log-lookback-minutes <count>  Initial unified-log lookback (default: ${DEFAULT_LOG_LOOKBACK_MINUTES})
  --json                          Emit one JSON object per sample
  --freshness-probe               Run a one-shot freshness probe: create a file
                                  under a tracked path and verify Prunr's
                                  workingSet/category totals update.
  --freshness-timeout <seconds>   Probe timeout (default: 90)
  --freshness-size <bytes>        Probe file size in bytes (default: 8 MB)
  --freshness-dir <path>          Directory under a tracked path to host the
                                  probe file (default: active configured root)
  --help                          Show this help
`);
}

function runCommand(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      ...options
    }).trim();
  } catch (error) {
    const stderr = error.stderr?.toString().trim();
    const stdout = error.stdout?.toString().trim();
    const detail = stderr || stdout || error.message;
    throw new Error(`${command} ${args.join(" ")} failed: ${detail}`);
  }
}

function runOptionalCommand(command, args, fallback = "") {
  try {
    return runCommand(command, args);
  } catch {
    return fallback;
  }
}

function sqliteJson(sql) {
  const raw = runCommand("sqlite3", ["-json", DB_PATH, sql]);
  return raw ? JSON.parse(raw) : [];
}

function readDefaults() {
  const xml = runOptionalCommand("defaults", ["export", BUNDLE_ID, "-"], "");
  return {
    mainBasePath: plistString(xml, "mainBasePath"),
    trackedPathsData: plistData(xml, "trackedPaths"),
    automaticFullScanIntervalHours: plistInteger(xml, "automaticFullScanIntervalHours"),
    adaptiveFullScanIntervalApplied: plistBool(xml, "adaptiveFullScanIntervalApplied"),
    hasPendingScopeChanges: plistBool(xml, "hasPendingScopeChanges")
  };
}

function plistString(xml, key) {
  const match = xml.match(new RegExp(`<key>${escapeRegex(key)}</key>\\s*<string>([\\s\\S]*?)<\\/string>`));
  return match ? decodeXml(match[1]) : null;
}

function plistInteger(xml, key) {
  const match = xml.match(new RegExp(`<key>${escapeRegex(key)}</key>\\s*<integer>(-?\\d+)<\\/integer>`));
  return match ? Number.parseInt(match[1], 10) : null;
}

function plistBool(xml, key) {
  const truePattern = new RegExp(`<key>${escapeRegex(key)}</key>\\s*<true\\s*\\/?>`);
  const falsePattern = new RegExp(`<key>${escapeRegex(key)}</key>\\s*<false\\s*\\/?>`);
  if (truePattern.test(xml)) return true;
  if (falsePattern.test(xml)) return false;
  return null;
}

function plistData(xml, key) {
  const match = xml.match(new RegExp(`<key>${escapeRegex(key)}</key>\\s*<data>([\\s\\S]*?)<\\/data>`));
  return match ? match[1].replace(/\s+/g, "") : null;
}

function decodeXml(value) {
  return value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", "\"")
    .replaceAll("&#39;", "'");
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function readProcess() {
  const output = runOptionalCommand("ps", ["-axo", "pid,%cpu,rss,etime,comm", "-ww"], "");
  const lines = output.split("\n").slice(1).map((line) => line.trim()).filter(Boolean);
  const matches = lines
    .map((line) => {
      const match = line.match(/^(\d+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+(.+)$/);
      if (!match) return null;
      const [, pid, cpu, rss, etime, command] = match;
      if (!command.endsWith(`/${PROCESS_NAME}`) && command !== PROCESS_NAME) return null;
      return {
        pid: Number.parseInt(pid, 10),
        cpuPercent: Number.parseFloat(cpu),
        rssBytes: Number.parseInt(rss, 10) * 1024,
        elapsed: etime,
        command
      };
    })
    .filter(Boolean)
    .sort((left, right) => right.pid - left.pid);

  return matches[0] ?? null;
}

function readSnapshots() {
  return sqliteJson(`
    WITH entry_counts AS (
      SELECT
        snapshotId,
        COUNT(*) AS entryCount,
        COALESCE(SUM(sizeBytes), 0) AS totalBytes
      FROM snapshotEntry
      GROUP BY snapshotId
    )
    SELECT
      s.id,
      s.trackedPathId,
      s.createdAt,
      s.freeBytes,
      COALESCE(ec.entryCount, 0) AS entryCount,
      COALESCE(ec.totalBytes, 0) AS totalBytes
    FROM snapshot AS s
    LEFT JOIN entry_counts AS ec ON ec.snapshotId = s.id
    ORDER BY s.createdAt DESC
    LIMIT 6;
  `).map((row) => ({
    ...row,
    createdAtDate: parseSqliteDate(row.createdAt)
  }));
}

function readWorkingSet() {
  return sqliteJson(`
    SELECT
      trackedPathId,
      COUNT(*) AS rowCount,
      COALESCE(SUM(sizeBytes), 0) AS totalBytes,
      MAX(updatedAt) AS updatedAt
    FROM workingSetEntry
    GROUP BY trackedPathId
    ORDER BY updatedAt DESC;
  `).map((row) => ({
    ...row,
    updatedAtDate: parseSqliteDate(row.updatedAt)
  }));
}

function readCategoryTotals() {
  return sqliteJson(`
    SELECT
      trackedPathId,
      category,
      totalBytes,
      updatedAt
    FROM workingSetCategoryTotal
    ORDER BY trackedPathId, totalBytes DESC, category ASC;
  `).map((row) => ({
    ...row,
    updatedAtDate: parseSqliteDate(row.updatedAt)
  }));
}

function parseSqliteDate(value) {
  if (!value) return null;
  return new Date(value.replace(" ", "T") + "Z");
}

function formatBytes(bytes) {
  if (bytes == null || Number.isNaN(bytes)) return "n/a";
  const abs = Math.abs(bytes);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let unitIndex = 0;
  let value = abs;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }
  const fractionDigits = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  const sign = bytes < 0 ? "-" : "";
  return `${sign}${value.toFixed(fractionDigits)} ${units[unitIndex]}`;
}

function formatAge(date) {
  if (!date) return "n/a";
  return formatDuration((Date.now() - date.getTime()) / 1000);
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "n/a";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return `${hours}h ${minutes}m`;
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function collectLogs(state, options) {
  const now = Date.now();
  if (state.lastLogRefreshAt && now - state.lastLogRefreshAt < LOG_REFRESH_INTERVAL_SECONDS * 1000) {
    return state.logSummary;
  }

  const lookbackMinutes = state.lastLogRefreshAt
    ? Math.max(1, Math.ceil((now - state.lastLogRefreshAt) / 60000) + 1)
    : options.logLookbackMinutes;

  const output = runOptionalCommand("/usr/bin/log", [
    "show",
    "--style",
    "compact",
    "--last",
    `${lookbackMinutes}m`,
    "--predicate",
    `process == "${PROCESS_NAME}" OR subsystem == "com.prunr.permissions"`
  ], "");

  const blockedLocations = new Set(state.logSummary.blockedLocations);
  let permissionDeniedCount = state.logSummary.permissionDeniedCount;
  let cacheDeleteErrorCount = state.logSummary.cacheDeleteErrorCount;

  for (const line of output.split("\n")) {
    const normalizedLine = line.trim();
    if (!normalizedLine || state.seenLogLines.has(normalizedLine)) continue;
    state.seenLogLines.add(normalizedLine);

    if (normalizedLine.includes("Blocked scan scope locations:")) {
      const locations = normalizedLine.split("Blocked scan scope locations:")[1]
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean);
      for (const location of locations) blockedLocations.add(location);
    }
    if (/permission denied/i.test(normalizedLine) || /ScanError\.permissionDenied/.test(normalizedLine)) {
      permissionDeniedCount += 1;
    }
    if (normalizedLine.includes("GetAPFSVolumeRole error")) {
      cacheDeleteErrorCount += 1;
    }
  }

  state.lastLogRefreshAt = now;
  state.logSummary = {
    blockedLocations: Array.from(blockedLocations).sort(),
    permissionDeniedCount,
    cacheDeleteErrorCount
  };
  return state.logSummary;
}

function buildSample(previous, state, options) {
  const processInfo = readProcess();
  const defaults = readDefaults();
  const snapshots = readSnapshots();
  const workingSets = readWorkingSet();
  const categoryRows = readCategoryTotals();
  const logs = collectLogs(state, options);

  const latestSnapshot = snapshots[0] ?? null;
  const previousSnapshot = snapshots[1] ?? null;
  const workingSetByTrackedPath = new Map(workingSets.map((row) => [row.trackedPathId, row]));
  const categoriesByTrackedPath = new Map();
  for (const row of categoryRows) {
    const bucket = categoriesByTrackedPath.get(row.trackedPathId) ?? [];
    bucket.push(row);
    categoriesByTrackedPath.set(row.trackedPathId, bucket);
  }

  const trackedPathId = latestSnapshot?.trackedPathId ?? workingSets[0]?.trackedPathId ?? null;
  const workingSet = trackedPathId ? workingSetByTrackedPath.get(trackedPathId) ?? null : null;
  const categories = trackedPathId ? categoriesByTrackedPath.get(trackedPathId) ?? [] : [];
  const categoryBytes = categories.reduce((sum, row) => sum + Number(row.totalBytes), 0);
  const categoryUpdatedAt = categories.reduce((latest, row) => {
    if (!row.updatedAtDate) return latest;
    return !latest || row.updatedAtDate > latest ? row.updatedAtDate : latest;
  }, null);
  const rowDelta = latestSnapshot && previous?.latestSnapshot?.id === latestSnapshot.id
    ? Number(latestSnapshot.entryCount) - Number(previous.latestSnapshot.entryCount)
    : null;
  const snapshotByteDelta = latestSnapshot && previous?.latestSnapshot?.id === latestSnapshot.id
    ? Number(latestSnapshot.totalBytes) - Number(previous.latestSnapshot.totalBytes)
    : null;
  const rssDelta = processInfo && previous?.processInfo?.pid === processInfo.pid
    ? processInfo.rssBytes - previous.processInfo.rssBytes
    : null;
  const categoryByteDelta = previous?.trackedPathId === trackedPathId
    ? categoryBytes - previous.categoryBytes
    : null;

  const warnings = [];
  const notes = [];

  if (!processInfo) {
    warnings.push("Prunr process is not running");
  }

  if (latestSnapshot && rowDelta != null && rowDelta > 0) {
    state.stallSamples = 0;
  } else if (processInfo && latestSnapshot) {
    state.stallSamples += 1;
  } else {
    state.stallSamples = 0;
  }

  if (processInfo?.cpuPercent >= HIGH_CPU_PERCENT && state.stallSamples >= STALL_WARNING_SAMPLES) {
    warnings.push(
      `CPU is ${processInfo.cpuPercent.toFixed(1)}% but snapshot ${latestSnapshot.id} has not grown for ${state.stallSamples} samples`
    );
  }

  if (processInfo?.rssBytes >= HIGH_RSS_BYTES) {
    warnings.push(`RSS is high at ${formatBytes(processInfo.rssBytes)}`);
  }

  const leakWindow = state.rssHistory;
  if (processInfo) {
    leakWindow.push({ at: Date.now(), rssBytes: processInfo.rssBytes, rowCount: Number(latestSnapshot?.entryCount ?? 0) });
    while (leakWindow.length > 12) leakWindow.shift();
  }

  if (leakWindow.length >= 4) {
    const first = leakWindow[0];
    const last = leakWindow[leakWindow.length - 1];
    const rssGrowth = last.rssBytes - first.rssBytes;
    const rowGrowth = last.rowCount - first.rowCount;
    if (rssGrowth >= RSS_LEAK_DELTA_BYTES && rowGrowth < 10_000) {
      warnings.push(
        `RSS grew by ${formatBytes(rssGrowth)} while snapshot rows only grew by ${rowGrowth.toLocaleString()}`
      );
    }
  }

  if (workingSet) {
    const ratio = workingSet.totalBytes > 0 ? categoryBytes / workingSet.totalBytes : 1;
    const delta = categoryBytes - workingSet.totalBytes;
    if (ratio > CATEGORY_INFLATION_RATIO) {
      warnings.push(
        `Category totals exceed working-set bytes by ${formatBytes(delta)} (${(ratio * 100).toFixed(1)}% of working set)`
      );
    } else {
      notes.push(
        `category-vs-working-set delta ${formatBytes(delta)}`
      );
    }

    if (delta !== 0 && categories.length !== 0 && categoryUpdatedAt && workingSet.updatedAtDate) {
      const lagSeconds = (workingSet.updatedAtDate.getTime() - categoryUpdatedAt.getTime()) / 1000;
      if (lagSeconds > CATEGORY_STALE_WARNING_SECONDS) {
        warnings.push(
          `Category totals are stale by ${formatDuration(lagSeconds)} relative to working-set updates`
        );
      }
    }
  }

  if (categories.length > EXPECTED_CATEGORY_COUNT) {
    warnings.push(`Found ${categories.length} category rows for tracked path ${trackedPathId}, expected at most ${EXPECTED_CATEGORY_COUNT}`);
  }

  if (categories.some((row) => Number(row.totalBytes) < 0)) {
    warnings.push("Found negative category totals");
  }

  if (logs.blockedLocations.length > 0) {
    warnings.push(`Protected locations blocked: ${logs.blockedLocations.join(", ")}`);
  }

  if (logs.permissionDeniedCount > 0) {
    warnings.push(`Permission-denied log events seen: ${logs.permissionDeniedCount}`);
  }

  if (logs.cacheDeleteErrorCount >= 4) {
    warnings.push(`Repeated CacheDelete/GetAPFSVolumeRole errors seen: ${logs.cacheDeleteErrorCount}`);
  }

  const autoscanHours = defaults.automaticFullScanIntervalHours;
  const dueAt = latestSnapshot?.createdAtDate && autoscanHours
    ? new Date(latestSnapshot.createdAtDate.getTime() + autoscanHours * 3600 * 1000)
    : null;

  const topCategories = categories
    .slice(0, 5)
    .map((row) => {
      const previousValue = previous?.categoryMap?.get(row.category);
      const delta = previousValue == null ? null : Number(row.totalBytes) - previousValue;
      return {
        category: row.category,
        totalBytes: Number(row.totalBytes),
        deltaBytes: delta
      };
    });

  const sample = {
    at: new Date().toISOString(),
    trackedPathId,
    defaults,
    processInfo,
    latestSnapshot,
    previousSnapshot,
    workingSet,
    categories,
    categoryBytes,
    categoryUpdatedAt,
    topCategories,
    deltas: {
      rowDelta,
      snapshotByteDelta,
      rssDelta,
      categoryByteDelta
    },
    logs,
    warnings,
    notes,
    autoscan: {
      intervalHours: autoscanHours,
      adaptiveIntervalApplied: defaults.adaptiveFullScanIntervalApplied,
      nextDueAt: dueAt?.toISOString() ?? null
    }
  };

  sample.categoryMap = new Map(categories.map((row) => [row.category, Number(row.totalBytes)]));
  return sample;
}

function printSample(sample) {
  console.log("");
  console.log(`Sample ${sample.at}`);

  if (sample.processInfo) {
    const rssDeltaText = sample.deltas.rssDelta == null ? "" : ` (${signedBytes(sample.deltas.rssDelta)})`;
    console.log(
      `process   pid ${sample.processInfo.pid}  cpu ${sample.processInfo.cpuPercent.toFixed(1)}%  rss ${formatBytes(sample.processInfo.rssBytes)}${rssDeltaText}  uptime ${sample.processInfo.elapsed}`
    );
  } else {
    console.log("process   not running");
  }

  if (sample.latestSnapshot) {
    const rowDeltaText = sample.deltas.rowDelta == null ? "" : ` (${signedNumber(sample.deltas.rowDelta)} rows)`;
    const byteDeltaText = sample.deltas.snapshotByteDelta == null ? "" : ` (${signedBytes(sample.deltas.snapshotByteDelta)})`;
    console.log(
      `snapshot  #${sample.latestSnapshot.id}  ${Number(sample.latestSnapshot.entryCount).toLocaleString()} rows${rowDeltaText}  ${formatBytes(Number(sample.latestSnapshot.totalBytes))}${byteDeltaText}  age ${formatAge(sample.latestSnapshot.createdAtDate)}`
    );
  } else {
    console.log("snapshot  none");
  }

  if (sample.workingSet) {
    console.log(
      `working   ${Number(sample.workingSet.rowCount).toLocaleString()} rows  ${formatBytes(Number(sample.workingSet.totalBytes))}  updated ${formatAge(sample.workingSet.updatedAtDate)}`
    );
  } else {
    console.log("working   none");
  }

  if (sample.categories.length > 0) {
    const lag = sample.categoryUpdatedAt && sample.workingSet?.updatedAtDate
      ? formatDuration((sample.workingSet.updatedAtDate.getTime() - sample.categoryUpdatedAt.getTime()) / 1000)
      : "n/a";
    console.log(
      `category  ${sample.categories.length} rows  ${formatBytes(sample.categoryBytes)}  updated ${formatAge(sample.categoryUpdatedAt)}  lag ${lag}`
    );
    const topLine = sample.topCategories
      .map((row) => `${row.category}=${formatBytes(row.totalBytes)}${row.deltaBytes == null ? "" : ` (${signedBytes(row.deltaBytes)})`}`)
      .join("  ");
    console.log(`top       ${topLine}`);
  } else {
    console.log("category  none");
  }

  const autoscanParts = [];
  if (sample.defaults.mainBasePath) autoscanParts.push(`root ${sample.defaults.mainBasePath}`);
  if (sample.autoscan.intervalHours != null) autoscanParts.push(`interval ${sample.autoscan.intervalHours}h`);
  if (sample.autoscan.adaptiveIntervalApplied != null) {
    autoscanParts.push(`adaptive ${sample.autoscan.adaptiveIntervalApplied ? "on" : "off"}`);
  }
  if (sample.autoscan.nextDueAt) autoscanParts.push(`next due ${sample.autoscan.nextDueAt}`);
  if (sample.defaults.hasPendingScopeChanges != null) {
    autoscanParts.push(`pending-scope ${sample.defaults.hasPendingScopeChanges ? "yes" : "no"}`);
  }
  console.log(`config    ${autoscanParts.join("  ")}`);

  if (sample.notes.length > 0) {
    for (const note of sample.notes) {
      console.log(`note      ${note}`);
    }
  }

  if (sample.warnings.length === 0) {
    console.log("status    OK");
  } else {
    for (const warning of sample.warnings) {
      console.log(`warn      ${warning}`);
    }
  }
}

function signedBytes(value) {
  const prefix = value > 0 ? "+" : "";
  return `${prefix}${formatBytes(value)}`;
}

function signedNumber(value) {
  return `${value > 0 ? "+" : ""}${value.toLocaleString()}`;
}

function workingSetSummary() {
  const rows = readWorkingSet();
  return rows[0] ?? null;
}

function workingSetSummaryForTrackedPath(trackedPathId) {
  const normalized = normalizeUuid(trackedPathId);
  return readWorkingSet().find((row) => normalizeUuid(row.trackedPathId) === normalized) ?? null;
}

function categorySummaryForTrackedPath(trackedPathId) {
  const normalized = normalizeUuid(trackedPathId);
  const rows = readCategoryTotals().filter((row) => normalizeUuid(row.trackedPathId) === normalized);
  const totalBytes = rows.reduce((sum, row) => sum + Number(row.totalBytes), 0);
  const updatedAtDate = rows.reduce((latest, row) => {
    if (!row.updatedAtDate) return latest;
    return !latest || row.updatedAtDate > latest ? row.updatedAtDate : latest;
  }, null);

  return {
    rowCount: rows.length,
    totalBytes,
    updatedAt: updatedAtDate ? updatedAtDate.toISOString() : null,
    updatedAtDate
  };
}

function configuredTrackedPathMap(defaults) {
  const result = new Map();
  result.set(normalizeUuid(MAIN_BASE_PATH_ID), defaults.mainBasePath || os.homedir());

  for (const trackedPath of decodeCustomTrackedPaths(defaults.trackedPathsData)) {
    const id = trackedPath.id;
    const urlPath = pathFromEncodedURL(trackedPath.url);
    if (id && urlPath) {
      result.set(normalizeUuid(id), urlPath);
    }
  }

  return result;
}

function decodeCustomTrackedPaths(dataValue) {
  if (!dataValue) return [];
  try {
    const json = Buffer.from(dataValue, "base64").toString("utf8");
    const decoded = JSON.parse(json);
    return Array.isArray(decoded) ? decoded : [];
  } catch {
    return [];
  }
}

function pathFromEncodedURL(value) {
  if (!value) return null;
  if (typeof value === "string") {
    if (value.startsWith("file://")) {
      return decodeURIComponent(new URL(value).pathname);
    }
    return value;
  }
  return null;
}

function normalizeUuid(value) {
  return String(value ?? "").toLowerCase();
}

function allocatedBytesForPath(filePath) {
  const stats = fs.statSync(filePath);
  if (Number.isFinite(stats.blocks) && stats.blocks > 0) {
    return stats.blocks * 512;
  }
  return stats.size;
}

function deriveFreshnessProbeTarget(options, baseline) {
  const trackedPathId = baseline.trackedPathId;
  if (options.freshnessProbeDir) {
    return {
      trackedPathId,
      rootPath: null,
      probeDir: path.resolve(options.freshnessProbeDir)
    };
  }

  const defaults = readDefaults();
  const pathsById = configuredTrackedPathMap(defaults);
  const rootPath = pathsById.get(normalizeUuid(trackedPathId));
  if (!rootPath) {
    console.error(
      `freshness probe: cannot derive filesystem root for trackedPathId=${trackedPathId}; pass --freshness-dir under that tracked path`
    );
    process.exit(2);
  }

  return {
    trackedPathId,
    rootPath,
    probeDir: path.join(rootPath, "prunr-monitor-probe")
  };
}

async function runFreshnessProbe(options) {
  const baseline = workingSetSummary();
  if (!baseline) {
    console.error("freshness probe: no workingSet rows; run an initial scan first");
    process.exit(2);
  }
  const target = deriveFreshnessProbeTarget(options, baseline);
  const baselineCategory = categorySummaryForTrackedPath(target.trackedPathId);
  if (baselineCategory.rowCount === 0) {
    console.error(`freshness probe: no workingSetCategoryTotal rows for trackedPathId=${target.trackedPathId}`);
    process.exit(2);
  }

  const probeDir = target.probeDir;
  fs.mkdirSync(probeDir, { recursive: true });

  const probeFile = path.join(
    probeDir,
    `freshness-${Date.now()}-${process.pid}.bin`
  );
  const probeBytes = options.freshnessProbeBytes;

  console.log(`[probe] trackedPathId=${target.trackedPathId} root=${target.rootPath ?? "(custom --freshness-dir)"}`);
  console.log(`[probe] baseline working rows=${baseline.rowCount} bytes=${baseline.totalBytes} updatedAt=${baseline.updatedAt}`);
  console.log(`[probe] baseline categories rows=${baselineCategory.rowCount} bytes=${baselineCategory.totalBytes} updatedAt=${baselineCategory.updatedAt}`);
  console.log(`[probe] writing ${probeBytes}B to ${probeFile}`);

  fs.writeFileSync(probeFile, randomBytes(probeBytes));
  const expectedProbeBytes = allocatedBytesForPath(probeFile);
  console.log(`[probe] allocated ${expectedProbeBytes}B on disk`);

  const start = Date.now();
  const deadline = start + options.freshnessTimeoutSeconds * 1000;
  let detected = null;
  while (Date.now() < deadline) {
    await sleep(2000);
    const current = workingSetSummaryForTrackedPath(target.trackedPathId);
    const currentCategory = categorySummaryForTrackedPath(target.trackedPathId);
    if (!current) continue;

    const workingDelta = Number(current.totalBytes) - Number(baseline.totalBytes);
    const categoryDelta = Number(currentCategory.totalBytes) - Number(baselineCategory.totalBytes);
    if (workingDelta >= expectedProbeBytes && categoryDelta >= expectedProbeBytes) {
      detected = { observedAt: Date.now(), working: current, category: currentCategory };
      break;
    }
  }

  let exitCode = 0;
  if (detected) {
    const latencySeconds = Math.round((detected.observedAt - start) / 1000);
    const workingDelta = Number(detected.working.totalBytes) - Number(baseline.totalBytes);
    const categoryDelta = Number(detected.category.totalBytes) - Number(baselineCategory.totalBytes);
    console.log(
      `[probe] PASS detected probe within ${latencySeconds}s: workingRows=${detected.working.rowCount} workingBytes=${detected.working.totalBytes} workingDelta=${workingDelta} categoryBytes=${detected.category.totalBytes} categoryDelta=${categoryDelta}`
    );
  } else {
    const final = workingSetSummaryForTrackedPath(target.trackedPathId);
    const finalCategory = categorySummaryForTrackedPath(target.trackedPathId);
    console.error(
      `[probe] FAIL no working/category update after ${options.freshnessTimeoutSeconds}s; final working rows=${final?.rowCount} bytes=${final?.totalBytes} updatedAt=${final?.updatedAt}; final categories rows=${finalCategory.rowCount} bytes=${finalCategory.totalBytes} updatedAt=${finalCategory.updatedAt}`
    );
    exitCode = 1;
  }

  try {
    fs.rmSync(probeFile, { force: true });
  } catch {
    // best-effort cleanup
  }

  process.exit(exitCode);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));

  if (options.freshnessProbe) {
    await runFreshnessProbe(options);
    return;
  }

  const state = {
    stallSamples: 0,
    rssHistory: [],
    seenLogLines: new Set(),
    lastLogRefreshAt: 0,
    logSummary: {
      blockedLocations: [],
      permissionDeniedCount: 0,
      cacheDeleteErrorCount: 0
    }
  };

  let previous = null;
  let sampleCount = 0;

  while (true) {
    try {
      const sample = buildSample(previous, state, options);
      if (options.json) {
        const serializable = { ...sample };
        delete serializable.categoryMap;
        console.log(JSON.stringify(serializable));
      } else {
        printSample(sample);
      }

      previous = sample;
      sampleCount += 1;
    } catch (error) {
      if (options.samples) {
        throw error;
      }
      const message = `sample failed at ${new Date().toISOString()}: ${error.message}`;
      if (options.json) {
        console.log(JSON.stringify({ at: new Date().toISOString(), warnings: [message] }));
      } else {
        console.error(`warn      ${message}`);
      }
    }

    if (options.samples && sampleCount >= options.samples) break;
    await sleep(options.intervalSeconds * 1000);
  }
}

main().catch((error) => {
  console.error(`monitor failed: ${error.message}`);
  process.exit(1);
});
