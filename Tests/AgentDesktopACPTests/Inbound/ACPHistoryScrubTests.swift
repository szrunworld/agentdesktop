import Testing
@testable import AgentDesktopACP

/// Legacy (format 1) agent lines: echoes go, useful status stays (Kevin's S4
/// ruling; b9's third review of #141 for the /runs cases).
struct ACPHistoryScrubTests {
    let runs: Set<String> = ["run-1", "run-2"]
    let cleared = "（不属于本会话的任务，已清除）"

    private func scrub(_ t: String) -> String { ACPHistoryScrub.legacyAgent(t, runIds: runs).0 }

    @Test(arguments: [
        "任务 hunter2：状态待核实（不会自动重试）",
        "密码：hunter2：状态待核实（不会自动重试）",
        "正在停止任务 hunter2 secret：阶段 stopping",
        "任务 hunter2 已结束：阶段 ended：状态待核实（不会自动重试）",
        "a\nhunter2 b：状态待核实（不会自动重试）",
        "hunter2\n任务 run-1 已结束：阶段 ended：状态待核实（不会自动重试）",
        "任务 run-1 已结束：阶段 ended\nhunter2：阶段 x",
    ])
    func echoedRunsArgumentsNeverSurvive(_ text: String) {
        let out = scrub(text)
        #expect(!out.contains("hunter2"), "\(out)")
        #expect(ACPHistoryScrub.legacyAgent(text, runIds: runs).1 == .changed)
    }

    @Test func knownStatusLinesAreKept() {
        #expect(scrub("任务 run-1 已结束：阶段 ended，结果 succeeded") == "任务 run-1 已结束：阶段 ended，结果 succeeded")
        #expect(scrub("正在停止任务 run-2：阶段 stopping") == "正在停止任务 run-2：阶段 stopping")
        #expect(ACPHistoryScrub.legacyAgent("任务 run-1 已结束：阶段 ended", runIds: runs).1 == .kept)
        let runsOutput = "run-1：阶段 ended，结果 succeeded\nrun-2：状态待核实（不会自动重试）"
        #expect(scrub(runsOutput) == ACPRedactor.redact(runsOutput))
    }

    @Test func aStatusLineAboutAnotherSessionsRunIsCleared() {
        #expect(scrub("任务 run-9 已结束：阶段 ended") == cleared)
        #expect(scrub("run-1：阶段 ended\nrun-9：阶段 ended") == ACPRedactor.redact("run-1：阶段 ended\n" + cleared))
    }

    @Test func ordinaryLinesAreKept() {
        #expect(scrub("任务已受理：run-1（工作）。") == "任务已受理：run-1（工作）。")
        #expect(scrub("本会话还没有任务。") == "本会话还没有任务。")
    }
}
