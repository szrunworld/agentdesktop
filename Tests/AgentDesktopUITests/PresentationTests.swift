import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

func receipt(_ delivery: String, _ execution: String) -> JSONValue {
    .obj([("receiptId", .string("rcpt_1")), ("requestId", .string("req_1")), ("desktopId", .string("desk_001")),
          ("snapshotId", .string("snap_1")), ("delivery", .string(delivery)), ("execution", .string(execution)),
          ("verification", .string("not_requested"))])
}

@Suite("Action results (06 §6.4)")
struct ActionResultTests {
    // Every delivery × execution pair maps to exactly one level.
    @Test(arguments: [
        ("dispatched", "completed", ActionResultLevel.executedUnverified, "已执行，未验证"),
        ("dispatched", "failed", .failed, "执行失败"),
        ("dispatched", "unknown", .unknown, "结果未知"),
        ("not_dispatched", "completed", .notDispatched, "未发出"),
        ("not_dispatched", "failed", .notDispatched, "未发出"),
        ("not_dispatched", "unknown", .notDispatched, "未发出"),
        ("unknown", "completed", .unknown, "结果未知"),
        ("unknown", "failed", .unknown, "结果未知"),
        ("unknown", "unknown", .unknown, "结果未知"),
    ])
    func everyCombination(delivery: String, execution: String, level: ActionResultLevel, title: String) {
        let p = ActionResultPresentation.make(receipt: receipt(delivery, execution))
        #expect(p.level == level)
        #expect(p.title == title)
        #expect(p.canRetry == false)
        #expect(p.needsReconciliation == (level == .unknown))
        #expect(p.businessResult == "业务结果：未评估")
        // Delivery or receipt alone is never shown as success.
        #expect(!p.title.contains("成功"))
    }

    @Test func acceptedWithoutReceipt() {
        let p = ActionResultPresentation.make(receipt: nil)
        #expect(p.level == .accepted)
        #expect(p.title == "已受理")
        let record = JSONValue.obj([("requestId", .string("req_9")), ("method", .string("act")),
                                    ("state", .string("accepted")), ("acceptedAt", .string("2026-10-08T00:00:00Z"))])
        #expect(ActionResultPresentation.make(record: record).level == .accepted)
    }

    @Test func notDispatchedShowsItsReason() {
        let p = ActionResultPresentation.make(receipt: receipt("not_dispatched", "failed"), errorCode: "target_moved")
        #expect(p.reasonCode == "target_moved")
        #expect(p.reasonText == "目标已移动（target_moved）")
        let silent = ActionResultPresentation.make(receipt: receipt("not_dispatched", "failed"))
        #expect(silent.reasonText == "Runtime 未提供原因")
    }

    @Test func fromRequestRecordError() {
        let record = JSONValue.obj([
            ("requestId", .string("req_2")), ("method", .string("act")), ("state", .string("failed")),
            ("acceptedAt", .string("2026-10-08T00:00:00Z")),
            ("outcome", .obj([("error", .obj([("code", .string("invalid_target")), ("message", .string("x")),
                                              ("details", .obj([("receipt", receipt("not_dispatched", "failed"))]))]))])),
        ])
        let p = ActionResultPresentation.make(record: record)
        #expect(p.level == .notDispatched)
        #expect(p.reasonCode == "invalid_target")
        // The Runtime's ledger stores a success as {data: receipt}
        // (RequestLedger); it is the receipt, not "only accepted".
        let ok = record.setting("state", .string("completed"))
            .setting("outcome", .obj([("data", receipt("dispatched", "completed"))]))
        #expect(ActionResultPresentation.make(record: ok).level == .executedUnverified)
        #expect(ActionReceiptView(record: ok).receipt?["receiptId"] != nil)
        // An older record with the receipt itself in outcome is still read.
        let legacy = record.setting("outcome", receipt("dispatched", "completed"))
        #expect(ActionResultPresentation.make(record: legacy).level == .executedUnverified)
    }
}

