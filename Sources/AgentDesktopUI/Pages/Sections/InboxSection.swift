import SwiftUI

/// Inbox (U9): owned by lane UI-A (Runs、Inbox 与 Store; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file.
struct InboxSection: View {
    let context: SectionContext

    var body: some View {
        InboxNotEnabledView()
    }
}
