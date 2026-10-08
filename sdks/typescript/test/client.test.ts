import assert from "node:assert/strict";
import { mkdtempSync, openSync, writeSync, closeSync, chmodSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { join, dirname } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { API_VERSION, RuntimeApiError, RuntimeClient, checkResponse, loadExecContext, strictParse, type Obj } from "../src/index.ts";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const identity = { product: "AgentDesktop", productVersion: "0.1.0-dev", apiVersion: API_VERSION, apiVersions: [API_VERSION],
  instanceId: "rt_ts", pid: 1, startedAt: "2026-10-08T00:00:00Z", endpoint: "/x",
  platform: { os: "macos", osVersion: "15", arch: "arm64" }, build: { source: "t" } };

function ok(req: Obj, data: Obj) { return JSON.stringify({ apiVersion: API_VERSION, requestId: req.requestId, ok: true, data }); }

async function fakeRuntime(reply: (req: Obj) => string | null): Promise<{ path: string; requests: Obj[]; server: Server }> {
  const dir = mkdtempSync("/tmp/adt-ts-");
  const path = join(dir, "r.sock");
  const requests: Obj[] = [];
  const server = createServer((s) => {
    let buf = "";
    s.setEncoding("utf8");
    s.on("data", (chunk: string) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const req = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        requests.push(req);
        const out = req.method === "runtime.handshake" ? ok(req, identity) : reply(req);
        if (out === null) { s.destroy(); return; }
        s.write(out + "\n");
      }
    });
  });
  await new Promise<void>((r) => server.listen(path, r));
  return { path, requests, server };
}

test("shared Response fixtures", () => {
  const dir = join(repo, "contracts/fixtures/runtime/v1");
  let checked = 0;
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".json"))) {
    const doc = JSON.parse(readFileSync(join(dir, f), "utf8"));
    if (doc.def !== "Response") continue;
    checked++;
    if (f.endsWith(".valid.json")) checkResponse(doc.instance);
    else assert.throws(() => checkResponse(doc.instance), RuntimeApiError, f);
  }
  assert.ok(checked >= 4);
});

test("strict JSON refuses duplicate keys at any depth", () => {
  assert.deepEqual(strictParse('{"a":{"b":[1,{"c":"x\\\\\\"y"}]},"d":"中"}'), { a: { b: [1, { c: 'x\\"y' }] }, d: "中" });
  assert.throws(() => strictParse('{"a":1,"a":2}'), RuntimeApiError);
  assert.throws(() => strictParse('{"x":[{"k":1,"k":1}]}'), RuntimeApiError);
  assert.doesNotThrow(() => strictParse('[{"k":1},{"k":2}]'));
});

test("handshake, typed calls and request ids", async () => {
  const rt = await fakeRuntime((r) => ok(r, { desktops: [], desktopId: "d_1" }));
  const c = new RuntimeClient(rt.path, 2000, {});
  assert.equal((await c.handshake()).instanceId, "rt_ts");
  assert.deepEqual(await c.desktops(), []);
  await c.createDesktop({ name: "工作区", width: 1280, height: 800 }, "ts-create-1");
  assert.deepEqual(rt.requests.map((r) => r.method), ["runtime.handshake", "desktop.list", "desktop.create"]);
  assert.equal(rt.requests[2].requestId, "ts-create-1");
  assert.deepEqual(rt.requests[2].params, { name: "工作区", width: 1280, height: 800 });
  c.close(); rt.server.close();
});

test("errors keep their code; bad replies are refused", async () => {
  const rt = await fakeRuntime((r) => JSON.stringify({ apiVersion: API_VERSION, requestId: r.requestId, ok: false,
    error: { code: "stale_observation", message: "observe again", phase: "handler", retryable: false, notSent: true } }));
  const c = new RuntimeClient(rt.path, 2000, {});
  await assert.rejects(c.status(), (e: RuntimeApiError) => e.code === "stale_observation" && e.notSent === true);
  c.close(); rt.server.close();
  const other = await fakeRuntime((r) => ok({ requestId: "someone_else" }, {}));
  const c2 = new RuntimeClient(other.path, 2000, {});
  await assert.rejects(c2.status(), (e: RuntimeApiError) => e.code === "instance_mismatch");
  c2.close(); other.server.close();
});

