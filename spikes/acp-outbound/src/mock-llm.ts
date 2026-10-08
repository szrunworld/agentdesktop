// Scripted local "model provider" for the outbound-isolation spike.
//
// Instead of asking a real model to *try* to escape (non-deterministic, costs money,
// and the real model may simply refuse), this server plays the model and *orders*
// the agent to call its built-in tools. What we measure is the enforcement layer:
// does the adapter / OS stop the call? Because the agent talks to us in clear HTTP,
// every byte the agent would send to its provider is captured here (no TLS MITM).
//
// Speaks three wire formats:
//   Anthropic Messages  POST /v1/messages                         (Claude Code)
//   OpenAI Responses    POST /v1/responses                        (Codex)
//   Gemini              POST /v1beta/models/<m>:streamGenerateContent / :generateContent (Gemini CLI)
import http from "node:http";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import path from "node:path";

export type Attempt =
  | { id: string; kind: "mcp"; tool: string; args: Record<string, unknown> }
  | { id: string; kind: "read"; file: string }
  | { id: string; kind: "write"; file: string; content: string }
  | { id: string; kind: "shell"; command: string }
  | { id: string; kind: "fetch"; url: string };

export interface MockOptions {
  outDir: string; // full request bodies go here (gitignored)
  summaryFile: string; // committed per-request summary (jsonl)
  canaries: Record<string, string>; // label -> secret string to look for in egress
}

type Tool = { name: string; schema: any };

export class MockLLM {
  plan: Attempt[] = [];
  emitted: { provider: string; attempt: string; tool: string; args: unknown }[] = [];
  skipped: { provider: string; attempt: string; reason: string }[] = [];
  private n = 0;
  server!: http.Server;
  port = 0;
  constructor(private o: MockOptions) {
    mkdirSync(o.outDir, { recursive: true });
  }

  setPlan(p: Attempt[]) {
    this.plan = p;
  }

  async start() {
    this.server = http.createServer((req, res) => this.handle(req, res));
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", () => r()));
    this.port = (this.server.address() as any).port;
    return this.port;
  }
  stop() {
    this.server.closeAllConnections?.();
    this.server.close();
  }

  requestTimes: number[] = [];
  private record(provider: string, req: http.IncomingMessage, raw: string, body: any, extra: any) {
    const i = ++this.n;
    this.requestTimes.push(Date.now());
    writeFileSync(path.join(this.o.outDir, `${String(i).padStart(3, "0")}-${provider}.json`), raw);
    const hits: Record<string, boolean> = {};
    for (const [k, v] of Object.entries(this.o.canaries)) hits[k] = raw.includes(v);
    appendFileSync(
      this.o.summaryFile,
      JSON.stringify({
        i,
        provider,
        method: req.method,
        path: req.url,
        bytes: raw.length,
        sha256: createHash("sha256").update(raw).digest("hex").slice(0, 16),
        model: body?.model,
        canaryInBody: hits,
        headerNames: Object.keys(req.headers).sort(),
        ...extra,
      }) + "\n",
    );
  }

