#!/usr/bin/env node
// QTest echo agent: a tiny, deterministic ACP agent used only to self-test
// the fake editor (docs/acp/tests/README.md). It is NOT AgentDesktop and
// does not model a Runtime; it only has the observable ACP behaviour the
// scenarios assert on (session lifecycle, permission, cancel, disconnect).
//
// Prompt grammar (first word):
//   echo <text>    one agent_message_chunk, end_turn
//   act <label>    one tool call that needs permission (allow_once / reject_once)
//   slow <steps>   <steps> tool calls, 250 ms apart; cancellable
//   forbidden      refused (stopReason refusal), nothing executed
//   titled <name>  one action on a window titled with <name> (ruling P1)
//   unknown        one action whose result never comes (ruling P2)
//
// Environment:
//   QTEST_ECHO_STATE      directory for sessions.json and actions.log (required)
//   QTEST_ECHO_PRINCIPAL  the "authenticated" identity of this connection
//                         (stands in for the Runtime's auth context)
//   QTEST_ECHO_MUTANT     plant one known bug, so the self-test can prove the
//                         matching scenario FAILs (scripts/acp/selftest.sh):
//                         allow-when-unavailable, allow-always, ignore-cancel,
//                         no-owner-check, cross-talk, overclaim (claims
//                         images, still rejects them),
//                         continue-after-reconnect, stdout-noise,
//                         replay-user-as-agent, leak-title, unknown-as-completed
import * as acp from "@agentclientprotocol/sdk";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";

const stateDir = process.env.QTEST_ECHO_STATE ?? "";
if (!stateDir) {
  process.stderr.write("qtest-echo-agent: QTEST_ECHO_STATE is required\n");
  process.exit(2);
}
mkdirSync(stateDir, { recursive: true });
const principal = process.env.QTEST_ECHO_PRINCIPAL ?? "local-owner";
const mutant = process.env.QTEST_ECHO_MUTANT ?? "";
if (mutant === "stdout-noise") process.stdout.write("qtest-echo-agent starting\n");
const sessionsFile = join(stateDir, "sessions.json");
const actionsLog = join(stateDir, "actions.log");

type StoredSession = {
  principal: string;
  cwd: string;
  title: string;
  updatedAt: string;
  closed: boolean;
  history: acp.SessionUpdate[];
};

function loadAll(): Record<string, StoredSession> {
  if (!existsSync(sessionsFile)) return {};
  return JSON.parse(readFileSync(sessionsFile, "utf8"));
}
function saveAll(all: Record<string, StoredSession>) {
  writeFileSync(sessionsFile, JSON.stringify(all, null, 1), { mode: 0o600 });
}
function mutate(sessionId: string, f: (s: StoredSession) => void) {
  const all = loadAll();
  const s = all[sessionId];
  if (!s) return;
  f(s);
  s.updatedAt = new Date().toISOString();
  saveAll(all);
}
/// Every executed "input" is one line; the fake editor's evidence reads it.
function recordInput(sessionId: string, what: string) {
  appendFileSync(actionsLog, `${new Date().toISOString()} ${sessionId} ${what}\n`);
}

let counter = 0;
const nextId = (p: string) => `${p}-${process.pid}-${++counter}`;

class QTestEchoAgent implements acp.Agent {
  private running = new Map<string, AbortController>();
  constructor(private conn: acp.AgentSideConnection) {}

  private async send(sessionId: string, update: acp.SessionUpdate) {
    mutate(sessionId, (s) => s.history.push(update));
    await this.conn.sessionUpdate({ sessionId, update });
  }

  private owned(sessionId: string): StoredSession {
    const s = loadAll()[sessionId];
    // Another identity's session is indistinguishable from a missing one.
    if (!s || (s.principal !== principal && mutant !== "no-owner-check") || s.closed) {
      throw acp.RequestError.resourceNotFound(sessionId);
    }
    return s;
  }

  async initialize(_p: acp.InitializeRequest): Promise<acp.InitializeResponse> {
    // Only version 1 exists here; any other request gets our own version
    // back and the client decides (ACP version negotiation).
    return {
      protocolVersion: 1,
      agentCapabilities: {
        loadSession: true,
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
        sessionCapabilities: { list: {}, resume: {}, close: {} },
        ...(mutant === "overclaim" ? { promptCapabilities: { image: true, audio: false, embeddedContext: false } } : {}),
      },
      agentInfo: { name: "qtest-echo-agent", version: "0.1.0" },
      authMethods: [],
    };
  }

  async authenticate(_p: acp.AuthenticateRequest): Promise<acp.AuthenticateResponse> {
    return {};
  }

