import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A5: request.list and request.export (Design P19–P20). RT-18 (docs/plan/08):
// filters and pages; content as request.show gives it; the export is readable JSON.

private func list(_ sc: Scene, _ params: String = "{}", on c: ConnectionState? = nil) -> JSONValue? {
    data(call(sc.s, c ?? sc.c, "request.list", params: params))
}

private func ids(_ v: JSONValue?) -> [String] { v?["requests"]?.arrayValue?.compactMap { $0["requestId"]?.stringValue } ?? [] }

/// Every page of request.list with this filter, following `next`.
private func allPages(_ sc: Scene, filter: String = "", limit: Int, on c: ConnectionState? = nil) throws -> [JSONValue] {
    var out: [JSONValue] = []
    var cursor: String?
    repeat {
        let extra = cursor.map { #","cursor":"\#($0)""# } ?? ""
        let page = try #require(list(sc, #"{"limit":\#(limit)\#(filter)\#(extra)}"#, on: c))
        #expect(contract.validate(page, "RequestList").isEmpty, "\(page.encoded())")
        out += page["requests"]?.arrayValue ?? []
        cursor = page["next"]?.stringValue
    } while cursor != nil
    return out
}

@Test func rt18_requestsFilterByDesktopAndStateAndReadAsRequestShowDoes() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let other = try created(sc.s, sc.c)
    _ = act(sc, clickContinue, id: "act-ok-1")
    _ = act(sc, clickContinue, id: "act-ok-2")
    platform.failNext = PlatformError(.refused, "no element 0 in the window", beforeDispatch: true)
    _ = act(sc, clickContinue, id: "act-fail-1")
    _ = call(sc.s, sc.c, "window.unbind", id: "unbind-other", params: #"{"desktopId":"\#(other)"}"#)

    let onA = try #require(list(sc, #"{"desktopId":"\#(sc.desktop)","method":"act"}"#))
    #expect(contract.validate(onA, "RequestList").isEmpty, "\(onA.encoded())")
    #expect(ids(onA) == ["act-fail-1", "act-ok-2", "act-ok-1"], "newest first, only acts on A")
    #expect(!ids(list(sc, #"{"desktopId":"\#(sc.desktop)"}"#)).contains("unbind-other"))
    #expect(ids(list(sc, #"{"desktopId":"\#(other)"}"#)) == ["unbind-other"])
    #expect(ids(list(sc, #"{"state":"failed"}"#)) == ["act-fail-1"])

    // Each record is what request.show gives for it, plus who and where.
    for item in onA["requests"]?.arrayValue ?? [] {
        let id = try #require(item["requestId"]?.stringValue)
        let shown = try #require(data(call(sc.s, sc.c, "request.show", params: #"{"requestId":"\#(id)"}"#)))
        #expect(shown == item, "\(id)")
        #expect(item["clientId"]?.stringValue == "local:\(getuid())" && item["desktopId"]?.stringValue == sc.desktop)
    }
    #expect(onA["requests"]?.arrayValue?.first?["outcome"]?["error"]?["code"]?.stringValue == "execution_failed")
}

@Test func rt18_pagesAreCompleteWithoutRepeats() throws {
    let sc = try scene()
    for i in 0..<7 { _ = act(sc, clickContinue, id: "page-\(i)") }
    let whole = ids(list(sc, #"{"method":"act","limit":100}"#))
    #expect(whole.count == 7)
    let paged = try allPages(sc, filter: #","method":"act""#, limit: 3).compactMap { $0["requestId"]?.stringValue }
    #expect(paged == whole)
}

@Test func aPairedAppListsOnlyItsOwnRecordsAndTheOwnerSeesEveryones() throws {
    let sc = try scene()
    _ = act(sc, clickContinue, id: "owner-act")
    let (app, appId) = try pairedConnection(sc.s, capabilities: ["observe", "act", "run"], desktops: [sc.desktop])
    let sid = try #require(data(call(sc.s, app, "session.open", id: "app-session", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["sessionId"]?.stringValue)
    _ = sid
    let mine = try #require(list(sc, on: app))
    #expect(ids(mine) == ["app-session"])
    #expect(ids(list(sc, #"{"clientId":"local:\#(getuid())"}"#, on: app)) == ["app-session"], "clientId does not widen a paired app's view")
    let all = ids(list(sc))
    #expect(all.contains("owner-act") && all.contains("app-session"))
    #expect(ids(list(sc, #"{"clientId":"\#(appId)"}"#)) == ["app-session"])
    // A Desktop outside its grant is refused, not answered empty.
    let elsewhere = try created(sc.s, sc.c)
    #expect(code(call(sc.s, app, "request.list", params: #"{"desktopId":"\#(elsewhere)"}"#)) != nil)
}

@Test func rt18_theExportIsReadableJSONWithTheListedRecords() throws {
    let sc = try scene()
    _ = act(sc, clickContinue, id: "exp-1")
    _ = act(sc, clickContinue, id: "exp-2")
    let exported = try #require(data(call(sc.s, sc.c, "request.export", params: #"{"method":"act"}"#)))
    #expect(contract.validate(exported, "RequestExport").isEmpty, "\(exported.encoded())")
    #expect(exported["count"]?.intValue == 2 && exported["truncated"] == .bool(false))
    #expect(exported["artifact"]?["mediaType"]?.stringValue == "application/json")
    let artifactId = try #require(exported["artifact"]?["artifactId"]?.stringValue)
    let chunk = try #require(data(call(sc.s, sc.c, "artifact.read", params: #"{"artifactId":"\#(artifactId)"}"#)))
    #expect(chunk["eof"] == .bool(true))
    let bytes = try #require(Data(base64Encoded: chunk["dataBase64"]?.stringValue ?? ""))
    let document = try StrictJSON.parse(bytes)
    #expect(document["count"]?.intValue == 2 && document["filter"]?["method"]?.stringValue == "act")
    #expect(document["requests"] == list(sc, #"{"method":"act"}"#)?["requests"], "the export holds what the list shows")

    // A paired app cannot read the owner's export.
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe"], desktops: [sc.desktop])
    #expect(code(call(sc.s, app, "artifact.read", params: #"{"artifactId":"\#(artifactId)"}"#)) == "not_found")
}

@Test func theLedgerGainsTheDesktopColumnAndKeepsOlderRecords() throws {
    let dir = NSTemporaryDirectory() + "adt-ledger-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/requests.sqlite"
    // A ledger as it was before A5: no desktop_id column.
    do {
        let db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE requests (caller TEXT NOT NULL, request_id TEXT NOT NULL, method TEXT NOT NULL,
              digest TEXT NOT NULL, state TEXT NOT NULL, accepted_at TEXT NOT NULL, finished_at TEXT, outcome TEXT,
              dispatch_started_at TEXT, PRIMARY KEY (caller, request_id))
            """)
        try db.execute("INSERT INTO requests VALUES ('local:1', 'old-1', 'act', 'x', 'completed', ?, ?, '{\"data\":{}}', NULL)",
                       [.text(Timestamp.string(Date())), .text(Timestamp.string(Date()))])
    }
    let ledger = try RequestLedger(path: path)
    let page = try ledger.list(RequestLedger.Filter(), after: nil, limit: 10)
    #expect(page.records.map(\.requestId) == ["old-1"])
    #expect(page.records.first?.desktopId == nil && page.records.first?.caller == "local:1")
}
