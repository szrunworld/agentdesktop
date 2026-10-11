import SwiftUI

/// Inbox (U9): owned by lane UI-A (Runs、Inbox 与 Store; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file.
///
/// The Inbox page when the Runtime offers `inbox.list` (PR4); a Runtime
/// without it keeps the "not yet" page (06 §6.1).
struct InboxSection: View {
    let context: SectionContext
    @ObservedObject var store: ShellStore

    init(context: SectionContext) {
        self.context = context
        store = context.store
    }

    var body: some View {
        if store.capabilities == nil || store.offers("inbox.list") {
            InboxPage(store: store, navigation: context.navigation)
        } else {
            InboxNotEnabledView()
        }
    }
}
