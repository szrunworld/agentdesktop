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

    @Test func membersAreReadWithKeysDecodedAndValuesAsWritten() throws {
        let m = try #require(ACPFileSessionStore.topLevelMembers(Data(#" {"a\u0062":1.50, "s":"x\"}y", "o":{"k":[1,"]"]}} "#.utf8)))
        #expect(m.map(\.key) == ["ab", "s", "o"])
        #expect(m.map(\.rawValue) == ["1.50", #""x\"}y""#, #"{"k":[1,"]"]}"#])
        #expect(ACPFileSessionStore.topLevelMembers(Data("[1]".utf8)) == nil)
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
        #"{"at":"2026-10-09T00:00:00Z","entries":9007199254740992.5,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":1e300,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3e0,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3.0,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":9223372036854775808,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        // a repeated deciding field (b9 on #178), also through an escaped key
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"uncertain","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","file":"binding","sessionId":"s1","status":"uncertain"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","sessionId":"s2","status":"uncertain"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"uncertain","st\u0061tus":"completed"}"#,
        #"{"at":"2026-02-31T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T00:00:00Zjunk","entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        #"{"at":"2026-10-09T25:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed"}"#,
        // ④ a field the record does not have
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","note":"x"}"#,
        #"{"at":"2026-10-09T00:00:00Z","entries":3,"file":"history","sessionId":"s1","status":"completed","Status":"intent"}"#,
    ])
    func everyBrokenRuleIsRejected(_ line: String) {
        #expect(!ok(line), "\(line)")
    }
}
