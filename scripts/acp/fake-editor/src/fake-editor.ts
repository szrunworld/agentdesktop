#!/usr/bin/env node
// Fake editor: a scripted ACP client (official @agentclientprotocol/sdk,
// stable v1 surface) that launches an agent command over stdio, runs JSON
// scenarios, records a transcript and asserts expectations.
//
//   node dist/fake-editor.js --profile profiles/echo.json \
//        --scenario scenarios/t01-valid-requests.json [--scenario ...] \
//        [--agent "<command> <args>"] [--env KEY=VALUE]... --out <dir>
//
// Exit code: 0 when every scenario is PASS or BLOCKED, 1 when any FAILs,
// 2 on a usage or scenario-file error. See docs/acp/tests/README.md.
import * as acp from "@agentclientprotocol/sdk";
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// MARK: types

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Step = { op: string; [k: string]: any };
type Scenario = { id: string; cases: string[]; title: string; requires?: string[]; steps: Step[] };
type Profile = {
  name: string;
  agent: string[];
  cwd?: string;
  env?: Record<string, string>;
  identities?: Record<string, Record<string, string>>;
  features: string[];
  vars: Record<string, string>;
};
type Recorded = { conn: number; t: number; sessionId: string; update: any };
type PermissionRecord = { conn: number; t: number; sessionId: string; toolCallId: string; optionKinds: string[]; answer: string };

class StepFailure extends Error {}

const here = dirname(fileURLToPath(import.meta.url));
const editorRoot = resolve(here, "..");
const repoRoot = resolve(editorRoot, "../../..");

// MARK: connection

/// One spawned agent process and its ACP client connection. Every frame in
/// both directions goes through `log`, so the transcript is complete.
class QTestConnection {
  child: ChildProcess;
  sdk: acp.ClientSideConnection;
  exit: Promise<{ code: number | null; signal: string | null }>;
  exited: { code: number | null; signal: string | null } | null = null;
  private rawWaiters = new Map<string, (m: any) => void>();
  rawUnmatched: any[] = [];
  unparseable: string[] = [];
  private enqueue!: (m: any) => void;
  private closeReadable!: () => void;
  permissionPolicy = "deny";

  constructor(
    readonly index: number,
    readonly cmd: string[],
    env: Record<string, string>,
    cwd: string,
    private log: (entry: any) => void,
    private onUpdate: (r: Recorded) => void,
    private onPermission: (r: PermissionRecord) => void,
  ) {
    this.child = spawn(cmd[0], cmd.slice(1), { cwd, env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    this.exit = new Promise((res) =>
      this.child.on("exit", (code, signal) => {
        this.exited = { code, signal };
        log({ conn: index, dir: "exit", code, signal });
        res(this.exited);
      }),
    );
    this.child.on("error", (e) => log({ conn: index, dir: "spawn-error", message: String(e) }));
    this.child.stderr!.on("data", (d) => log({ conn: index, dir: "stderr", text: String(d).slice(0, 4000) }));
    this.child.stdin!.on("error", () => {});

    const readable = new ReadableStream<any>({
      start: (c) => {
        this.enqueue = (m) => c.enqueue(m);
        this.closeReadable = () => {
          try { c.close(); } catch {}
        };
      },
    });
    const writable = new WritableStream<any>({
      write: (m) => {
        log({ conn: index, dir: "out", msg: m });
        if (!this.child.stdin!.destroyed) this.child.stdin!.write(JSON.stringify(m) + "\n");
      },
    });
    let buf = "";
    this.child.stdout!.on("data", (d) => {
      buf += String(d);
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) this.incoming(line);
      }
    });
    this.child.stdout!.on("end", () => this.closeReadable());

    this.sdk = new acp.ClientSideConnection(() => this.client(), { readable, writable });
  }

  private incoming(line: string) {
    let m: any;
    try {
      m = JSON.parse(line);
    } catch {
      this.unparseable.push(line.slice(0, 200));
      this.log({ conn: this.index, dir: "in-unparseable", raw: line.slice(0, 2000) });
      return;
    }
    this.log({ conn: this.index, dir: "in", msg: m });
    const isResponse = m && typeof m === "object" && !("method" in m) && ("result" in m || "error" in m);
    if (isResponse && (m.id === null || (typeof m.id === "string" && m.id.startsWith("raw-")))) {
      const key = String(m.id);
      const w = this.rawWaiters.get(key);
      if (w) {
        this.rawWaiters.delete(key);
        w(m);
      } else this.rawUnmatched.push(m);
      return;
    }
    this.enqueue(m);
  }

