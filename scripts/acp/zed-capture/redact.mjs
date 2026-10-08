#!/usr/bin/env node
// Used by collect.sh: summarise a Zed capture and write a redacted copy to
// <capture>/redacted/. Paths, the user name and the host name are replaced;
// raw byte files are not copied (sizes and SHA-256 only).
//
//   node redact.mjs <capture-dir> <repo-root>
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { homedir, hostname, userInfo } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const [cap, repo] = process.argv.slice(2);
if (!cap || !repo) {
  console.error("usage: redact.mjs <capture-dir> <repo-root>");
  process.exit(2);
}
const out = join(cap, "redacted");
mkdirSync(out, { recursive: true, mode: 0o700 });

const user = userInfo().username;
const host = hostname().replace(/\.local$/, "");
const pairs = [
  [realpathSync(cap), "<capture>"],
  [cap, "<capture>"],
  [realpathSync(repo), "<repo>"],
  [repo, "<repo>"],
  [homedir(), "~"],
];
const words = [
  [user, "<user>"],
  [host, "<host>"],
];
function redact(s) {
  for (const [a, b] of pairs.sort((x, y) => y[0].length - x[0].length)) s = s.split(a).join(b);
  for (const [a, b] of words) if (a && a.length >= 3) s = s.replace(new RegExp(a.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), b);
  return s;
}
const sha = (f) => createHash("sha256").update(readFileSync(f)).digest("hex");
const readLines = (f) => (existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean) : []);
const parse = (s) => {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
};

let zedVersion = "";
try {
  zedVersion = execFileSync(process.env.ZED_CLI || "zed", ["--version"], { encoding: "utf8" }).trim();
} catch {}

const framesRoot = join(cap, "frames");
const launches = existsSync(framesRoot) ? readdirSync(framesRoot).filter((d) => d.startsWith("launch-")).sort() : [];
const summary = { zed: redact(zedVersion), capturedAt: new Date().toISOString(), launches: [] };
const firstInit = { request: null, response: null };

for (const l of launches) {
  const src = join(framesRoot, l);
  const dst = join(out, l);
  mkdirSync(dst, { recursive: true });
  const frames = readLines(join(src, "frames.jsonl")).map((x) => JSON.parse(x));
  writeFileSync(join(dst, "frames.redacted.jsonl"), frames.map((f) => redact(JSON.stringify(f))).join("\n") + "\n");
  writeFileSync(join(dst, "chunks.jsonl"), readLines(join(src, "chunks.jsonl")).join("\n") + "\n");
  for (const f of ["exit.json", "agent-stderr.log"]) {
    if (existsSync(join(src, f))) writeFileSync(join(dst, f.replace(".log", ".redacted.log")), redact(readFileSync(join(src, f), "utf8")));
  }
  const raw = {};
  for (const f of ["editor-to-agent.bin", "agent-to-editor.bin"]) {
    const p = join(src, f);
    if (existsSync(p)) raw[f] = { bytes: readFileSync(p).length, sha256: sha(p) };
  }
  // Protocol facts.
  const msgs = frames.map((f) => ({ ...f, msg: parse(f.text) }));
  const init = msgs.find((m) => m.dir === "editor->agent" && m.msg?.method === "initialize");
  const initResp = init && msgs.find((m) => m.dir === "agent->editor" && m.msg && m.msg.id === init.msg.id && ("result" in m.msg || "error" in m.msg));
  const sentBeforeInitReply = init
    ? msgs.filter((m) => m.dir === "editor->agent" && m.msg?.method && m.msg.method !== "initialize" && (!initResp || m.ms < initResp.ms) && m.ms >= init.ms).map((m) => m.msg.method)
    : [];
  const methods = msgs.filter((m) => m.msg?.method).map((m) => ({ ms: m.ms, dir: m.dir, method: m.msg.method, id: m.msg.id ?? null }));
  const unparseable = msgs.filter((m) => m.msg === undefined).length;
  if (init && !firstInit.request) {
    firstInit.request = init.msg;
    firstInit.response = initResp?.msg ?? null;
  }
  summary.launches.push({
    launch: l,
    frames: { editorToAgent: msgs.filter((m) => m.dir === "editor->agent").length, agentToEditor: msgs.filter((m) => m.dir === "agent->editor").length, unparseable },
    requestedProtocolVersion: init?.msg?.params?.protocolVersion ?? null,
    answeredProtocolVersion: initResp?.msg?.result?.protocolVersion ?? null,
    clientInfo: init?.msg?.params?.clientInfo ?? null,
    clientCapabilities: init?.msg?.params?.clientCapabilities ?? null,
    initializeRoundTripMs: init && initResp ? initResp.ms - init.ms : null,
    requestsSentBeforeInitializeReply: sentBeforeInitReply,
    methods,
    raw,
    exit: parse(existsSync(join(src, "exit.json")) ? readFileSync(join(src, "exit.json"), "utf8") : "") ?? null,
  });
}
writeFileSync(join(out, "initialize.json"), redact(JSON.stringify(firstInit, null, 2)) + "\n");
writeFileSync(join(out, "summary.json"), redact(JSON.stringify(summary, null, 2)) + "\n");

// Zed's own log, only lines about agents / ACP.
const zedLog = join(cap, "zed-data", "logs", "Zed.log");
if (existsSync(zedLog)) {
  const lines = readFileSync(zedLog, "utf8").split("\n").filter((x) => /acp|agent_server|agent server|external agent|AgentDesktop|capture-agent/i.test(x));
  writeFileSync(join(out, "zed-log-excerpt.redacted.txt"), redact(lines.slice(-300).join("\n")) + "\n");
}

// Nothing identifying may be left.
const leaks = [];
const scan = (d) => {
  for (const f of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, f.name);
    if (f.isDirectory()) scan(p);
    else {
      const s = readFileSync(p, "utf8");
      for (const needle of [homedir(), user, host].filter((x) => x && x.length >= 3)) if (s.toLowerCase().includes(needle.toLowerCase())) leaks.push(`${p}: ${needle === user ? "<user>" : needle === host ? "<host>" : "<home>"}`);
    }
  }
};
scan(out);
if (leaks.length) {
  console.error("redaction incomplete, not usable as evidence:\n" + leaks.join("\n"));
  process.exit(1);
}

console.log(`launches: ${launches.length}`);
for (const l of summary.launches) {
  console.log(`${l.launch}: initialize requested v${l.requestedProtocolVersion} answered v${l.answeredProtocolVersion}; client ${l.clientInfo ? `${l.clientInfo.name} ${l.clientInfo.version}` : "?"}; frames in/out ${l.frames.editorToAgent}/${l.frames.agentToEditor}; sent before initialize reply: ${l.requestsSentBeforeInitializeReply.join(", ") || "none"}`);
}
if (!firstInit.request) {
  console.log("no initialize frame captured: did Zed start the agent? (Agent panel → New Thread → AgentDesktop (dev demo))");
  process.exit(1);
}
console.log(`redacted copy: ${join(out)}`);
