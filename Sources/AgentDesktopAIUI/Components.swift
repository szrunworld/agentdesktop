import SwiftUI
import AgentDesktopUI

/// A service failure in the shell's ProblemView. EmptyState and LabeledValue
/// now come from AgentDesktopUI; this adapter goes when the pages move to
/// runtime/1 (U6b).
struct ProblemBanner: View {
    let problem: UIProblem
    var retry: (() -> Void)?

    var body: some View {
        ProblemView(title: problem.title, advice: problem.advice, code: problem.code.rawValue,
                    extra: problem.currentRevision.map { ["服务器当前版本 r\($0)"] } ?? [], retry: retry)
    }
}