  private client(): acp.Client {
    return {
      sessionUpdate: async (p) => {
        this.onUpdate({ conn: this.index, t: Date.now(), sessionId: p.sessionId, update: p.update });
      },
      requestPermission: async (p) => {
        const kinds = p.options.map((o) => o.kind);
        const policy = this.permissionPolicy;
        this.onPermission({ conn: this.index, t: Date.now(), sessionId: p.sessionId, toolCallId: p.toolCall.toolCallId, optionKinds: kinds, answer: policy });
        const pick = (k: string) => p.options.find((o) => o.kind === k);
        switch (policy) {
          case "allow": {
            const o = pick("allow_once");
            if (!o) return { outcome: { outcome: "cancelled" } };
            return { outcome: { outcome: "selected", optionId: o.optionId } };
          }
          case "deny": {
            const o = pick("reject_once");
            if (!o) return { outcome: { outcome: "cancelled" } };
            return { outcome: { outcome: "selected", optionId: o.optionId } };
          }
          case "cancelled":
            return { outcome: { outcome: "cancelled" } };
          case "none":
            // An editor without a permission UI.
            throw acp.RequestError.methodNotFound("session/request_permission");
          case "hang":
            return new Promise(() => {});
          default:
            throw new Error(`unknown permission policy ${policy}`);
        }
      },
    };
  }

  /// Bytes the SDK would never produce (malformed frames, unknown ids).
  raw(text: string, id: string | null): Promise<any> {
    const key = String(id);
    const p = new Promise<any>((res) => this.rawWaiters.set(key, res));
    this.log({ conn: this.index, dir: "out-raw", raw: text.length > 2000 ? `${text.slice(0, 200)}…(${text.length} bytes)` : text });
    if (!this.child.stdin!.destroyed) this.child.stdin!.write(text.endsWith("\n") ? text : text + "\n");
    return p;
  }

  disconnect(mode: string) {
    this.log({ conn: this.index, dir: "disconnect", mode });
    if (mode === "kill") this.child.kill("SIGKILL");
    else this.child.stdin!.end();
  }
}

// MARK: helpers

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function within<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout;
  const t = new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new StepFailure(`timeout after ${ms} ms: ${what}`)), ms)));
  try {
    return await Promise.race([p, t]);
  } finally {
    clearTimeout(timer!);
  }
}

/// `expected` is a subset of `actual` (objects by key, arrays by position).
function subset(expected: any, actual: any): boolean {
  if (expected === null || typeof expected !== "object") return expected === actual;
  if (Array.isArray(expected)) return Array.isArray(actual) && expected.every((e, i) => subset(e, actual[i]));
  if (actual === null || typeof actual !== "object") return false;
  return Object.keys(expected).every((k) => subset(expected[k], actual[k]));
}

function substitute(v: any, vars: Record<string, string>): any {
  if (typeof v === "string") {
    return v.replace(/\$\{([A-Z0-9_]+)\}/g, (m, k) => {
      if (!(k in vars)) throw new Error(`scenario uses \${${k}} but the profile does not define it`);
      return vars[k];
    });
  }
  if (Array.isArray(v)) return v.map((x) => substitute(x, vars));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, substitute(x, vars)]));
  return v;
}

/// Scenario values may come from string profile vars ("true", "600", "[1]").
const flag = (v: any) => v === true || v === "true";
const num = (v: any) => (v === undefined ? undefined : Number(v));
const list = (v: any) => (typeof v === "string" ? JSON.parse(v) : v);

const CRASH_SIGNALS = new Set(["SIGSEGV", "SIGABRT", "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP"]);

// MARK: runner

class QTestScenarioRun {
  conns: QTestConnection[] = [];
  current?: QTestConnection;
  sessions = new Map<string, string>();
  updates: Recorded[] = [];
  permissions: PermissionRecord[] = [];
  marks = new Map<string, { updates: number; t: number }>();
  initResult: any;
  failures: string[] = [];
  stepLog: any[] = [];
  private t0 = Date.now();

  constructor(private sc: Scenario, private profile: Profile, private outDir: string, private vars: Record<string, string>) {}

