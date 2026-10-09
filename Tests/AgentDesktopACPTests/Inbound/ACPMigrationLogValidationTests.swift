import Foundation
import Testing
@testable import AgentDesktopACP

/// Kevin 2026-10-09: one rule for every migration-log record instead of a
/// patch per corruption. Each case breaks exactly one part of the rule.
struct ACPMigrationLogValidationTests {
    static let valid = #"{"agentChanged":0,"agentKept":2,"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","titleReset":false,"userScrubbed":1}"#

    private func ok(_ line: String) -> Bool { ACPFileSessionStore.validLogRecord(Data(line.utf8)) != nil }

    @Test func aRecordTheStoreWritesIsValid() throws {
        #expect(ok(Self.valid))
        var e = ACPFileSessionStore.MigrationLogEntry(at: "2026-10-09T01:02:03Z", file: "binding", sessionId: "acps_x-1", entries: 0)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for status in ["intent", "completed"] {
            e.status = status
            #expect(ok(String(decoding: try enc.encode(e), as: UTF8.self)), "\(status)")
        }
        for status in ["failed", "uncertain"] {
            e.status = status
            e.error = "write"
            #expect(ok(String(decoding: try enc.encode(e), as: UTF8.self)), "\(status)")
        }
        #expect(ok(#"{"at":"2026-10-09T00:00:00.123Z","entries":0,"file":"binding","sessionId":"s1","status":"intent"}"#))
    }

    @Test(arguments: [
        // ① not a JSON object
        "", "not json", "[]", #""s1""#, "42", "null",
        // ② a required field missing
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1"}"#,
        #"{"entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","status":"completed"}"#,
        // ③ a value outside its range or of the wrong type
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"uncertaib"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"histroy","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"../s1","status":"completed"}"#,
        #"{"at":"t","entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":-1,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":1.5,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":"3","file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":true,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","userScrubbed":-2}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","titleReset":"yes"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","titleReset":1}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","error":"write"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"intent","error":"write"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"failed","error":7}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":["history"],"sessionId":"s1","status":"completed"}"#,
        // ④ a field the record does not have
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","note":"x"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","Status":"intent"}"#,
    ])
    func everyBrokenRuleIsRejected(_ line: String) {
        #expect(!ok(line), "\(line)")
    }
}
