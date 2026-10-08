import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// GUI-001, GUI-002, GUI-004 (codec and proposal side). Executor and
// Runtime counts belong to T07; here no codec or factory can reach a
// screen or input at all (they hold none), which GUI-001 checks directly.

enum Fixture {
    static let stamp = ObservationStamp(sessionId: "sess-A", desktopId: "desktopA", snapshotId: "snapS1",
                                        bindingEpoch: 1, runGeneration: 1)
    static let target = TargetIdentity(appId: "com.agentdesktop.neutral-form", processId: 4242, processStartId: "ps-1",
                                       windowId: "w-1", windowGeometryRevision: 3, backendId: "macos-sky",
                                       windowFrameDesktopLogical: GuiRect(x: -1440, y: 120, width: 800, height: 500))
    /// 1600x1000 source shown 1:1; Retina 2x to the desktop at (-1440,120).
    static func shot(_ id: String = "shot-1", transform: ScreenshotTransform? = nil) throws -> ScreenshotDescriptor {
        try ScreenshotDescriptor(screenshotId: id, artifactRef: "art-\(id)", sha256: String(repeating: "a", count: 64),
                                 mimeType: "image/png", transformVersion: "t1",
                                 sourceToDesktop: affine([0.5, 0, 0, 0.5, -1440, 120]),
                                 transform: transform ?? .pipeline(sourceSize: Size(width: 1600, height: 1000)))
    }
    static func observation(_ shots: [ScreenshotDescriptor]? = nil) throws -> Observation {
        Observation(observationId: "obs-1", stamp: stamp, target: target,
                    observedAt: Date(timeIntervalSince1970: 1_791_000_000), screenshots: try shots ?? [shot()])
    }
    static var context: CodecContext {
        CodecContext(transform: try! .pipeline(sourceSize: Size(width: 1600, height: 1000)), maxWaitMs: 2000)
    }
}

let uitars = UITarsCodec(coordinateProtocol: .normalized1000)
let fixtureCodec = FixtureJsonCodec(coordinateProtocol: .normalized1000)

func decodeCode(_ codec: GuiActionCodec, _ text: String) -> ErrorCode? {
    code { _ = try codec.decode(text, context: Fixture.context) }
}

@Suite("UI-TARS codec")
struct UITarsCodecTests {
    // GUI-002: golden suggestions, one variant each.
    @Test(arguments: [
        ("Thought: 点击姓名输入框\nAction: click(start_box='(500,500)')",
         GuiProposalBody.action(.click(sourcePixel: Point(x: 800, y: 500)))),
        ("Action: click(start_box='[100, 200, 300, 400]')",
         .action(.click(sourcePixel: Point(x: 320, y: 300)))),
        ("Action: click(point='<point>383 117</point>')",
         .action(.click(sourcePixel: Point(x: 612.8, y: 117)))),
        ("Action: type(content='Ada')", .action(.type(text: "Ada"))),
        ("Action: type(content='第二行\\n')", .action(.type(text: "第二行\n"))),
        ("Action: hotkey(key='ctrl c')", .action(.key(keys: ["Control", "C"]))),
        ("Action: hotkey(key='cmd+shift+page down')", .action(.key(keys: ["Meta", "Shift", "PageDown"]))),
        ("Action: scroll(start_box='(500,500)', direction='down')",
         .action(.scroll(sourcePixel: Point(x: 800, y: 500), direction: .down, amountPixels: UITarsCodec.scrollAmountPixels))),
        ("Action：wait()", .wait(milliseconds: 2000)),
        ("Thought: 已保存\nAction: finished(content='saved')", .finish(reason: "saved")),
        ("Action: finished()", .finish(reason: "finished")),
        ("Action: call_user(content='请先登录')", .needsUser(reasonCode: "model_requested_user", message: "请先登录")),
    ])
    func gui002Golden(reply: String, expected: GuiProposalBody) throws {
        let d = try uitars.decode(reply, context: Fixture.context)
        if case let .action(.click(p)) = d.body, case let .action(.click(e)) = expected {
            #expect(near(p, e.x, e.y))
        } else {
            #expect(d.body == expected)
        }
        // Every golden becomes a contract-valid proposal.
        let (proposal, _) = try ProposalFactory().propose(codec: uitars, modelOutput: reply, runId: "run-1", stepIndex: 0,
                                                          inferenceAttemptId: "att-1", observation: try Fixture.observation(),
                                                          screenshotId: "shot-1", maxWaitMs: 2000)
        #expect(try ContractBundle.shared.validate(proposal.json, "GuiProposal").isEmpty)
    }

