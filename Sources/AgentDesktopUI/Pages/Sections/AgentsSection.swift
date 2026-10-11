import SwiftUI

/// Agents (U4): owned by lane UI-C (Agents 页; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file.
struct AgentsSection: View {
    let context: SectionContext

    var body: some View {
        PendingEntryPage(context: context, section: .agents)
    }
}