  private log = (entry: any) => {
    appendFileSync(join(this.outDir, "transcript.jsonl"), JSON.stringify({ ms: Date.now() - this.t0, ...entry }) + "\n");
  };

  private conn(): QTestConnection {
    if (!this.current) throw new StepFailure("no connection: add a connect step");
    return this.current;
  }
  private sid(name: string): string {
    const s = this.sessions.get(name);
    if (s) return s;
    if (name.startsWith("literal:")) return name.slice(8);
    throw new StepFailure(`unknown session name ${name}`);
  }
  private check(cond: boolean, msg: string) {
    if (!cond) throw new StepFailure(msg);
  }

  /// Common expectations on a request outcome.
  private expectResponse(e: any, r: { ok: boolean; result?: any; error?: any }, what: string) {
    if (e && flag(e.allowError) && !r.ok) return;
    if (!e) {
      this.check(r.ok, `${what}: unexpected error ${JSON.stringify(r.error)}`);
      return;
    }
    if (e.ok !== undefined) this.check(r.ok === e.ok, `${what}: expected ok=${e.ok}, got ${r.ok ? "result" : "error " + JSON.stringify(r.error)}`);
    if (e.errorCode !== undefined) this.check(!r.ok && r.error?.code === e.errorCode, `${what}: expected error ${e.errorCode}, got ${JSON.stringify(r.error ?? r.result)}`);
    if (e.errorCodeIn !== undefined) this.check(!r.ok && e.errorCodeIn.includes(r.error?.code), `${what}: expected error in ${e.errorCodeIn}, got ${JSON.stringify(r.error ?? r.result)}`);
    if (e.result !== undefined) this.check(r.ok && subset(e.result, r.result), `${what}: result ${JSON.stringify(r.result)} does not contain ${JSON.stringify(e.result)}`);
    if (e.protocolVersionIn !== undefined) this.check(r.ok && list(e.protocolVersionIn).includes(r.result?.protocolVersion), `${what}: protocolVersion ${r.result?.protocolVersion} not in ${e.protocolVersionIn}`);
  }

  private async call(p: Promise<any>, ms: number, what: string) {
    try {
      return { ok: true, result: await within(p, ms, what) };
    } catch (err: any) {
      if (err instanceof StepFailure) throw err;
      return { ok: false, error: { code: err?.code, message: String(err?.message ?? err) } };
    }
  }

  private turnText(sessionId: string, fromIndex: number) {
    return this.updates
      .slice(fromIndex)
      .filter((u) => u.sessionId === sessionId && u.update.sessionUpdate === "agent_message_chunk" && u.update.content?.type === "text")
      .map((u) => u.update.content.text)
      .join("");
  }

  private async prompt(s: Step) {
    const c = this.conn();
    const sessionId = this.sid(s.session);
    c.permissionPolicy = s.permission ?? "deny";
    const fromU = this.updates.length;
    const fromP = this.permissions.length;
    const content = s.content ?? [{ type: "text", text: s.text }];
    const started = c.sdk.prompt({ sessionId, prompt: content });
    if (s.cancelAfterMs !== undefined) {
      s.cancelAfterMs = num(s.cancelAfterMs);
      setTimeout(() => {
        this.log({ conn: c.index, dir: "note", note: `cancel ${sessionId}` });
        c.sdk.cancel({ sessionId }).catch(() => {});
      }, s.cancelAfterMs);
    }
    if (s.disconnectAfterMs !== undefined) setTimeout(() => c.disconnect(s.disconnectMode ?? "close-stdin"), num(s.disconnectAfterMs));
    let outcome: string;
    let error: any;
    try {
      const r = await within(started, s.timeoutMs ?? 20000, `prompt ${s.text ?? ""}`);
      outcome = r.stopReason;
    } catch (err: any) {
      if (err instanceof StepFailure) throw err;
      outcome = s.disconnectAfterMs !== undefined ? "disconnected" : "error";
      error = { code: err?.code, message: String(err?.message ?? err) };
    }
    this.stepLog.push({ op: "prompt", text: s.text, outcome, error });
    const e = s.expect ?? {};
    if (e.stopReason !== undefined) this.check(outcome === e.stopReason, `prompt: stopReason ${outcome} (${JSON.stringify(error)}), expected ${e.stopReason}`);
    if (e.stopReasonIn !== undefined) this.check(list(e.stopReasonIn).includes(outcome), `prompt: stopReason ${outcome} not in ${e.stopReasonIn}`);
    if (e.errorCode !== undefined) this.check(error?.code === e.errorCode, `prompt: expected error ${e.errorCode}, got ${JSON.stringify(error ?? outcome)}`);
    await this.turnChecks(e, sessionId, fromU, fromP);
  }

