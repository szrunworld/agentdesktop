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
        // The navigation's target (a Run from elsewhere, or P27 for a
        // Desktop) seeds the page; a new target makes a new page.
        let n = context.navigation
        ExplorerPage(store: context.store, navigation: n, connectionState: context.connectionState,
                     retry: context.retry, starter: starter,
                     route: n.explorerRunId.map { .run($0) } ?? .history,
                     composing: n.explorerDesktopId != nil,
                     draft: ExplorerDraft(desktopId: n.explorerDesktopId))
            .id("\(n.explorerRunId ?? "")|\(n.explorerDesktopId ?? "")")
    }
}