    // GUI-002: anything but exactly one v1 action is refused.
    @Test(arguments: [
        ("hover(start_box='(1,1)')", ErrorCode.invalidAction),
        ("Action: hover(start_box='(1,1)')", .invalidAction),
        ("Action: drag(start_box='(1,1)', end_box='(5,5)')", .invalidAction),
        ("Action: left_double(start_box='(1,1)')", .invalidAction),
        ("Action: right_single(start_box='(1,1)')", .invalidAction),
        ("Action: click(element='3')", .invalidAction),
        ("Action: click(start_box='(1,1)')\n\nclick(start_box='(2,2)')", .invalidAction),
        ("Action: click(start_box='(1,1)')\nAction: type(content='x')", .invalidAction),
        ("Action: click(start_box='(1,1)'); type(content='x')", .invalidAction),
        ("Action: click(start_box='(1,1)', start_box='(2,2)')", .invalidAction),
        ("Action: click(start_box=(1,1))", .invalidAction),
        ("Action: click()", .invalidAction),
        ("Action: type(content='a\u{07}b')", .invalidAction),
        ("Action: hotkey(key='ctrl fn')", .invalidAction),
        ("Action: hotkey(key='ctrl ctrl')", .invalidAction),
        ("Action: hotkey(key='ctrl shift alt cmd c')", .invalidAction),
        ("Action: scroll(start_box='(1,1)', direction='sideways')", .invalidAction),
        ("Action: scroll(start_box='(1,1)', direction='down', amount='99999')", .invalidAction),
        ("Action: finished(content='\(String(repeating: "x", count: 513))')", .invalidAction),
        ("Action: click(start_box='[383]')", .invalidAction),
        ("Action: click(start_box='[300, 400, 100, 200]')", .invalidAction),
        ("Action: click(start_box='(abc,1)')", .invalidAction),
        ("Action: click(start_box='(1000,10)')", .coordinateOutOfBounds),
        ("Action: click(start_box='(-5,10)')", .coordinateOutOfBounds),
        ("data: {\"choices\":[{\"delta\":{\"content\":\"Action: click\"}}]}", .invalidAction),
        ("Action: click(start_box='(1,1", .invalidAction),
        ("", .invalidAction),
        ("not an action at all", .invalidAction),
    ])
    func gui002Refusals(reply: String, expected: ErrorCode) {
        #expect(decodeCode(uitars, reply) == expected, "\(reply)")
    }

    // Replies from the old lenient parser's tests (2ndscreen da5677c
    // Tests/TarsAgentTests/TarsAgentTests.swift): the well-formed ones still
    // decode; the ones it guessed at are now refused.
    @Test func legacyParserRegression() throws {
        let accepted: [(String, GuiProposalBody)] = [
            ("Thought: 点击文件传输助手。\nAction: click(start_box='[100, 200, 300, 400]')", .action(.click(sourcePixel: Point(x: 320, y: 300)))),
            ("Action: click(start_box='(500,250)')", .action(.click(sourcePixel: Point(x: 800, y: 250)))),
            ("Action: click(start_box='[383 117]')", .action(.click(sourcePixel: Point(x: 612.8, y: 117)))),
            ("Action: click(start_box='<|box_start|>(10,20)<|box_end|>')", .action(.click(sourcePixel: Point(x: 16, y: 20)))),
            ("Action: type(content='你好，世界\\n')", .action(.type(text: "你好，世界\n"))),
            ("Action: finished(content='done, really')", .finish(reason: "done, really")),
            ("Action：wait()", .wait(milliseconds: 2000)),
        ]
        for (reply, expected) in accepted {
            let body = try uitars.decode(reply, context: Fixture.context).body
            if case let .action(.click(p)) = body, case let .action(.click(e)) = expected {
                #expect(near(p, e.x, e.y), "\(reply)")
            } else {
                #expect(body == expected, "\(reply)")
            }
        }
        // The old parser rescaled 0..1 values by guessing; uitars_v1 under
        // normalized_1000 takes them as tiny normalized values instead.
        let tiny = try uitars.decode("Action: click(start_box='(0.5,0.25)')", context: Fixture.context).body
        #expect(tiny == .action(.click(sourcePixel: Point(x: 0.8, y: 0.25))))
        for refused in ["not an action at all", "Action: click(start_box='[383]')",
                        "Action: drag(start_box='(100,200)', end_box='(300,400)')",
                        "Action: hotkey(key='ctrl c')\n\nfinished()"] {
            #expect(decodeCode(uitars, refused) != nil, "\(refused)")
        }
    }

