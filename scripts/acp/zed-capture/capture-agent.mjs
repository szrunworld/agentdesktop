#!/usr/bin/env node
// Capture wrapper for the Zed manual step (docs/acp/tests/e2e-runbook.md §三.1).
//
// Zed starts this as its ACP agent. It starts the real agent command, copies
// every byte in both directions unchanged, and records them:
//
//   $ADT_ZED_CAPTURE_DIR/launch-<n>-<pid>/
//     editor-to-agent.bin   exact bytes Zed wrote to the agent's stdin
//     agent-to-editor.bin   exact bytes the agent wrote to stdout
//     chunks.jsonl          one line per read: time, direction, offset, length
//     frames.jsonl          one line per newline-terminated frame: time, direction, text
//     agent-stderr.log      the agent's stderr (also passed through)
//     exit.json             how the agent ended
//
// Environment (set by setup.sh in Zed's isolated settings):
//   ADT_ZED_CAPTURE_DIR   capture root (required; must be under /tmp/adt-)
//   ADT_AGENT_COMMAND     JSON array: the agent command, e.g. ["/path/agentdesktop-acp-dev","--demo"]
//
// Nothing is interpreted or rewritten: this is a tee, not a proxy.
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

function die(msg) {
  process.stderr.write(`adt-zed-capture: ${msg}\n`);
  process.exit(2);
}

const root = process.env.ADT_ZED_CAPTURE_DIR ?? "";
if (!root) die("ADT_ZED_CAPTURE_DIR is not set");
if (!resolve(root).startsWith("/tmp/adt-") && !resolve(root).startsWith("/private/tmp/adt-")) {
  die(`capture directory must be under /tmp/adt-* (got ${root})`);
}
let command;
try {
  command = JSON.parse(process.env.ADT_AGENT_COMMAND ?? "");
} catch {
  die("ADT_AGENT_COMMAND must be a JSON array");
}
if (!Array.isArray(command) || command.length === 0) die("ADT_AGENT_COMMAND must be a non-empty JSON array");

mkdirSync(root, { recursive: true, mode: 0o700 });
const n = readdirSync(root).filter((f) => f.startsWith("launch-")).length + 1;
const dir = join(root, `launch-${n}-${process.pid}`);
mkdirSync(dir, { recursive: true, mode: 0o700 });
const t0 = process.hrtime.bigint();
const stamp = () => ({ t: new Date().toISOString(), ms: Number((process.hrtime.bigint() - t0) / 1000000n) });
const w = (f, data) => appendFileSync(join(dir, f), data, { mode: 0o600 });
w("chunks.jsonl", "");
w("frames.jsonl", "");
w("editor-to-agent.bin", Buffer.alloc(0));
w("agent-to-editor.bin", Buffer.alloc(0));
writeFileSync(join(dir, "launch.json"), JSON.stringify({ ...stamp(), command, wrapperPid: process.pid }, null, 2) + "\n", { mode: 0o600 });

/// Per direction: byte offset and the bytes of an unfinished frame.
function recorder(direction, binFile) {
  let offset = 0;
  let pending = Buffer.alloc(0);
  return {
    chunk(buf) {
      const s = stamp();
      w(binFile, buf);
      w("chunks.jsonl", JSON.stringify({ ...s, dir: direction, offset, length: buf.length }) + "\n");
      offset += buf.length;
      pending = Buffer.concat([pending, buf]);
      let nl;
      while ((nl = pending.indexOf(0x0a)) >= 0) {
        const line = pending.subarray(0, nl);
        pending = pending.subarray(nl + 1);
        w("frames.jsonl", JSON.stringify({ ...s, dir: direction, bytes: line.length + 1, text: line.toString("utf8") }) + "\n");
      }
    },
    end() {
      if (pending.length) {
        w("frames.jsonl", JSON.stringify({ ...stamp(), dir: direction, bytes: pending.length, unterminated: true, text: pending.toString("utf8") }) + "\n");
      }
      w("chunks.jsonl", JSON.stringify({ ...stamp(), dir: direction, end: true, total: offset }) + "\n");
    },
  };
}

const toAgent = recorder("editor->agent", "editor-to-agent.bin");
const toEditor = recorder("agent->editor", "agent-to-editor.bin");

const child = spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "pipe"] });
child.on("error", (e) => {
  writeFileSync(join(dir, "exit.json"), JSON.stringify({ ...stamp(), spawnError: String(e) }) + "\n");
  die(`cannot start ${command[0]}: ${e}`);
});
child.stdin.on("error", () => {});
process.stdout.on("error", () => {});

process.stdin.on("data", (buf) => {
  toAgent.chunk(buf);
  child.stdin.write(buf);
});
process.stdin.on("end", () => {
  toAgent.end();
  child.stdin.end();
});
child.stdout.on("data", (buf) => {
  toEditor.chunk(buf);
  process.stdout.write(buf);
});
child.stdout.on("end", () => toEditor.end());
child.stderr.on("data", (buf) => {
  w("agent-stderr.log", buf);
  process.stderr.write(buf);
});
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(sig, () => {
    w("chunks.jsonl", JSON.stringify({ ...stamp(), signal: sig }) + "\n");
    child.kill(sig);
  });
}
child.on("close", (code, signal) => {
  writeFileSync(join(dir, "exit.json"), JSON.stringify({ ...stamp(), code, signal }) + "\n", { mode: 0o600 });
  // Let stdout drain before leaving.
  process.stdout.write("", () => process.exit(code ?? (signal ? 1 : 0)));
});
