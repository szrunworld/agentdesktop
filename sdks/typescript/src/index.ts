// Thin client for the AgentDesktop Runtime API (agentdesktop.runtime/1).
// It connects, confirms who answered and carries requests; every rule
// (scope, leases, snapshot checks, the request ledger, stopping) is the
// Runtime's. Contract: contracts/runtime/v1 in the repository.
import { randomUUID } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";

export const API_VERSION = "agentdesktop.runtime/1";
const MAX_FRAME = 1_048_576;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const PHASES = new Set(["local", "connect", "transport", "handshake", "request", "handler"]);
const WRITES = new Set(["desktop.create", "desktop.destroy", "app.launch", "window.bind", "window.unbind",
  "session.open", "session.close", "act", "run.finish", "run.cancel"]);

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
export type Obj = { [k: string]: Json };

export class RuntimeApiError extends Error {
  code: string;
  phase: string;
  retryable: boolean;
  notSent?: boolean;
  details: Obj;

  constructor(code: string, message: string, phase = "local", retryable = false, notSent?: boolean, details: Obj = {}) {
    super(`${code}: ${message}`);
    this.code = code;
    this.phase = phase;
    this.retryable = retryable;
    this.notSent = notSent;
    this.details = details;
  }
}

export function newRequestId(prefix = "ts"): string {
  return `${prefix}_${randomUUID().replaceAll("-", "")}`;
}

export function resolveEndpoint(option?: string, env: NodeJS.ProcessEnv = process.env): string {
  if (option) return option;
  if (env.AGENTDESKTOP_ENDPOINT) return env.AGENTDESKTOP_ENDPOINT;
  return `${env.HOME ?? homedir()}/Library/Application Support/AgentDesktop/runtime.sock`;
}

/** JSON.parse that refuses duplicate keys, like the Runtime. */
export function strictParse(text: string): Json {
  const value = JSON.parse(text);   // syntax first
  noDuplicateKeys(text);
  return value;
}