func run(kind: String = "act", phase: String, outcome: String? = nil, quiescence: String? = nil, origin: String = "agent_hub") -> JSONValue {
    .obj([("runId", .string("run_1")), ("kind", .string(kind)), ("origin", .string(origin)), ("desktopId", .string("desk_001")),
          ("phase", .string(phase)), ("outcome", outcome.map(JSONValue.string) ?? .null),
          ("quiescence", .string(quiescence ?? (phase == "ended" ? "confirmed" : "not_confirmed"))),
          ("clientId", .string("local:501")), ("receipts", .array([.string("r1"), .string("r2")]))])
}

@Suite("Run status")
struct RunStatusTests {
    @Test func actSuccessIsDelivered() {
        #expect(RunStatusPresentation.make(run: run(kind: "act", phase: "ended", outcome: "success")).text == "已投递")
        #expect(RunStatusPresentation.make(run: run(kind: "unit", phase: "ended", outcome: "success")).text == "成功")
        #expect(RunStatusPresentation.make(run: run(kind: "exec", phase: "ended", outcome: "success")).text == "成功")
    }

    @Test func stoppingIsNotStopped() {
        #expect(RunStatusPresentation.make(run: run(phase: "stopping", quiescence: "pending")) == StatusText("停止中", .attention))
        #expect(RunStatusPresentation.make(run: run(phase: "ended", outcome: "cancelled", quiescence: "pending")).text == "停止中")
        #expect(RunStatusPresentation.make(run: run(phase: "ended", outcome: "cancelled")).text == "已停止")
        #expect(RunStatusPresentation.make(run: run(phase: "ended", outcome: "unknown")) == StatusText("结果未知", .attention))
        #expect(RunStatusPresentation.make(run: run(phase: "running")) == StatusText("运行中", .running))
    }

    @Test func desktopControlFromRuns() {
        let desk = JSONValue.obj([("desktopId", .string("desk_001")), ("name", .string("A")), ("state", .string("ready")),
                                  ("screen", .obj([("frame", .obj([("width", .int(1280)), ("height", .int(800))]))]))])
        let idle = DesktopControlPresentation.make(desktop: desk, activeRuns: [])
        #expect(idle.status == StatusText("等待接入", .idle))
        #expect(idle.controller == "尚无控制者")
        let busy = DesktopControlPresentation.make(desktop: desk, activeRuns: [run(phase: "running")])
        #expect(busy.status == StatusText("Agent 操作中", .running))
        #expect(busy.actionCount == 2)
        #expect(busy.source == "来自运行记录")
        let stopping = DesktopControlPresentation.make(desktop: desk, activeRuns: [run(phase: "stopping")])
        #expect(stopping.status.text == "停止中")
        let manual = DesktopControlPresentation.make(desktop: desk, activeRuns: [run(phase: "running", origin: "user")])
        #expect(manual.status == StatusText("人工控制中", .attention))
        #expect(DesktopControlPresentation.sizeText(desk) == "1280 × 800")
    }
}

@MainActor
@Suite("StateBadge")
struct StateBadgeTests {
    // Text and colour together: the words are what is read aloud, and the
    // rendered badge carries the tone's colour.
    @Test(arguments: StatusTone.allCases)
    func textAndColour(tone: StatusTone) throws {
        let badge = StateBadge("状态文字", tone: tone)
        #expect(badge.accessibilityText == "状态文字")
        #expect(tone.foregroundHex != tone.backgroundHex)
        let png = try #require(SnapshotRenderer.png(badge.padding(4), size: CGSize(width: 140, height: 36), scale: 1))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(containsColour(rep, tone.foregroundHex), "badge for \(tone) shows its tone colour; top: \(colours(rep))")
        #expect(containsColour(rep, tone.backgroundHex), "badge for \(tone) shows its background")
    }