  private async turnChecks(e: any, sessionId: string, fromU: number, fromP: number) {
    const mine = this.updates.slice(fromU).filter((u) => u.sessionId === sessionId);
    const kinds = new Set(mine.map((u) => u.update.sessionUpdate));
    for (const k of e.updatesInclude ?? []) this.check(kinds.has(k), `turn: no ${k} update (saw ${[...kinds]})`);
    for (const k of e.updatesExclude ?? []) this.check(!kinds.has(k), `turn: unexpected ${k} update`);
    const text = this.turnText(sessionId, fromU);
    for (const t of e.textIncludes ?? []) this.check(text.includes(t), `turn: text lacks "${t}" (got "${text.slice(0, 200)}")`);
    for (const t of e.textExcludes ?? []) this.check(!text.includes(t), `turn: text contains "${t}"`);
    if (e.textMatches) this.check(new RegExp(e.textMatches).test(text), `turn: text "${text.slice(0, 200)}" does not match /${e.textMatches}/`);
    const perms = this.permissions.slice(fromP).filter((p) => p.sessionId === sessionId);
    if (e.permissionRequested !== undefined) this.check((perms.length > 0) === e.permissionRequested, `turn: permissionRequested=${perms.length > 0}, expected ${e.permissionRequested}`);
    if (e.permissionOptionKinds) {
      const want = [...e.permissionOptionKinds].sort().join(",");
      for (const p of perms) this.check([...p.optionKinds].sort().join(",") === want, `turn: permission options ${p.optionKinds} != ${want}`);
    }
    const status = new Map<string, string>();
    for (const u of mine) if (u.update.toolCallId && u.update.status) status.set(u.update.toolCallId, u.update.status);
    if (e.deniedToolsNotCompleted) {
      for (const p of perms.filter((p) => p.answer !== "allow")) {
        this.check(status.get(p.toolCallId) !== "completed", `turn: tool ${p.toolCallId} completed although the answer was ${p.answer}`);
      }
    }
    if (e.allowedToolsCompleted) {
      for (const p of perms.filter((p) => p.answer === "allow")) {
        this.check(status.get(p.toolCallId) === "completed", `turn: allowed tool ${p.toolCallId} ended ${status.get(p.toolCallId)}`);
      }
    }
    if (e.minToolCalls !== undefined) {
      const n = new Set(mine.filter((u) => u.update.sessionUpdate === "tool_call").map((u) => u.update.toolCallId)).size;
      this.check(n >= e.minToolCalls, `turn: ${n} tool calls < ${e.minToolCalls}`);
    }
    if (e.quietAfterMs !== undefined) {
      const before = this.updates.length;
      await sleep(e.quietAfterMs);
      const late = this.updates.slice(before).filter((u) => u.sessionId === sessionId && ["tool_call", "tool_call_update"].includes(u.update.sessionUpdate));
      this.check(late.length === 0, `turn: ${late.length} tool updates within ${e.quietAfterMs} ms after the turn ended`);
    }
  }

  async run(): Promise<"PASS" | "FAIL" | "BLOCKED"> {
    mkdirSync(this.outDir, { recursive: true });
    writeFileSync(join(this.outDir, "transcript.jsonl"), "");
    const missing = (this.sc.requires ?? []).filter((r) => !this.profile.features.includes(r));
    if (missing.length) {
      this.failures.push(`blocked: profile ${this.profile.name} lacks ${missing.join(", ")}`);
      return "BLOCKED";
    }
    let status: "PASS" | "FAIL" = "PASS";
    try {
      for (const raw of this.sc.steps) {
        const s = substitute(raw, this.vars);
        this.log({ dir: "step", step: s.op, at: s });
        await this.step(s);
      }
    } catch (err: any) {
      this.failures.push(err instanceof StepFailure ? err.message : `runner error: ${err?.stack ?? err}`);
      status = "FAIL";
    } finally {
      for (const c of this.conns) if (!c.exited) c.child.kill("SIGKILL");
    }
    for (const c of this.conns) {
      if (c.unparseable.length) {
        this.failures.push(`connection ${c.index}: ${c.unparseable.length} non-ACP lines on stdout (stdout must carry only ACP frames)`);
        status = "FAIL";
      }
    }
    return status;
  }