  async newSession(p: acp.NewSessionRequest): Promise<acp.NewSessionResponse> {
    const sessionId = nextId("qs");
    const all = loadAll();
    all[sessionId] = { principal, cwd: p.cwd, title: "", updatedAt: new Date().toISOString(), closed: false, history: [] };
    saveAll(all);
    return { sessionId };
  }

  async loadSession(p: acp.LoadSessionRequest): Promise<acp.LoadSessionResponse> {
    const s = this.owned(p.sessionId);
    for (const update of s.history) {
      const shown: acp.SessionUpdate =
        mutant === "replay-user-as-agent" && update.sessionUpdate === "user_message_chunk"
          ? { ...update, sessionUpdate: "agent_message_chunk" }
          : update;
      await this.conn.sessionUpdate({ sessionId: p.sessionId, update: shown });
    }
    if (mutant === "continue-after-reconnect" && s.history.some((u) => u.sessionUpdate === "agent_message_chunk" && u.content.type === "text" && u.content.text.startsWith("ended:connection_lost"))) {
      // The bug under test: a connection_scoped run picks up where it left off.
      setTimeout(() => void this.slow(p.sessionId, 2, new AbortController().signal), 100);
    }
    return {};
  }

  async resumeSession(p: acp.ResumeSessionRequest): Promise<acp.ResumeSessionResponse> {
    this.owned(p.sessionId);
    return {};
  }

  async listSessions(_p: acp.ListSessionsRequest): Promise<acp.ListSessionsResponse> {
    const all = loadAll();
    return {
      sessions: Object.entries(all)
        .filter(([, s]) => (s.principal === principal || mutant === "no-owner-check") && !s.closed)
        .map(([sessionId, s]) => ({ sessionId, cwd: s.cwd, title: s.title || null, updatedAt: s.updatedAt })),
    };
  }

  async closeSession(p: acp.CloseSessionRequest): Promise<acp.CloseSessionResponse> {
    this.owned(p.sessionId);
    this.running.get(p.sessionId)?.abort();
    mutate(p.sessionId, (s) => (s.closed = true));
    return {};
  }

  async cancel(p: acp.CancelNotification): Promise<void> {
    if (mutant === "ignore-cancel") return;
    this.running.get(p.sessionId)?.abort();
  }

