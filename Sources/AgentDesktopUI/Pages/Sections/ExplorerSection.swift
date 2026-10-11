import SwiftUI

/// GUI Explorer (U7): owned by lane UI-E (Explorer 页; docs/plan/11-parallel-lanes.md).
/// Only that lane edits this file.
///
/// Starting needs the in-process Durable entry in the environment
/// (`\.explorerDurableStart`, which the host fills from
/// `RuntimeService.startDurableUnitRun`); without it the page only observes.
struct ExplorerSection: View {
    let context: SectionContext
    @Environment(\.explorerDurableStart) private var starter

    var body: some View {
        ExplorerPage(store: context.store, navigation: context.navigation, connectionState: context.connectionState,
                     retry: context.retry, starter: starter)
    }
}