  delayMs = 0; // per-response latency, used by the cancellation experiment
  private handle(req: http.IncomingMessage, res: http.ServerResponse) {
    if (this.delayMs) {
      const d = this.delayMs;
      this.delayMs = 0;
      setTimeout(() => {
        this.delayMs = d;
        this.handleNow(req, res);
      }, d);
      return;
    }
    this.handleNow(req, res);
  }
  private handleNow(req: http.IncomingMessage, res: http.ServerResponse) {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body: any = undefined;
      try {
        body = raw ? JSON.parse(raw) : undefined;
      } catch {}
      const url = req.url || "";
      try {
        if (url.includes("/v1/messages")) return this.anthropic(req, res, raw, body);
        if (url.includes("/responses")) return this.openai(req, res, raw, body);
        if (url.includes(":streamGenerateContent") || url.includes(":generateContent") || url.includes(":countTokens"))
          return this.gemini(req, res, raw, body, url);
        this.record("other", req, raw, body, { note: "unhandled path" });
        if (url.includes("/models")) {
          res.writeHead(200, { "content-type": "application/json" });
          return res.end(JSON.stringify({ data: [], models: [] }));
        }
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "mock: not found" } }));
      } catch (e: any) {
        this.record("error", req, raw, body, { error: String(e?.stack || e) });
        res.writeHead(500);
        res.end(String(e));
      }
    });
  }

  // ---------- generic tool selection -------------------------------------------------
  private next(provider: string, tools: Tool[], step: number): { name: string; args: any; attempt: string } | null {
    while (step < this.plan.length) {
      const a = this.plan[step];
      const pick = this.pick(provider, tools, a);
      if (pick) {
        this.emitted.push({ provider, attempt: a.id, tool: pick.name, args: pick.args });
        return { ...pick, attempt: a.id };
      }
      // tool not offered by this agent: record and move to the next attempt
      this.skipped.push({ provider, attempt: a.id, reason: "no matching tool offered to the model" });
      this.plan.splice(step, 1);
    }
    return null;
  }

  private pick(provider: string, tools: Tool[], a: Attempt): { name: string; args: any } | null {
    const find = (...res: RegExp[]) => {
      for (const re of res) {
        const t = tools.find((t) => re.test(t.name));
        if (t) return t;
      }
      return undefined;
    };
    const props = (t: Tool) => Object.keys(t.schema?.properties ?? {});
    const prop = (t: Tool, ...cands: string[]) => cands.find((c) => props(t).includes(c)) ?? cands[0];
    switch (a.kind) {
      case "mcp": {
        const t = find(new RegExp(`(^|_|\\.|:)${a.tool}$`));
        return t ? { name: t.name, args: a.args } : null;
      }
      case "read": {
        const t = find(/^Read$/, /^read_file$/, /^read$/i);
        if (!t) return this.pick(provider, tools, { id: a.id, kind: "shell", command: `cat ${a.file}` });
        return { name: t.name, args: { [prop(t, "file_path", "absolute_path", "path")]: a.file } };
      }
      case "write": {
        const t = find(/^Write$/, /^write_file$/);
        if (!t) {
          const shell = `mkdir -p "$(dirname ${a.file})" && printf '%s' '${a.content.replace(/'/g, "'\\''")}' > ${a.file}`;
          return this.pick(provider, tools, { id: a.id, kind: "shell", command: shell });
        }
        return { name: t.name, args: { [prop(t, "file_path", "absolute_path", "path")]: a.file, content: a.content } };
      }
      case "shell": {
        const t = find(/^Bash$/, /^run_shell_command$/, /^shell_command$/, /^exec_command$/, /^shell$/, /^local_shell$/);
        if (!t) return null;
        const ps = t.schema?.properties ?? {};
        if (ps.command?.type === "array") return { name: t.name, args: { command: ["bash", "-lc", a.command] } };
        if (ps.cmd) return { name: t.name, args: { cmd: a.command } };
        const args: any = { command: a.command };
        if (ps.description) args.description = "spike attempt " + a.id;
        return { name: t.name, args };
      }
      case "fetch": {
        const t = find(/^WebFetch$/, /^web_fetch$/);
        if (!t) return null;
        const ps = t.schema?.properties ?? {};
        if (ps.url) return { name: t.name, args: { url: a.url, prompt: "Return the page text." } };
        return { name: t.name, args: { prompt: `Fetch ${a.url} and return the text.` } };
      }
    }
  }

  private finalText(provider: string) {
    return `MOCK-FINAL(${provider}): plan finished.`;
  }

  // ---------- Anthropic ----------------------------------------------------------------
  private anthropic(req: http.IncomingMessage, res: http.ServerResponse, raw: string, body: any) {
    if (req.url?.includes("count_tokens")) {
      this.record("anthropic", req, raw, body, { kind: "count_tokens" });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ input_tokens: 10 }));
    }
    const tools: Tool[] = (body?.tools ?? []).filter((t: any) => t.name).map((t: any) => ({ name: t.name, schema: t.input_schema }));
    const results: any[] = [];
    for (const m of body?.messages ?? [])
      if (Array.isArray(m.content)) for (const c of m.content) if (c.type === "tool_result") results.push(c);
    const step = results.length;
    const isMain = tools.some((t) => /get_run_status/.test(t.name)) || tools.some((t) => t.name === "Bash");
    const pick = isMain ? this.next("anthropic", tools, step) : null;
    this.record("anthropic", req, raw, body, {
      kind: isMain ? "main" : "side",
      toolNames: tools.map((t) => t.name),
      systemChars: JSON.stringify(body?.system ?? "").length,
      toolResultsSent: results.map((r) => ({ id: r.tool_use_id, is_error: !!r.is_error, text: trunc(flat(r.content)) })),
      reply: pick ? { tool: pick.name, attempt: pick.attempt } : "text",
    });
    const id = "msg_mock_" + this.n;
    const blocks: any[] = pick
      ? [{ type: "tool_use", id: `toolu_${pick.attempt}_${this.n}`, name: pick.name, input: pick.args }]
      : [{ type: "text", text: isMain ? this.finalText("anthropic") : "Spike session" }];
    const stop = pick ? "tool_use" : "end_turn";
    const usage = { input_tokens: 10, output_tokens: 5 };
    if (!body?.stream) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ id, type: "message", role: "assistant", model: body?.model, content: blocks, stop_reason: stop, stop_sequence: null, usage }));
    }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const ev = (event: string, data: any) => res.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`);
    ev("message_start", { message: { id, type: "message", role: "assistant", model: body?.model, content: [], stop_reason: null, stop_sequence: null, usage } });
    blocks.forEach((b, index) => {
      if (b.type === "text") {
        ev("content_block_start", { index, content_block: { type: "text", text: "" } });
        ev("content_block_delta", { index, delta: { type: "text_delta", text: b.text } });
      } else {
        ev("content_block_start", { index, content_block: { type: "tool_use", id: b.id, name: b.name, input: {} } });
        ev("content_block_delta", { index, delta: { type: "input_json_delta", partial_json: JSON.stringify(b.input) } });
      }
      ev("content_block_stop", { index });
    });
    ev("message_delta", { delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } });
    ev("message_stop", {});
    res.end();
  }

  // ---------- OpenAI Responses ---------------------------------------------------------
  private openai(req: http.IncomingMessage, res: http.ServerResponse, raw: string, body: any) {
    // Codex groups MCP tools in a Responses "namespace" tool; flatten as "<ns>:<tool>".
    const tools: Tool[] = (body?.tools ?? [])
      .flatMap((t: any) =>
        t.type === "namespace"
          ? (t.tools ?? []).map((x: any) => ({ name: `${t.name}:${x.name}`, schema: x.parameters }))
          : [{ name: t.name ?? t.function?.name ?? t.type, schema: t.parameters ?? t.function?.parameters ?? t.format }],
      )
      .filter((t: any) => t.name);
    const outs = (body?.input ?? []).filter((x: any) => typeof x?.type === "string" && x.type.endsWith("_output"));
    const step = outs.length;
    const isMain = tools.length > 0;
    const pick = isMain ? this.next("openai", tools, step) : null;
    this.record("openai", req, raw, body, {
      kind: isMain ? "main" : "side",
      toolNames: tools.map((t) => t.name),
      systemChars: JSON.stringify(body?.instructions ?? "").length,
      toolResultsSent: outs.map((o: any) => ({ id: o.call_id, text: trunc(flat(o.output)) })),
      reply: pick ? { tool: pick.name, attempt: pick.attempt } : "text",
    });
    const rid = "resp_mock_" + this.n;
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    let seq = 0;
    const ev = (type: string, data: any) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, sequence_number: seq++, ...data })}\n\n`);
    const base = { id: rid, object: "response", created_at: Math.floor(Date.now() / 1000), model: body?.model, status: "in_progress", output: [] };
    ev("response.created", { response: base });
    let item: any;
    if (pick) {
      const [ns, fn] = pick.name.includes(":") ? pick.name.split(":") : [undefined, pick.name];
      item = { type: "function_call", id: "fc_" + this.n, call_id: `call_${pick.attempt}_${this.n}`, name: fn, ...(ns ? { namespace: ns } : {}), arguments: JSON.stringify(pick.args), status: "completed" };
    } else {
      const text = isMain ? this.finalText("openai") : "Spike session";
      item = { type: "message", id: "msg_" + this.n, role: "assistant", status: "completed", content: [{ type: "output_text", text, annotations: [] }] };
    }
    ev("response.output_item.added", { output_index: 0, item: { ...item, status: "in_progress" } });
    if (item.type === "message") ev("response.output_text.delta", { output_index: 0, item_id: item.id, content_index: 0, delta: item.content[0].text });
    ev("response.output_item.done", { output_index: 0, item });
    ev("response.completed", {
      response: { ...base, status: "completed", output: [item], usage: { input_tokens: 10, input_tokens_details: { cached_tokens: 0 }, output_tokens: 5, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 15 } },
    });
    res.end();
  }

  // ---------- Gemini ------------------------------------------------------------------
  private gemini(req: http.IncomingMessage, res: http.ServerResponse, raw: string, body: any, url: string) {
    if (url.includes(":countTokens")) {
      this.record("gemini", req, raw, body, { kind: "countTokens" });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ totalTokens: 10 }));
    }
    const decls: any[] = [];
    for (const t of body?.tools ?? []) for (const d of t.functionDeclarations ?? []) decls.push(d);
    const tools: Tool[] = decls.map((d) => ({ name: d.name, schema: d.parametersJsonSchema ?? d.parameters }));
    const responses: any[] = [];
    for (const c of body?.contents ?? []) for (const p of c.parts ?? []) if (p.functionResponse) responses.push(p.functionResponse);
    const step = responses.length;
    const isMain = tools.length > 0;
    const pick = isMain ? this.next("gemini", tools, step) : null;
    const stream = url.includes(":streamGenerateContent");
    this.record("gemini", req, raw, body, {
      kind: isMain ? "main" : "side",
      toolNames: tools.map((t) => t.name),
      systemChars: JSON.stringify(body?.systemInstruction ?? "").length,
      toolResultsSent: responses.map((r) => ({ name: r.name, text: trunc(JSON.stringify(r.response)) })),
      reply: pick ? { tool: pick.name, attempt: pick.attempt } : "text",
    });
    let parts: any[];
    if (pick) parts = [{ functionCall: { name: pick.name, args: pick.args } }];
    else if (isMain) parts = [{ text: this.finalText("gemini") }];
    else {
      // side calls (routing / next-speaker / summaries) usually want JSON
      parts = [{ text: JSON.stringify({ reasoning: "mock", next_speaker: "user", model_choice: "flash", complexity_reasoning: "mock", complexity_score: 1 }) }];
    }
    const chunk = { candidates: [{ content: { role: "model", parts }, finishReason: "STOP", index: 0 }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 }, modelVersion: "mock" };
    if (!stream) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify(chunk));
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify(chunk)}\r\n\r\n`);
    res.end();
  }
}

function flat(c: any): string {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map((x) => (typeof x === "string" ? x : x?.text ?? JSON.stringify(x))).join("\n");
  return JSON.stringify(c);
}
function trunc(s: string, n = 1500) {
  return s.length > n ? s.slice(0, n) + `…[+${s.length - n}]` : s;
}

/** Canary HTTP endpoint: any hit means an unauthorized network egress happened. */
export async function startCanaryHttp(logFile: string) {
  const s = http.createServer((req, res) => {
    appendFileSync(logFile, JSON.stringify({ t: Date.now(), method: req.method, url: req.url, ua: req.headers["user-agent"] }) + "\n");
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("CANARY-HTTP-REACHED");
  });
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  return { server: s, port: (s.address() as any).port as number };
}
