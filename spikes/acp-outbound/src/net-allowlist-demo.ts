// Shows how "model API only" egress can be enforced on macOS: sandbox-exec cannot name a
// remote host (only "*" or "localhost"), so the profile allows ONLY a local CONNECT proxy
// port, and the proxy decides by hostname. The proxy here never dials upstream (no real
// egress); it only answers 200 for allow-listed hosts and 403 otherwise.
import http from "node:http";
import net from "node:net";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFileSync, mkdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { sandboxProfile } from "./sandbox.ts";

const ALLOW = new Set(["api.anthropic.com:443"]);
const decisions: any[] = [];
const proxy = http.createServer((_q, s) => { s.writeHead(403); s.end(); });
proxy.on("connect", (req, sock) => {
  const ok = ALLOW.has(req.url ?? "");
  decisions.push({ target: req.url, allowed: ok });
  sock.end(ok ? "HTTP/1.1 200 Connection Established\r\n\r\n" : "HTTP/1.1 403 Forbidden\r\n\r\n");
});
await new Promise<void>((r) => proxy.listen(0, "127.0.0.1", () => r()));
const pport = (proxy.address() as any).port;
const other = net.createServer((s) => s.end("reached")).listen(0, "127.0.0.1");
await new Promise((r) => other.once("listening", r));
const oport = (other.address() as any).port;

const NODE = realpathSync(process.execPath);
const out = path.join(import.meta.dirname, "..", "runs", "net-allowlist-demo");
mkdirSync(out, { recursive: true });
const profile = sandboxProfile({ readAllow: [path.dirname(path.dirname(NODE))], writeAllow: [], execAllow: [NODE], netAllow: [`localhost:${pport}`] });
writeFileSync(`${out}/sandbox.sb`, profile);
const probe = `
const net=require('net');
const tcp=(h,p)=>new Promise(r=>{const s=net.connect(p,h);s.on('connect',()=>{s.destroy();r('connected')});s.on('error',e=>r('error '+e.code));});
const via=(t)=>new Promise(r=>{const s=net.connect(${pport},'127.0.0.1',()=>s.write('CONNECT '+t+' HTTP/1.1\\r\\nHost: '+t+'\\r\\n\\r\\n'));let b='';s.on('data',d=>{b+=d;});s.on('end',()=>r(b.split('\\r\\n')[0]));s.on('error',e=>r('error '+e.code));});
(async()=>{console.log(JSON.stringify({
 direct_1_1_1_1_443: await tcp('1.1.1.1',443),
 direct_localhost_other_port: await tcp('127.0.0.1',${oport}),
 proxy_api_anthropic: await via('api.anthropic.com:443'),
 proxy_other_host: await via('exfil.example.com:443'),
}))})();`;
// async: the proxy lives in this process and must keep serving while the probe runs
const { stdout: res } = await promisify(execFile)("/usr/bin/sandbox-exec", ["-f", `${out}/sandbox.sb`, NODE, "-e", probe], { encoding: "utf8", timeout: 30000 });
const result = { inSandbox: JSON.parse(res), proxyDecisions: decisions };
writeFileSync(`${out}/result.json`, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 1));
proxy.close(); other.close();