    /// Exact sRGB bytes (NSBitmapImageRep.colorAt converts through another
    /// space and shifts values, so the pixels are read raw).
    func pixels(_ rep: NSBitmapImageRep) -> [UInt32] {
        guard let cg = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        return (0..<(cg.width * cg.height)).compactMap { i in
            p[i * 4 + 3] == 255 ? UInt32(p[i * 4]) << 16 | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) : nil
        }
    }

    func containsColour(_ rep: NSBitmapImageRep, _ hex: UInt32) -> Bool {
        pixels(rep).contains { px in
            [16, 8, 0].allSatisfy { sh in abs(Int((px >> UInt32(sh)) & 0xFF) - Int((hex >> UInt32(sh)) & 0xFF)) <= 3 }
        }
    }

    func colours(_ rep: NSBitmapImageRep) -> [String] {
        var seen: [UInt32: Int] = [:]
        for p in pixels(rep) { seen[p, default: 0] += 1 }
        return seen.sorted { $0.value > $1.value }.prefix(8).map { String(format: "%06x:%d", $0.key, $0.value) }
    }
}

@Suite("Problems and tokens")
struct ProblemAndTokenTests {
    // Every runtime/1 error code has its own Chinese text.
    @Test func everyCodeHasText() {
        for spec in RuntimeContract.shared.errors {
            let (title, _) = RuntimeProblem.text(spec.code)
            #expect(title != "发生未识别的错误", "no text for \(spec.code)")
        }
        #expect(RuntimeProblem(RuntimeError.runtimeOffline("x", endpoint: "y")).isDisconnection)
        #expect(!RuntimeProblem(RuntimeError.notFound("x")).isDisconnection)
    }

    @Test func tokensMatchDesignFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/design/v2/tokens.json")
        let json = try StrictJSON.parse(Data(contentsOf: url))
        for (name, hex) in ADColor.hex {
            #expect(json["color"]?[name]?.stringValue == String(format: "#%06x", hex), "\(name)")
        }
        for tone in StatusTone.allCases {
            #expect(json["status"]?[tone.rawValue]?["foreground"]?.stringValue == String(format: "#%06x", tone.foregroundHex))
            #expect(json["status"]?[tone.rawValue]?["background"]?.stringValue == String(format: "#%06x", tone.backgroundHex))
        }
        #expect(json["space"]?.arrayValue?.compactMap(\.intValue) == ADSpace.all.map { Int($0) })
        #expect(json["layout"]?["sidebar"]?.intValue == Int(ADLayout.sidebarWidth))
        #expect(json["layout"]?["titleBar"]?.intValue == Int(ADLayout.titleBarHeight))
        #expect(json["layout"]?["statusBar"]?.intValue == Int(ADLayout.statusBarHeight))
        #expect(json["layout"]?["contentPadding"]?.intValue == Int(ADLayout.contentPadding))
        #expect(json["layout"]?["buttonMinHeight"]?.intValue == Int(ADLayout.buttonMinHeight))
        #expect(json["radius"]?["button"]?.intValue == Int(ADRadius.button))
        #expect(json["radius"]?["panel"]?.intValue == Int(ADRadius.panel))
        #expect(json["font"]?["pageTitle"]?.intValue == Int(ADFont.pageTitleSize))
        #expect(json["font"]?["sectionTitle"]?.intValue == Int(ADFont.sectionTitleSize))
        #expect(json["font"]?["body"]?.intValue == Int(ADFont.bodySize))
        #expect(json["font"]?["note"]?.intValue == Int(ADFont.noteSize))
    }

    @Test func endpointRule() {
        #expect(ProviderEndpointRule.error("https://example.com/v1", allowLocalHTTP: false) == nil)
        #expect(ProviderEndpointRule.error("http://example.com/v1", allowLocalHTTP: true) == "非本机地址必须使用 HTTPS")
        #expect(ProviderEndpointRule.error("http://127.0.0.1:8000/v1", allowLocalHTTP: true) == nil)
        #expect(ProviderEndpointRule.error("ftp://x", allowLocalHTTP: true) != nil)
    }

    @Test func codeBoxJSON() {
        #expect(CodeBox.isValidJSON(#"{"mcpServers":{"agentdesktop":{"command":"agentdesktop","args":["mcp"]}}}"#))
        #expect(!CodeBox.isValidJSON(#"{"a":1,"a":2}"#))
        #expect(!CodeBox.isValidJSON("agentdesktop observe"))
    }
}