  private async step(s: Step) {
    const ms = s.timeoutMs ?? 15000;
    switch (s.op) {
      case "connect": {
        const env = { ...(this.profile.env ?? {}) };
        if (s.identity) {
          const id = this.profile.identities?.[s.identity];
          if (!id) throw new StepFailure(`profile has no identity ${s.identity}`);
          Object.assign(env, id);
        }
        const c = new QTestConnection(
          this.conns.length + 1,
          this.profile.agent,
          substitute(env, this.vars),
          this.profile.cwd ?? editorRoot,
          this.log,
          (r) => this.updates.push(r),
          (r) => this.permissions.push(r),
        );
        this.conns.push(c);
        this.current = c;
        return;
      }
      case "initialize": {
        const r = await this.call(
          this.conn().sdk.initialize({
            protocolVersion: s.protocolVersion ?? acp.PROTOCOL_VERSION,
            clientCapabilities: s.clientCapabilities ?? { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
            clientInfo: { name: "agentdesktop-fake-editor", version: "0.1.0" },
          }),
          ms,
          "initialize",
        );
        if (r.ok) this.initResult = r.result;
        this.expectResponse(s.expect, r, "initialize");
        return;
      }
      case "newSession": {
        const r = await this.call(this.conn().sdk.newSession({ cwd: s.cwd ?? this.vars.RUN_DIR, mcpServers: [] }), ms, "session/new");
        this.expectResponse(s.expect, r, "session/new");
        if (r.ok && s.as) this.sessions.set(s.as, r.result.sessionId);
        return;
      }
      case "prompt":
        return this.prompt(s);
      case "promptParallel": {
        const c = this.conn();
        c.permissionPolicy = s.permission ?? "deny";
        const fromU = this.updates.length;
        const runs = (s.prompts as Step[]).map((p) =>
          this.call(c.sdk.prompt({ sessionId: this.sid(p.session), prompt: [{ type: "text", text: p.text }] }), p.timeoutMs ?? 20000, `prompt ${p.text}`),
        );
        const results = await Promise.all(runs);
        (s.prompts as Step[]).forEach((p, i) => {
          const r = results[i];
          this.check(r.ok && r.result.stopReason === (p.expect?.stopReason ?? "end_turn"), `parallel prompt ${p.session}: ${JSON.stringify(r)}`);
          const sid = this.sid(p.session);
          const text = this.turnText(sid, fromU);
          this.check(text.includes(p.marker), `parallel prompt ${p.session}: own marker ${p.marker} missing`);
          for (const other of s.prompts as Step[]) {
            if (other !== p) this.check(!text.includes(other.marker), `cross-talk: session ${p.session} received ${other.marker}`);
          }
        });
        const known = new Set((s.prompts as Step[]).map((p) => this.sid(p.session)));
        const stray = this.updates.slice(fromU).filter((u) => !known.has(u.sessionId));
        this.check(stray.length === 0, `parallel: ${stray.length} updates for sessions outside the turn`);
        return;
      }
      case "listSessions": {
        const r = await this.call(this.conn().sdk.listSessions({}), ms, "session/list");
        this.expectResponse(s.expect?.ok === false || s.expect?.errorCode !== undefined ? s.expect : undefined, r, "session/list");
        if (r.ok) {
          const ids = new Set((r.result.sessions ?? []).map((x: any) => x.sessionId));
          for (const n of s.expect?.contains ?? []) this.check(ids.has(this.sid(n)), `session/list lacks ${n}`);
          for (const n of s.expect?.excludes ?? []) this.check(!ids.has(this.sid(n)), `session/list shows ${n}`);
        }
        return;
      }
      case "resume": {
        const method = s.method ?? this.vars.RESUME_METHOD ?? "load";
        const sessionId = this.sid(s.session);
        const fromU = this.updates.length;
        const c = this.conn();
        const p =
          method === "load"
            ? c.sdk.loadSession({ sessionId, cwd: s.cwd ?? this.vars.RUN_DIR, mcpServers: [] })
            : c.sdk.resumeSession({ sessionId, cwd: s.cwd ?? this.vars.RUN_DIR, mcpServers: [] });
        const r = await this.call(p, ms, `session/${method}`);
        // History streamed before the response vs. after it (session/load
        // is expected to replay first, then answer).
        const beforeResponse = this.updates.slice(fromU).filter((u) => u.sessionId === sessionId).length;
        this.expectResponse(s.expect, r, `session/${method}`);
        if (s.expect?.replayBeforeResponse) {
          this.check(beforeResponse > 0, `session/${method}: no history update arrived before the response`);
        }
        if (s.expect?.replayIncludes) {
          const want: string[] = s.expect.replayIncludes;
          const deadline = Date.now() + (num(s.expect.replayWithinMs) ?? 0);
          let text = this.turnText(sessionId, fromU);
          while (!want.every((t) => text.includes(t)) && Date.now() < deadline) {
            await sleep(50);
            text = this.turnText(sessionId, fromU);
          }
          for (const t of want) this.check(text.includes(t), `replay lacks "${t}" (got "${text.slice(0, 300)}")`);
        }
        this.stepLog.push({ op: `session/${method}`, updatesBeforeResponse: beforeResponse, updatesAfterResponse: this.updates.slice(fromU).filter((u) => u.sessionId === sessionId).length - beforeResponse });
        if (s.expect?.noReplay) {
          const n = this.updates.slice(fromU).filter((u) => u.conn === c.index).length;
          this.check(n === 0, `rejected resume still streamed ${n} updates`);
        }
        return;
      }
      case "closeSession": {
        const r = await this.call(this.conn().sdk.closeSession({ sessionId: this.sid(s.session) }), ms, "session/close");
        this.expectResponse(s.expect, r, "session/close");
        return;
      }
      case "disconnect":
        this.conn().disconnect(s.mode ?? "close-stdin");
        return;
      case "expectExit": {
        const c = this.conn();
        const r = await within(c.exit, s.withinMs ?? 5000, "agent exit after disconnect");
        this.check(!(r.signal && CRASH_SIGNALS.has(r.signal)), `agent crashed with ${r.signal}`);
        if (s.code !== undefined) this.check(r.code === s.code, `agent exit code ${r.code}, expected ${s.code}`);
        return;
      }
      case "expectAlive": {
        await sleep(s.ms ?? 300);
        this.check(!this.conn().exited, `agent exited: ${JSON.stringify(this.conn().exited)}`);
        return;
      }
      case "rawBatch": {
        // Several frames written back to back without waiting for any reply
        // (pipelining). Each item: {id, line, expect: {ok | errorCode}}.
        const c = this.conn();
        const items = s.items as Step[];
        const waits = items.map((it) => c.raw(it.line, it.id));
        const got = await Promise.all(waits.map((w, i) => Promise.race([w, sleep(num(s.waitMs) ?? 5000).then(() => ({ timeout: true, id: items[i].id }))])));
        this.stepLog.push({ op: "rawBatch", got });
        items.forEach((it, i) => {
          const m: any = got[i];
          this.check(!m.timeout, `rawBatch ${it.id}: no response`);
          if (it.expect?.ok === true) this.check(!!m.result, `rawBatch ${it.id}: expected a result, got ${JSON.stringify(m)}`);
          if (it.expect?.errorCode !== undefined) this.check(m.error?.code === it.expect.errorCode, `rawBatch ${it.id}: expected error ${it.expect.errorCode}, got ${JSON.stringify(m)}`);
        });
        return;
      }
      case "raw": {
        const c = this.conn();
        let text: string = s.line;
        if (s.oversizeBytes) {
          text = JSON.stringify({ jsonrpc: "2.0", id: s.id ?? null, method: "session/prompt", params: { sessionId: "x", prompt: [{ type: "text", text: "a".repeat(num(s.oversizeBytes)!) }] } });
        }
        const e = s.expect ?? {};
        const got = await Promise.race([
          c.raw(text, s.id ?? null).then((m) => ({ kind: "response", m })),
          c.exit.then((x) => ({ kind: "closed", m: x })),
          sleep(e.waitMs ?? 2000).then(() => ({ kind: "none", m: null })),
        ]);
        this.stepLog.push({ op: "raw", got });
        if (got.kind === "closed") {
          this.check(flag(e.allowClose), `raw: agent closed the connection (${JSON.stringify(got.m)})`);
          this.check(!(got.m as any).signal || !CRASH_SIGNALS.has((got.m as any).signal), `raw: agent crashed ${JSON.stringify(got.m)}`);
          return;
        }
        if (got.kind === "none") {
          this.check(flag(e.allowNoResponse), `raw: no response within ${e.waitMs ?? 2000} ms`);
          return;
        }
        const m = got.m as any;
        if (e.errorCode !== undefined) this.check(m.error?.code === e.errorCode, `raw: expected error ${e.errorCode}, got ${JSON.stringify(m)}`);
        if (e.errorCodeIn !== undefined) this.check(e.errorCodeIn.includes(m.error?.code), `raw: expected error in ${e.errorCodeIn}, got ${JSON.stringify(m)}`);
        if (e.ok === false) this.check(!!m.error, `raw: expected an error, got ${JSON.stringify(m)}`);
        return;
      }
      case "probeCapabilities": {
        // A claimed capability must answer; an unclaimed one must refuse.
        const caps = this.initResult?.agentCapabilities ?? {};
        const c = this.conn();
        const bogus = "qtest-no-such-session";
        const probes: [string, boolean, () => Promise<any>][] = [
          ["session/load", !!caps.loadSession, () => c.sdk.loadSession({ sessionId: bogus, cwd: this.vars.RUN_DIR, mcpServers: [] })],
          ["session/list", caps.sessionCapabilities?.list != null, () => c.sdk.listSessions({})],
          ["session/resume", caps.sessionCapabilities?.resume != null, () => c.sdk.resumeSession({ sessionId: bogus, cwd: this.vars.RUN_DIR, mcpServers: [] })],
          ["session/close", caps.sessionCapabilities?.close != null, () => c.sdk.closeSession({ sessionId: bogus })],
        ];
        const report: any[] = [];
        for (const [name, claimed, f] of probes) {
          const r = await this.call(f(), ms, name);
          const notFound = !r.ok && r.error?.code === -32601;
          report.push({ name, claimed, response: r.ok ? "result" : r.error?.code });
          if (claimed) this.check(!notFound, `${name} claimed but answers method_not_found`);
          else this.check(!r.ok, `${name} not claimed but answered with a result`);
        }
        if (s.imageSession) {
          const imageClaimed = !!caps.promptCapabilities?.image;
          const r = await this.call(
            c.sdk.prompt({ sessionId: this.sid(s.imageSession), prompt: [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }] }),
            ms,
            "image prompt",
          );
          report.push({ name: "prompt image", claimed: imageClaimed, response: r.ok ? r.result.stopReason : r.error?.code });
          if (imageClaimed) this.check(r.ok, `image prompt claimed but refused (${JSON.stringify(r)})`);
          if (!imageClaimed) this.check(!r.ok || r.result.stopReason === "refusal", `image prompt not claimed but accepted (${JSON.stringify(r)})`);
        }
        this.stepLog.push({ op: "probeCapabilities", report });
        return;
      }
      case "mark":
        this.marks.set(s.name, { updates: this.updates.length, t: Date.now() });
        return;
      case "wait":
        await sleep(num(s.ms)!);
        return;
      case "cancel":
        await this.conn().sdk.cancel({ sessionId: this.sid(s.session) });
        return;
      case "assert": {
        if (s.noNewToolCallsSince) {
          const m = this.marks.get(s.noNewToolCallsSince);
          if (!m) throw new StepFailure(`unknown mark ${s.noNewToolCallsSince}`);
          const seen = new Set(this.updates.slice(0, m.updates).map((u) => u.update.toolCallId).filter(Boolean));
          const fresh = this.updates.slice(m.updates).filter((u) => u.update.toolCallId && !seen.has(u.update.toolCallId));
          this.check(fresh.length === 0, `${fresh.length} new tool calls after mark ${s.noNewToolCallsSince}: ${fresh.map((u) => u.update.toolCallId).slice(0, 5)}`);
        }
        if (s.toolCallsNotCompletedSince) {
          // A tool call that was not completed at the mark (pending approval,
          // in flight at disconnect) must never turn completed afterwards.
          const m = this.marks.get(s.toolCallsNotCompletedSince);
          if (!m) throw new StepFailure(`unknown mark ${s.toolCallsNotCompletedSince}`);
          const atMark = new Map<string, string>();
          for (const u of this.updates.slice(0, m.updates)) if (u.update.toolCallId) atMark.set(u.update.toolCallId, u.update.status ?? atMark.get(u.update.toolCallId) ?? "pending");
          const late = this.updates
            .slice(m.updates)
            .filter((u) => u.update.status === "completed" && atMark.has(u.update.toolCallId) && atMark.get(u.update.toolCallId) !== "completed");
          this.check(late.length === 0, `tool calls completed after ${s.toolCallsNotCompletedSince}: ${late.map((u) => u.update.toolCallId)}`);
        }
        return;
      }
      default:
        throw new StepFailure(`unknown op ${s.op}`);
    }
  }

}

