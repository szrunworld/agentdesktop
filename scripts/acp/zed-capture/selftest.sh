#!/bin/bash
# Proves the capture wrapper is a byte-exact tee, without Zed.
#
#   scripts/acp/zed-capture/selftest.sh [out-dir under /tmp/adt-*]
#
# 1. bytes: wrap /bin/cat, push awkward input (UTF-8, CRLF, empty lines, a
#    2 MiB line, no final newline) in small chunks; stdin, stdout and both
#    .bin files must equal the input byte for byte.
# 2. protocol: the fake editor drives the dev entry --demo through the
#    wrapper (t01, t01b, t06b); every frame in the wrapper's frames.jsonl
#    must equal the fake editor's own transcript, in order.
# 3. collect: redact.mjs summarises that capture and leaves no home path,
#    user name or host name behind.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
fe="$repo/scripts/acp/fake-editor"
out="${1:-/tmp/adt-zed-capture-selftest-$(date +%Y%m%d-%H%M%S)}"
case "$out" in /tmp/adt-*) ;; *) echo "out-dir must be under /tmp/adt-"; exit 2 ;; esac
rm -rf "$out" && mkdir -m 700 -p "$out"
failed=0

echo "== 1. byte-exact tee"
node -e '
const fs=require("fs");
const parts=["{\"a\":\"ü€😀\"}\n","line with CRLF\r\n","\n","\n",JSON.stringify({big:"x".repeat(2*1024*1024)})+"\n","no newline at the end"];
fs.writeFileSync(process.argv[1], Buffer.from(parts.join(""),"utf8"));' "$out/input.bin"
ADT_ZED_CAPTURE_DIR="$out/bytes" ADT_AGENT_COMMAND='["/bin/cat"]' \
  node -e '
const {spawn}=require("child_process"); const fs=require("fs");
const data=fs.readFileSync(process.argv[1]);
const c=spawn(process.execPath,[process.argv[2]],{stdio:["pipe","pipe","inherit"]});
const got=[]; c.stdout.on("data",b=>got.push(b));
let i=0; (function next(){ if(i>=data.length){c.stdin.end();return;} const n=1+((i*7919)%4093); c.stdin.write(data.subarray(i,i+n)); i+=n; setImmediate(next); })();
c.on("close",code=>{ fs.writeFileSync(process.argv[3],Buffer.concat(got)); process.exit(code); });' \
  "$out/input.bin" "$here/capture-agent.mjs" "$out/stdout.bin"
rc=$?
l=$(ls -d "$out"/bytes/launch-* | head -1)
if [ $rc -eq 0 ] && cmp -s "$out/input.bin" "$out/stdout.bin" && cmp -s "$out/input.bin" "$l/editor-to-agent.bin" && cmp -s "$out/input.bin" "$l/agent-to-editor.bin"; then
  echo "PASS bytes: $(wc -c < "$out/input.bin" | tr -d ' ') bytes, $(grep -c '"dir":"editor->agent","offset"' "$l/chunks.jsonl") chunks in, stdout and both .bin identical to the input"
else
  echo "FAIL bytes (exit=$rc)"; failed=1
fi

echo "== 2. fake editor through the wrapper"
(cd "$repo" && swift build --product agentdesktop-acp-dev) >/dev/null || { echo "swift build failed"; exit 2; }
(cd "$fe" && npm ci --silent --no-audit --no-fund && npx tsc -p .) || { echo "fake editor build failed"; exit 2; }
node_bin="$(node -p 'require("fs").realpathSync(process.execPath)')"
cat > "$out/profile.json" <<EOF
{
  "name": "zed-capture-wrapper",
  "agent": ["$node_bin", "$here/capture-agent.mjs"],
  "env": {
    "ADT_ZED_CAPTURE_DIR": "$out/proto/frames",
    "ADT_AGENT_COMMAND": "[\"$repo/.build/debug/agentdesktop-acp-dev\", \"--demo\", \"--state-dir\", \"$out/proto/acp-state\"]"
  },
  "features": ["session.load"],
  "vars": { "SUPPORTED_VERSIONS": "[1]", "PROMPT_ECHO": "/help", "ECHO_TEXT": "" }
}
EOF
node "$fe/dist/fake-editor.js" --profile "$out/profile.json" \
  --scenario "$fe/scenarios/t01-valid-requests.json" --scenario "$fe/scenarios/t01b-pipelining.json" \
  --scenario "$fe/scenarios/t06b-load-ordering.json" --out "$out/fe"
rc=$?; [ $rc -eq 0 ] || { echo "FAIL fake editor through the wrapper (exit=$rc)"; failed=1; }
node -e '
const fs=require("fs"),path=require("path");
const [feDir,capDir]=process.argv.slice(1);
const launches=fs.readdirSync(capDir).filter(d=>d.startsWith("launch-")).sort((a,b)=>+a.split("-")[1]-+b.split("-")[1]);
const fromCap=[]; for(const l of launches){ for(const x of fs.readFileSync(path.join(capDir,l,"frames.jsonl"),"utf8").split("\n").filter(Boolean)){ const f=JSON.parse(x); fromCap.push(f.dir+" "+f.text); } }
const fromFe=[];
for(const s of ["T01-valid-requests","T01-pipelining","T06-load-ordering"]){
  for(const x of fs.readFileSync(path.join(feDir,s,"transcript.jsonl"),"utf8").split("\n").filter(Boolean)){
    const e=JSON.parse(x);
    if(e.dir==="out") fromFe.push("editor->agent "+JSON.stringify(e.msg));
    else if(e.dir==="out-raw") fromFe.push("editor->agent "+e.raw);
    else if(e.dir==="in") fromFe.push("agent->editor "+JSON.stringify(e.msg));
  }
}
// Compare as parsed JSON (the fake editor logs parsed messages), per direction and in order.
const norm=a=>a.map(s=>{const i=s.indexOf(" ");return s.slice(0,i)+" "+JSON.stringify(JSON.parse(s.slice(i+1)));});
const pick=(a,d)=>norm(a).filter(s=>s.startsWith(d));
let ok=true;
for(const d of ["editor->agent","agent->editor"]){ const A=pick(fromCap,d),B=pick(fromFe,d); const same=A.length===B.length&&A.every((x,i)=>x===B[i]); console.log((same?"PASS":"FAIL")+" frames "+d+": wrapper "+A.length+", fake editor "+B.length); ok=ok&&same; }
process.exit(ok?0:1);' "$out/fe" "$out/proto/frames" || failed=1

echo "== 3. redaction"
mkdir -p "$out/proto/zed-data/logs"
node "$here/redact.mjs" "$out/proto" "$repo" > "$out/redact.txt"; rc=$?
cat "$out/redact.txt"
if [ $rc -eq 0 ] && ! grep -rqi -e "$HOME" -e "$(id -un)" "$out/proto/redacted"; then echo "PASS redaction"; else echo "FAIL redaction (exit=$rc)"; failed=1; fi

echo "evidence: $out"
exit $failed