/** Walk the (already valid) JSON text and refuse an object with a repeated key. */
function noDuplicateKeys(text: string): void {
  let i = 0;
  const ws = () => { while (i < text.length && " \t\n\r".includes(text[i])) i++; };
  const str = (): string => {
    const start = i;
    i++;
    while (text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
    i++;
    return JSON.parse(text.slice(start, i));
  };
  const value = (): void => {
    ws();
    const c = text[i];
    if (c === "{") {
      i++;
      const keys = new Set<string>();
      ws();
      if (text[i] === "}") { i++; return; }
      for (;;) {
        ws();
        const k = str();
        if (keys.has(k)) throw new RuntimeApiError("instance_mismatch", `duplicate key ${k}`, "transport");
        keys.add(k);
        ws(); i++;            // ':'
        value(); ws();
        if (text[i++] === "}") return;   // else ','
      }
    } else if (c === "[") {
      i++; ws();
      if (text[i] === "]") { i++; return; }
      for (;;) { value(); ws(); if (text[i++] === "]") return; }
    } else if (c === '"') {
      str();
    } else {
      while (i < text.length && !",]} \t\n\r".includes(text[i])) i++;
    }
  };
  value();
}

/** The Response envelope of runtime.schema.json. */
export function checkResponse(v: Json): asserts v is Obj {
  const bad = (m: string) => new RuntimeApiError("instance_mismatch", m, "transport");
  if (typeof v !== "object" || v === null || Array.isArray(v) || v.apiVersion !== API_VERSION) {
    throw new RuntimeApiError("version_mismatch", "reply is not agentdesktop.runtime/1", "transport");
  }
  const rid = v.requestId;
  if (rid !== null && (typeof rid !== "string" || !ID.test(rid) || rid.length > 128)) throw bad("invalid requestId");
  const keys = Object.keys(v).sort().join(",");
  if (v.ok === true) {
    if (keys !== "apiVersion,data,ok,requestId" || typeof v.data !== "object" || v.data === null || Array.isArray(v.data)) throw bad("success reply breaks the schema");
  } else if (v.ok === false) {
    const e = v.error as Obj | undefined;
    if (keys !== "apiVersion,error,ok,requestId" || !e || typeof e !== "object" ||
        !["code", "message", "phase", "retryable"].every((k) => k in e) || !PHASES.has(String(e.phase))) throw bad("error reply breaks the schema");
  } else throw bad("reply has no ok");
}

export interface ExecContext { endpoint: string; desktopId: string; sessionId: string; runId: string; token: string }

export function loadExecContext(env: NodeJS.ProcessEnv = process.env): ExecContext | undefined {
  const path = env.AGENTDESKTOP_CONTEXT;
  if (!path) return undefined;
  const st = lstatSync(path);
  if (!st.isFile() || st.uid !== process.getuid!() || (st.mode & 0o077) !== 0) {
    throw new RuntimeApiError("permission_denied", `${path} must be this user's file and not readable by others`, "local", false, true);
  }
  return strictParse(readFileSync(path, "utf8")) as unknown as ExecContext;
}

export class RuntimeClient {
  readonly endpoint: string;
  readonly context?: ExecContext;
  identity?: Obj;
  private socket?: Socket;
  private buffer = "";
  private waiting?: { resolve: (line: string) => void; reject: (e: Error) => void };
  private attached = false;
  private timeoutMs: number;

  constructor(endpoint?: string, timeoutMs = 10_000, env: NodeJS.ProcessEnv = process.env) {
    this.timeoutMs = timeoutMs;
    this.context = loadExecContext(env);
    if (!endpoint && this.context && !env.AGENTDESKTOP_ENDPOINT) endpoint = this.context.endpoint;
    this.endpoint = resolveEndpoint(endpoint, env);
  }

  close(): void {
    this.socket?.destroy();
    this.socket = undefined;
    this.identity = undefined;
    this.attached = false;
    this.buffer = "";
  }

  private connect(): Promise<void> {
    let st;
    try { st = lstatSync(this.endpoint); } catch {
      throw new RuntimeApiError("runtime_offline", `nothing is listening: ${this.endpoint} does not exist`, "connect", true, true);
    }
    if (!st.isSocket()) throw new RuntimeApiError("runtime_offline", `${this.endpoint} is not a socket`, "connect", false, true);
    if (st.uid !== process.getuid!()) throw new RuntimeApiError("permission_denied", `${this.endpoint} belongs to another user`, "connect", false, true);
    return new Promise((resolve, reject) => {
      const s = createConnection(this.endpoint);
      s.setEncoding("utf8");
      s.once("connect", () => { this.socket = s; resolve(); });
      s.once("error", (e) => {
        if (!this.socket) reject(new RuntimeApiError("runtime_offline", `no Runtime is accepting on ${this.endpoint} (${e.message})`, "connect", true, true));
        else this.fail(new RuntimeApiError("connection_lost", e.message, "transport"));
      });
      s.on("data", (chunk: string) => {
        this.buffer += chunk;
        if (this.buffer.length > MAX_FRAME) this.fail(new RuntimeApiError("connection_lost", "the reply exceeds 1 MiB", "transport"));
        const i = this.buffer.indexOf("\n");
        if (i >= 0 && this.waiting) {
          const line = this.buffer.slice(0, i);
          this.buffer = this.buffer.slice(i + 1);
          const w = this.waiting; this.waiting = undefined; w.resolve(line);
        }
      });
      s.on("close", () => this.fail(new RuntimeApiError("connection_lost", "the Runtime closed the connection before replying", "transport")));
    });
  }

  private fail(e: Error) {
    const w = this.waiting; this.waiting = undefined;
    this.socket?.destroy(); this.socket = undefined; this.identity = undefined;
    w?.reject(e);
  }

  private async exchange(request: Obj): Promise<Obj> {
    const line = JSON.stringify(request) + "\n";
    if (Buffer.byteLength(line) > MAX_FRAME) throw new RuntimeApiError("invalid_argument", "request exceeds 1 MiB", "local", false, true);
    const s = this.socket!;
    const reply = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => this.fail(new RuntimeApiError("connection_lost", "no reply within the timeout", "transport")), this.timeoutMs);
      this.waiting = { resolve: (l) => { clearTimeout(timer); resolve(l); }, reject: (e) => { clearTimeout(timer); reject(e); } };
      s.write(line);
    });
    let v: Json;
    try { v = strictParse(reply); } catch (e) {
      if (e instanceof RuntimeApiError) throw e;
      throw new RuntimeApiError("instance_mismatch", `reply is not JSON: ${(e as Error).message}`, "transport");
    }
    checkResponse(v);
    if (v.requestId !== null && v.requestId !== request.requestId) {
      throw new RuntimeApiError("instance_mismatch", `reply answers ${v.requestId}, not ${request.requestId}`, "transport");
    }
    if (!v.ok) {
      const e = v.error as Obj;
      throw new RuntimeApiError(String(e.code), String(e.message), String(e.phase), Boolean(e.retryable),
                                e.notSent as boolean | undefined, (e.details as Obj) ?? {});
    }
    return v.data as Obj;
  }

  async handshake(): Promise<Obj> {
    if (this.identity) return this.identity;
    await this.connect();
    const id = await this.exchange({ apiVersion: API_VERSION, requestId: newRequestId("hs"), method: "runtime.handshake",
      params: { apiVersions: [API_VERSION], client: { name: "agentdesktop-typescript", version: "0.1.0" } } });
    if (id.product !== "AgentDesktop") { this.close(); throw new RuntimeApiError("instance_mismatch", `${this.endpoint} is not an AgentDesktop Runtime`, "handshake"); }
    this.identity = id;
    return id;
  }

  async call(method: string, params: Obj = {}, opts: { context?: Obj; requestId?: string; deadline?: string } = {}): Promise<Obj> {
    await this.handshake();
    const req: Obj = { apiVersion: API_VERSION, requestId: opts.requestId ?? newRequestId(), method };
    if (opts.context) req.context = opts.context;
    if (opts.deadline) req.deadline = opts.deadline;
    req.params = params;
    try {
      return await this.exchange(req);
    } catch (e) {
      if (e instanceof RuntimeApiError && e.code === "connection_lost" && WRITES.has(method)) {
        throw new RuntimeApiError("request_acceptance_unknown", `${e.message}; check with requestShow("${req.requestId}")`,
                                  "transport", false, undefined, { requestId: req.requestId as string });
      }
      throw e;
    }
  }

  status() { return this.call("runtime.status"); }
  async desktops() { return (await this.call("desktop.list")).desktops as Obj[]; }
  createDesktop(o: { name?: string; width?: number; height?: number } = {}, requestId?: string) { return this.call("desktop.create", o as Obj, { requestId }); }
  destroyDesktop(desktopId: string, requestId?: string) { return this.call("desktop.destroy", { desktopId }, { requestId }); }
  launch(desktopId: string, bundleId: string, requestId?: string) { return this.call("app.launch", { desktopId, bundleId }, { requestId }); }
  bindWindow(desktopId: string, pid: number, windowId?: number, requestId?: string) {
    return this.call("window.bind", windowId ? { desktopId, pid, windowId } : { desktopId, pid }, { requestId });
  }
  requestShow(requestId: string) { return this.call("request.show", { requestId }); }
  runShow(runId: string) { return this.call("run.show", { runId }); }
  runCancel(runId: string, requestId?: string) { return this.call("run.cancel", { runId }, { requestId }); }

  /** A Session; inside session exec, the exec's own (not opened or closed here). */
  async session(desktopId?: string): Promise<Session> {
    const ctx = this.context;
    if (ctx && (!desktopId || desktopId === ctx.desktopId)) return new Session(this, ctx.sessionId, false);
    if (!desktopId) throw new RuntimeApiError("invalid_argument", "give a desktopId outside session exec", "local", false, true);
    const s = await this.call("session.open", { desktopId });
    return new Session(this, s.sessionId as string, true);
  }

  async attach(): Promise<string | undefined> {
    if (!this.context) return undefined;
    if (!this.attached) {
      await this.call("run.attach", { runId: this.context.runId, token: this.context.token });
      this.attached = true;
    }
    return this.context.runId;
  }
}

