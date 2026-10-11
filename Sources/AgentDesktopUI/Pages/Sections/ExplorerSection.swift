import SwiftUI

/// GUI Explorer (U7): owned by lane UI-E (Explorer 页; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file.
struct ExplorerSection: View {
    let context: SectionContext

    var body: some View {
        PendingEntryPage(context: context, section: .explorer)
    }
}
