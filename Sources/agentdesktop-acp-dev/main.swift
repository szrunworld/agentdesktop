// Development entry for the ACP server (docs/acp/03-lanes.md, lane S).
// Not bundled: the shipped command is `agentdesktop acp`, wired into the
// one CLI by the Runtime owner once the server works (lane plan, step P1-01).
import AgentDesktopACP
import Foundation

FileHandle.standardError.write(Data("agentdesktop-acp-dev: server not implemented yet\n".utf8))
exit(2)
