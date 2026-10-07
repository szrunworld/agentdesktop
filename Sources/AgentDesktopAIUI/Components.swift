import SwiftUI

struct ProblemBanner: View {
    let problem: UIProblem
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).bold()
                Text(problem.advice).font(.callout)
                if let r = problem.currentRevision { Text("服务器当前版本 r\(r)").font(.caption) }
                Text(problem.code.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let retry { Button("重试", action: retry) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("错误：\(problem.title)。\(problem.advice)")
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1) }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
