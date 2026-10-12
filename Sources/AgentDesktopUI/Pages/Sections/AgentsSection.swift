import SwiftUI

/// Agents (U4): owned by lane UI-C (Agents 页; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file. The pages are in Pages/Agents*.swift.
struct AgentsSection: View {
    let context: SectionContext
    @StateObject private var model: AgentsModel

    init(context: SectionContext) {
        self.context = context
        _model = StateObject(wrappedValue: AgentsModel(store: context.store))
    }

    var body: some View { AgentsPageView(context: context, model: model) }
}
