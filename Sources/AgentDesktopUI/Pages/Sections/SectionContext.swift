import SwiftUI

/// What a first-level entry's page gets from the main window: the Store,
/// the navigation, the connection state for its PageContainer, and how to
/// retry the connection. Shared by every lane; change it only in a PR of
/// its own (docs/plan/11-parallel-lanes.md).
@MainActor
public struct SectionContext {
    public let store: ShellStore
    public let navigation: ShellNavigation
    public let connectionState: PageState
    public let retry: () -> Void

    public init(store: ShellStore, navigation: ShellNavigation, connectionState: PageState, retry: @escaping () -> Void) {
        self.store = store
        self.navigation = navigation
        self.connectionState = connectionState
        self.retry = retry
    }
}

/// The "not yet" page of an entry whose delivery has not landed.
struct PendingEntryPage: View {
    let context: SectionContext
    let section: MainSection

    var body: some View {
        PageContainer(state: context.connectionState, retry: context.retry, header: {
            PageHeader(eyebrow: section.eyebrow, title: section.title, subtitle: section.subviews.joined(separator: " · "))
        }) { PendingSection(delivery: section.delivery) }
    }
}