// MARK: main

function arg(name: string, all = false): string[] {
  const out: string[] = [];
  const a = process.argv.slice(2);
  for (let i = 0; i < a.length; i++) if (a[i] === name && i + 1 < a.length) out.push(a[++i]);
  return all ? out : out.slice(-1);
}

async function main() {
  const profilePath = arg("--profile")[0];
  const scenarios = arg("--scenario", true);
  const outRoot = arg("--out")[0];
  const agentOverride = arg("--agent")[0];
  if (!profilePath || !scenarios.length || !outRoot) {
    process.stderr.write("usage: fake-editor --profile <p.json> --scenario <s.json>... --out <dir> [--agent \"cmd args\"] [--env KEY=VALUE]...\n");
    process.exit(2);
  }
  const profile: Profile = JSON.parse(readFileSync(profilePath, "utf8"));
  if (agentOverride) profile.agent = agentOverride.split(/\s+/).filter(Boolean);
  for (const kv of arg("--env", true)) {
    const i = kv.indexOf("=");
    if (i <= 0) {
      process.stderr.write(`--env expects KEY=VALUE, got ${kv}\n`);
      process.exit(2);
    }
    profile.env = { ...(profile.env ?? {}), [kv.slice(0, i)]: kv.slice(i + 1) };
  }
  const out = resolve(outRoot);
  mkdirSync(out, { recursive: true });
  const summary: any = { profile: profile.name, agent: profile.agent, sdk: "@agentclientprotocol/sdk 1.7.0 (ACP v1)", startedAt: new Date().toISOString(), node: process.version, scenarios: [] };
  let failed = false;
  for (const file of scenarios) {
    let sc: Scenario;
    try {
      sc = JSON.parse(readFileSync(file, "utf8"));
    } catch (e) {
      process.stderr.write(`cannot read scenario ${file}: ${e}\n`);
      process.exit(2);
    }
    const dir = join(out, sc.id);
    const runDir = join(out, sc.id, "run");
    mkdirSync(runDir, { recursive: true });
    const vars = { ...profile.vars, RUN_DIR: runDir, REPO_ROOT: repoRoot, FAKE_EDITOR_DIR: editorRoot };
    profile.agent = substitute(profile.agent, vars);
    const run = new QTestScenarioRun(sc, profile, dir, vars);
    const t = Date.now();
    const status = await run.run();
    const rec = { id: sc.id, cases: sc.cases, title: sc.title, status, durationMs: Date.now() - t, failures: run.failures, steps: run.stepLog };
    writeFileSync(join(dir, "result.json"), JSON.stringify(rec, null, 2));
    summary.scenarios.push({ id: sc.id, cases: sc.cases, status, failures: run.failures, transcript: join(sc.id, "transcript.jsonl") });
    process.stdout.write(`${status.padEnd(7)} ${sc.id}  ${sc.cases.join(",")}${run.failures.length ? "  — " + run.failures.join("; ") : ""}\n`);
    if (status === "FAIL") failed = true;
  }
  summary.agent = profile.agent;
  summary.finishedAt = new Date().toISOString();
  summary.counts = {
    PASS: summary.scenarios.filter((s: any) => s.status === "PASS").length,
    FAIL: summary.scenarios.filter((s: any) => s.status === "FAIL").length,
    BLOCKED: summary.scenarios.filter((s: any) => s.status === "BLOCKED").length,
  };
  writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2));
  process.exit(failed ? 1 : 0);
}

main();