    @Test func thoughtIsKeptButNeverParsed() throws {
        let d = try uitars.decode("Thought: Action items: click(start_box='(9,9)') later\nAction: finished(content='ok')", context: Fixture.context)
        #expect(d.body == .finish(reason: "ok"))
        #expect(d.thought?.contains("Action items") == true)
    }

    @Test func waitHonoursTheProfileLimit() throws {
        let zero = CodecContext(transform: Fixture.context.transform, maxWaitMs: 0)
        #expect(try uitars.decode("Action: wait()", context: zero).body == .wait(milliseconds: 0))
    }

    @Test func actionSpaceNamesOnlyV1Actions() {
        let text = UITarsCodec.actionSpace(for: .normalized1000)
        for name in ["click(", "type(", "hotkey(", "scroll(", "wait(", "finished(", "call_user("] { #expect(text.contains(name)) }
        for name in ["drag(", "left_double(", "right_single(", "element="] { #expect(!text.contains(name)) }
    }
}

@Suite("Fixture codec and registry")
struct FixtureCodecTests {
    @Test func productionRegistryRefusesTheFixtureAdapter() throws {
        let production = GuiCodecRegistry()
        #expect(production.fixtureAdapterEnabled == false)
        #expect(production.availableAdapters == [.uitarsV1])
        #expect(code { _ = try production.codec(adapterId: "fixture_json_v1", coordinateProtocol: "normalized_1000") } == .capabilityMismatch)
        #expect(code { _ = try production.codec(adapterId: "openai_cua", coordinateProtocol: "normalized_1000") } == .capabilityMismatch)
        #expect(try production.codec(adapterId: "uitars_v1", coordinateProtocol: "image_pixels").provenance.adapterId == .uitarsV1)
        let test = GuiCodecRegistry(fixtureAdapterEnabled: true)
        #expect(try test.codec(adapterId: "fixture_json_v1", coordinateProtocol: "normalized_1000").provenance.adapterId == .fixtureJsonV1)
    }

    @Test func goldens() throws {
        let cases: [(String, GuiProposalBody)] = [
            (#"{"kind":"action","action":{"type":"click","x":500,"y":500,"button":"left"}}"#, .action(.click(sourcePixel: Point(x: 800, y: 500)))),
            (#"{"kind":"action","action":{"type":"type","text":"Ada"}}"#, .action(.type(text: "Ada"))),
            (#"{"kind":"action","action":{"type":"key","keys":["Meta","A"]}}"#, .action(.key(keys: ["Meta", "A"]))),
            (#"{"kind":"action","action":{"type":"scroll","x":10,"y":10,"direction":"up","amountPixels":120}}"#,
             .action(.scroll(sourcePixel: Point(x: 16, y: 10), direction: .up, amountPixels: 120))),
            (#"{"kind":"wait","waitMs":0}"#, .wait(milliseconds: 0)),
            (#"{"kind":"finish","reason":"done"}"#, .finish(reason: "done")),
            (#"{"kind":"needs_user","reasonCode":"login_required","message":"log in"}"#, .needsUser(reasonCode: "login_required", message: "log in")),
        ]
        for (text, expected) in cases {
            #expect(try fixtureCodec.decode(text, context: Fixture.context).body == expected, "\(text)")
        }
    }

    // GUI-001: a hostile reply with execution fields gains nothing.
    @Test(arguments: [
        #"{"kind":"action","action":{"type":"click","x":1,"y":1,"button":"left"},"approval":true}"#,
        #"{"kind":"action","action":{"type":"click","x":1,"y":1,"button":"left","execute":"rm -rf ~"}}"#,
        #"{"kind":"execute","shell":"open -a Terminal"}"#,
        #"{"kind":"action","action":{"type":"screenshot","path":"/etc"}}"#,
        #"{"kind":"action","action":{"type":"raw_event","cgEvent":1}}"#,
        #"{"kind":"action","action":{"type":"drag","x":1,"y":1}}"#,
        #"{"kind":"action","action":{"type":"click","x":1,"y":1,"button":"right"}}"#,
        #"{"kind":"wait","waitMs":-1}"#,
        #"{"kind":"wait","waitMs":1.5}"#,
        #"{"kind":"finish","reason":"ok","snapshotId":"snap-other"}"#,
        #"{"kind":"finish","reason":"ok","kind":"wait"}"#,
        #"[{"kind":"finish","reason":"a"},{"kind":"finish","reason":"b"}]"#,
        #"{"kind":"action","action":{"type":"key","keys":["Control","Control"]}}"#,
        #"{"kind":"action","action":{"type":"key","keys":["F13"]}}"#,
    ])
    func gui001HostileFixtureReplies(reply: String) {
        #expect(decodeCode(fixtureCodec, reply) == .invalidAction, "\(reply)")
    }

    @Test func gui001HostileUITarsArguments() {
        for reply in ["Action: click(start_box='(1,1)', execute='rm -rf ~')",
                      "Action: click(start_box='(1,1)', approval='true')",
                      "Action: type(content='x', shell='open -a Terminal')",
                      "Action: screenshot(path='/etc/passwd')",
                      "Action: eval(code='1+1')"] {
            #expect(decodeCode(uitars, reply) == .invalidAction, "\(reply)")
        }
    }

    @Test func waitBounds() {
        #expect(decodeCode(fixtureCodec, #"{"kind":"wait","waitMs":2001}"#) == .limitExceeded)
        let wide = CodecContext(transform: Fixture.context.transform, maxWaitMs: 5000)
        #expect(code { _ = try fixtureCodec.decode(#"{"kind":"wait","waitMs":5000}"#, context: wide) } == nil)
        #expect(code { _ = try fixtureCodec.decode(#"{"kind":"wait","waitMs":5001}"#, context: wide) } == .limitExceeded)
    }
}

@Suite("Proposals")
struct ProposalTests {
    // GUI-001: codecs hold no capability, and a proposal carries no authority.
    @Test func gui001NoCapabilitiesAndNoAuthorityFields() throws {
        #expect(Mirror(reflecting: uitars).children.map(\.label) == ["provenance"])
        #expect(Mirror(reflecting: fixtureCodec).children.map(\.label) == ["provenance"])
        let obs = try Fixture.observation()
        #expect(code {
            _ = try ProposalFactory().propose(codec: uitars, modelOutput: "Action: click(start_box='(1,1)', approval='true')",
                                              runId: "run-1", stepIndex: 0, inferenceAttemptId: "att-1",
                                              observation: obs, screenshotId: "shot-1", maxWaitMs: 2000)
        } == .invalidAction)
    }

    @Test func gui001ProposalKeysAreExactlyTheContractKeys() throws {
        let (p, _) = try ProposalFactory().propose(codec: uitars, modelOutput: "Action: click(start_box='(500,500)')",
                                                   runId: "run-1", stepIndex: 3, inferenceAttemptId: "att-9",
                                                   observation: try Fixture.observation(), screenshotId: "shot-1", maxWaitMs: 2000)
        let keys = Set(p.json.objectMembers!.map(\.key))
        #expect(keys == ["proposalId", "runId", "stepIndex", "inferenceAttemptId", "desktopId", "snapshotId",
                         "bindingEpoch", "runGeneration", "screenshotId", "provenance", "kind", "action"])
        #expect(p.json["provenance"]?["adapterId"]?.stringValue == "uitars_v1")
        #expect(p.json["provenance"]?["parserVersion"]?.stringValue == UITarsCodec.parserVersion)
    }

    // GUI-004 (codec side): identity comes from the observation, never the text.
    @Test func gui004IdentityFromTheObservation() throws {
        let obs = try Fixture.observation()
        let reply = "Thought: use snapshotId='snap-evil' desktopId='desktopB'\nAction: click(start_box='(500,500)')"
        let (p, _) = try ProposalFactory().propose(codec: uitars, modelOutput: reply, runId: "run-1", stepIndex: 0,
                                                   inferenceAttemptId: "att-1", observation: obs, screenshotId: "shot-1", maxWaitMs: 2000)
        #expect(p.stamp == obs.stamp)
        #expect(p.json["desktopId"]?.stringValue == "desktopA")
        #expect(p.json["snapshotId"]?.stringValue == "snapS1")
        #expect(p.json["bindingEpoch"]?.intValue == 1)
        #expect(p.json["runGeneration"]?.intValue == 1)
        #expect(p.screenshotId == "shot-1")
        #expect(p.inferenceAttemptId == "att-1")
        // Fields smuggled as call arguments or JSON members are refused.
        #expect(decodeCode(uitars, "Action: click(start_box='(1,1)', snapshotId='snap-evil')") == .invalidAction)
        #expect(decodeCode(fixtureCodec, #"{"kind":"finish","reason":"ok","desktopId":"desktopB"}"#) == .invalidAction)
        // A screenshot not in this observation is stale.
        #expect(code {
            _ = try ProposalFactory().propose(codec: uitars, modelOutput: "Action: finished()", runId: "run-1", stepIndex: 0,
                                              inferenceAttemptId: "att-1", observation: obs, screenshotId: "shot-other", maxWaitMs: 2000)
        } == .staleObservation)
    }

    // GUI-004: the codec maps with the chosen screenshot's own transform.
    @Test func gui004UsesTheBoundScreenshotsTransform() throws {
        let cropped = try ScreenshotTransform.pipeline(sourceSize: Size(width: 1600, height: 1000),
                                                       crop: GuiRect(x: 200, y: 100, width: 1000, height: 600),
                                                       resizedSize: Size(width: 500, height: 300))
        let obs = try Fixture.observation([try Fixture.shot("shot-1"), try Fixture.shot("shot-2", transform: cropped)])
        let codec = UITarsCodec(coordinateProtocol: .imagePixels)
        let (p, _) = try ProposalFactory().propose(codec: codec, modelOutput: "Action: click(start_box='(250,150)')", runId: "run-1",
                                                   stepIndex: 0, inferenceAttemptId: "att-1", observation: obs,
                                                   screenshotId: "shot-2", maxWaitMs: 2000)
        guard case let .action(.click(s)) = p.body else { Issue.record("not a click"); return }
        #expect(near(s, 700, 400))
        let desktop = try CoordinateMapper.desktopPoint(fromSource: s, screenshot: obs.screenshot("shot-2")!)
        #expect(near(desktop, -1090, 320))
    }

    // GUI-002: typed text is redacted in ordinary descriptions.
    @Test func gui002TypedTextIsRedacted() throws {
        let secret = "MAC-001-A 的密码是 hunter2"
        let (p, _) = try ProposalFactory().propose(codec: uitars, modelOutput: "Action: type(content='\(secret)')",
                                                   runId: "run-1", stepIndex: 0, inferenceAttemptId: "att-1",
                                                   observation: try Fixture.observation(), screenshotId: "shot-1", maxWaitMs: 2000)
        #expect(!p.redactedDescription.contains("hunter2"))
        #expect(p.redactedDescription.contains("<\(secret.count) chars>"))
        #expect(!p.body.redactedDescription.contains("密码"))
    }

    @Test func factoryRefusesOutOfRangeStepAndPoints() throws {
        let obs = try Fixture.observation()
        let f = ProposalFactory()
        #expect(code { _ = try f.make(runId: "run-1", stepIndex: 20, inferenceAttemptId: "att-1", observation: obs,
                                      screenshotId: "shot-1", provenance: uitars.provenance, body: .finish(reason: "x")) } == .validationError)
        #expect(code { _ = try f.make(runId: "run-1", stepIndex: 0, inferenceAttemptId: "att-1", observation: obs,
                                      screenshotId: "shot-1", provenance: uitars.provenance,
                                      body: .action(.click(sourcePixel: Point(x: 1600, y: 1)))) } == .coordinateOutOfBounds)
    }

    @Test func observationEncodesToTheContract() throws {
        #expect(try ContractBundle.shared.validate(try Fixture.observation().json, "Observation").isEmpty)
    }
}