  async prompt(p: acp.PromptRequest): Promise<acp.PromptResponse> {
    this.owned(p.sessionId);
    if (p.prompt.some((b) => b.type !== "text")) {
      throw acp.RequestError.invalidParams(undefined, "only text prompts are supported");
    }
    const text = p.prompt.map((b) => (b.type === "text" ? b.text : "")).join(" ").trim();
    const [verb, ...rest] = text.split(/\s+/);
    const arg = rest.join(" ");
    const sid = p.sessionId;
    if (this.running.has(sid)) throw acp.RequestError.invalidRequest(undefined, "a turn is already running");
    const abort = new AbortController();
    this.running.set(sid, abort);
    try {
      await this.send(sid, { sessionUpdate: "user_message_chunk", content: { type: "text", text } });
      switch (verb) {
        case "echo":
          if (mutant === "cross-talk") {
            for (const other of Object.keys(loadAll())) if (other !== sid) await this.send(other, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: arg } });
          }
          await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: arg } });
          return { stopReason: "end_turn" };
        case "titled":
          return await this.titled(sid, arg || "王小明");
        case "unknown":
          return await this.unknown(sid, abort.signal);
        case "forbidden":
          await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "task_not_authorized" } });
          return { stopReason: "refusal" };
        case "act":
          return await this.act(sid, arg || "action");
        case "slow":
          return await this.slow(sid, Math.max(1, parseInt(arg || "8", 10)), abort.signal);
        default:
          await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "unknown_command" } });
          return { stopReason: "end_turn" };
      }
    } finally {
      this.running.delete(sid);
    }
  }

  private async act(sid: string, label: string): Promise<acp.PromptResponse> {
    const toolCallId = nextId("act");
    await this.send(sid, { sessionUpdate: "tool_call", toolCallId, title: `Action (${label.length} chars)`, kind: "execute", status: "pending" });
    let allow = false;
    let why = "approval_unavailable";
    try {
      const r = await this.conn.requestPermission({
        sessionId: sid,
        toolCall: { toolCallId, title: "Action", kind: "execute", status: "pending" },
        options: [
          { optionId: "allow", name: "Allow once", kind: "allow_once" },
          { optionId: "reject", name: "Deny once", kind: "reject_once" },
          ...(mutant === "allow-always" ? [{ optionId: "always", name: "Always allow", kind: "allow_always" as const }] : []),
        ],
      });
      if (r.outcome.outcome === "selected") {
        allow = r.outcome.optionId === "allow";
        why = allow ? "allowed" : "rejected_by_editor";
      } else {
        why = "approval_cancelled";
      }
    } catch {
      // The editor could not answer: never treated as an allow.
      why = "approval_unavailable";
      if (mutant === "allow-when-unavailable") allow = true;
    }
    if (!allow) {
      await this.send(sid, { sessionUpdate: "tool_call_update", toolCallId, status: "failed" });
      await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `not_executed:${why}` } });
      return { stopReason: "end_turn" };
    }
    recordInput(sid, `act ${toolCallId}`);
    await this.send(sid, { sessionUpdate: "tool_call_update", toolCallId, status: "completed" });
    await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "executed" } });
    return { stopReason: "end_turn" };
  }

  private async slow(sid: string, steps: number, signal: AbortSignal): Promise<acp.PromptResponse> {
    for (let i = 1; i <= steps; i++) {
      await new Promise((r) => setTimeout(r, 250));
      if (signal.aborted) {
        await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "stopped:cancelled" } });
        return { stopReason: "cancelled" };
      }
      const toolCallId = nextId("step");
      await this.send(sid, { sessionUpdate: "tool_call", toolCallId, title: `Step ${i}`, kind: "execute", status: "in_progress" });
      recordInput(sid, `step ${toolCallId}`);
      await this.send(sid, { sessionUpdate: "tool_call_update", toolCallId, status: "completed" });
    }
    await this.send(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done" } });
    return { stopReason: "end_turn" };
  }

  async setSessionConfigOption(_p: acp.SetSessionConfigOptionRequest): Promise<acp.SetSessionConfigOptionResponse> {
    return { configOptions: [] };
  }

  /// Ruling P1 stand-in: the "bound window" is titled with a person's name;
  /// only the mutant lets it reach the editor.
  private async titled(sid: string, name: string): Promise<acp.PromptResponse> {
    const windowTitle = `候选人 ${name} 的简历 – Preview`;
    const toolCallId = nextId("act");
    const shown = mutant === "leak-title" ? `Click download on ${windowTitle}` : "点击（目标 ref-0001）";
    await this.send(sid, { sessionUpdate: "tool_call", toolCallId, title: shown, kind: "execute", status: "in_progress" });
    recordInput(sid, `titled ${toolCallId}`);
    await this.send(sid, { sessionUpdate: "tool_call_update", toolCallId, status: "completed" });
    return { stopReason: "end_turn" };
  }

  /// Ruling P2 stand-in: an action is sent but its result never comes; it
  /// stays in progress until the turn ends (cancel or disconnect).
  private unknownCalls = new Map<string, string>();
  private async unknown(sid: string, signal: AbortSignal): Promise<acp.PromptResponse> {
    const toolCallId = nextId("act");
    this.unknownCalls.set(sid, toolCallId);
    await this.send(sid, { sessionUpdate: "tool_call", toolCallId, title: "输入文字 — 已发出", kind: "execute", status: "in_progress", rawOutput: { outcome: "unknown" } });
    recordInput(sid, `unknown ${toolCallId}`);
    while (!signal.aborted) await new Promise((r) => setTimeout(r, 50));
    await this.endUnknown(sid);
    return { stopReason: "cancelled" };
  }

  private endUnknownFor(sid: string): acp.SessionUpdate[] {
    const toolCallId = this.unknownCalls.get(sid);
    if (!toolCallId) return [];
    this.unknownCalls.delete(sid);
    const status = mutant === "unknown-as-completed" ? "completed" : "failed";
    return [
      { sessionUpdate: "tool_call_update", toolCallId, title: "输入文字 — 结果未知 · 需要核实", status, rawOutput: { execution: "terminated", outcome: "unknown" } },
      { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "任务结束：结果未知 · 需要核实" } },
    ];
  }
  private async endUnknown(sid: string) {
    for (const u of this.endUnknownFor(sid)) await this.send(sid, u);
  }

  /// The control connection is gone: a connection-scoped turn stops input,
  /// and the history says so for whoever loads the session later.
  connectionLost() {
    for (const [sid, abort] of this.running) {
      abort.abort();
      const tail = this.endUnknownFor(sid);
      mutate(sid, (s) => {
        s.history.push(...tail);
        s.history.push({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "ended:connection_lost outcome:unknown" } });
      });
    }
  }
}

const stream = acp.ndJsonStream(
  Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
  Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
  { maxMessageBytes: 1024 * 1024 },
);
let agent: QTestEchoAgent | undefined;
const conn = new acp.AgentSideConnection((c) => (agent = new QTestEchoAgent(c)), stream);
conn.closed.then(
  () => {
    agent?.connectionLost();
    process.exit(0);
  },
  () => {
    agent?.connectionLost();
    process.exit(0);
  },
);
