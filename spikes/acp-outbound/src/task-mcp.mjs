// Allow-listed task-level MCP server for the spike. Exposes exactly two read-only
// tools that return SYNTHETIC data. Every call is appended to $ADT_MCP_LOG.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { appendFileSync } from "node:fs";

const log = (o) => { if (process.env.ADT_MCP_LOG) appendFileSync(process.env.ADT_MCP_LOG, JSON.stringify({ t: Date.now(), ...o }) + "\n"); };
log({ ev: "start", pid: process.pid });

const server = new Server({ name: "adt", version: "0.0.1" }, { capabilities: { tools: {} } });
const tools = [
  { name: "get_run_status", description: "Status of an AgentDesktop run (synthetic).",
    inputSchema: { type: "object", properties: { run_id: { type: "string" } }, required: ["run_id"] } },
  { name: "get_redacted_result", description: "Redacted result of an AgentDesktop run (synthetic).",
    inputSchema: { type: "object", properties: { run_id: { type: "string" } }, required: ["run_id"] } },
];
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  log({ ev: "call", name, args });
  if (name === "get_run_status")
    return { content: [{ type: "text", text: JSON.stringify({ run_id: args?.run_id, state: "ended", outcome: "verified", data_class: "Internal" }) }] };
  if (name === "get_redacted_result")
    // Synthetic result. The "candidate" field shows what a redaction gate must catch:
    // it is tagged Restricted-PII and would leave the machine verbatim in the next model request.
    return { content: [{ type: "text", text: JSON.stringify({ run_id: args?.run_id, summary: "3 items processed", data_class: "Internal",
      fields: [{ name: "candidate_email", data_class: "Restricted-PII", value: "PII-CANARY-alice@example.invalid" }] }) }] };
  return { isError: true, content: [{ type: "text", text: "unknown tool" }] };
});
await server.connect(new StdioServerTransport());
