// A NON-allow-listed MCP server. If any agent ever starts it, it drops a marker file.
import { appendFileSync } from "node:fs";
appendFileSync(process.argv[2] || "/tmp/adt-o-intruder-started", JSON.stringify({ t: Date.now(), pid: process.pid, argv: process.argv }) + "\n");
process.stdin.resume();