export class Session {
  readonly client: RuntimeClient;
  readonly sessionId: string;
  private owned: boolean;

  constructor(client: RuntimeClient, sessionId: string, owned: boolean) {
    this.client = client;
    this.sessionId = sessionId;
    this.owned = owned;
  }

  private async ctx(act = false): Promise<Obj> {
    const c: Obj = { sessionId: this.sessionId };
    if (act && this.client.context?.sessionId === this.sessionId) c.runId = (await this.client.attach()) ?? null;
    return c;
  }

  async observe(o: { query?: string; screenshot?: boolean; elements?: boolean } = {}) {
    const p: Obj = {};
    if (o.query) p.query = o.query;
    if (o.screenshot === false) p.screenshot = false;
    if (o.elements === false) p.elements = false;
    return this.client.call("observe", p, { context: await this.ctx() });
  }
  async act(snapshotId: string, action: Obj, requestId?: string) {
    return this.client.call("act", { snapshotId, action }, { context: await this.ctx(true), requestId });
  }
  click(snapshotId: string, target: { element: string } | { x: number; y: number }, requestId?: string) {
    const t: Obj = "element" in target ? { elementRef: target.element } : { imagePoint: { x: target.x, y: target.y } };
    return this.act(snapshotId, { kind: "click", target: t }, requestId);
  }
  typeText(snapshotId: string, text: string, element?: string, requestId?: string) {
    return this.act(snapshotId, element ? { kind: "type", text, target: { elementRef: element } } : { kind: "type", text }, requestId);
  }
  key(snapshotId: string, key: string, modifiers?: string[], requestId?: string) {
    return this.act(snapshotId, modifiers ? { kind: "key", key, modifiers } : { kind: "key", key }, requestId);
  }
  async waitFor(c: { present?: boolean; role?: string; label?: string; labelContains?: string; timeoutMs?: number }) {
    const cond: Obj = { kind: c.present === false ? "elementAbsent" : "elementPresent" };
    if (c.role) cond.role = c.role;
    if (c.label !== undefined) cond.label = c.label;
    if (c.labelContains) cond.labelContains = c.labelContains;
    return this.client.call("wait", { condition: cond, timeoutMs: c.timeoutMs ?? 5000 }, { context: await this.ctx() });
  }
  async close() {
    if (this.owned) await this.client.call("session.close", { sessionId: this.sessionId }).catch(() => undefined);
  }
}