test("offline, and a lost reply to a write is unknown", async () => {
  await assert.rejects(new RuntimeClient("/nonexistent/r.sock", 1000, {}).status(),
    (e: RuntimeApiError) => e.code === "runtime_offline" && e.notSent === true);
  const rt = await fakeRuntime(() => null);
  const c = new RuntimeClient(rt.path, 2000, {});
  await assert.rejects(c.destroyDesktop("d_1", "ts-kill-1"),
    (e: RuntimeApiError) => e.code === "request_acceptance_unknown" && e.details.requestId === "ts-kill-1");
  c.close(); rt.server.close();
});

test("inside session exec the context attaches and acts in the Run", async () => {
  const rt = await fakeRuntime((r) => ok(r, { runId: "run_ctx" }));
  const dir = mkdtempSync("/tmp/adt-ts-ctx-");
  const path = join(dir, "ctx.json");
  const fd = openSync(path, "w", 0o600);
  writeSync(fd, JSON.stringify({ endpoint: rt.path, desktopId: "d_1", sessionId: "s_ctx", runId: "run_ctx", token: "ab".repeat(32) }));
  closeSync(fd);
  const c = new RuntimeClient(undefined, 2000, { AGENTDESKTOP_CONTEXT: path });
  const s = await c.session();
  await s.click("obs_1", { element: "el_7" });
  await s.close();
  assert.deepEqual(rt.requests.map((r) => r.method), ["runtime.handshake", "run.attach", "act"]);
  assert.deepEqual(rt.requests[2].context, { sessionId: "s_ctx", runId: "run_ctx" });
  chmodSync(path, 0o644);
  assert.throws(() => loadExecContext({ AGENTDESKTOP_CONTEXT: path }), RuntimeApiError);
  c.close(); rt.server.close(); rmSync(dir, { recursive: true });
});

test("live flow against a real Runtime", { skip: !process.env.AGENTDESKTOP_SDK_LIVE_ENDPOINT }, async () => {
  // A4: an external app pairs first; the Swift harness plays the owner and
  // approves. Unpaired, everything but pairing is refused.
  const endpoint = process.env.AGENTDESKTOP_SDK_LIVE_ENDPOINT;
  const anon = new RuntimeClient(endpoint, 10_000, {});
  await assert.rejects(anon.desktops(), (e: RuntimeApiError) => e.code === "pairing_required");
  anon.close();
  const codes: string[] = [];
  const cred = await new RuntimeClient(endpoint, 10_000, {}).pair("ts-live", ["observe", "act", "desktop.manage", "run"],
    { desktops: ["created"], apps: ["com.apple.Notes"], onCode: (code) => codes.push(code), timeoutMs: 30_000, pollMs: 100 });
  assert.ok(cred.clientId.startsWith("app:"));
  assert.equal(codes[0].length, 6);
  const c = new RuntimeClient(endpoint, 10_000, {}, cred);
  assert.equal(((await c.handshake()).principal as Obj).role, "paired");
  const d = (await c.createDesktop({ name: "ts" }, "ts-live-create")).desktopId as string;
  assert.equal((await c.createDesktop({ name: "ts" }, "ts-live-create")).desktopId, d);
  await c.launch(d, "com.apple.Notes");
  await c.bindWindow(d, 4);
  const s = await c.session(d);
  const o = await s.observe();
  const el = (o.elements as Obj[]).find((e) => e.label === "完成")!.id as string;
  const r = await s.click(o.snapshotId as string, { element: el }, "ts-live-click");
  assert.equal(r.delivery, "dispatched");
  assert.equal((await s.click(o.snapshotId as string, { element: el }, "ts-live-click")).receiptId, r.receiptId);
  await assert.rejects(s.click("obs_gone", { element: el }), (e: RuntimeApiError) => e.code === "stale_observation");
  await s.close();
  await c.destroyDesktop(d);
  c.close();
  console.log("LIVE-OK");
});
