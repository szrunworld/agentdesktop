import ApplicationServices
import Foundation
import Testing
@testable import SecondScreenCore

@Test(arguments: ["scroll", "relayout", "removed", "covered", "content", "incomplete"])
func webTargetChangesRefuseBeforeInput(scenario: String) {
    var inputs = 0
    do {
        try AXSnapshot.requireCurrentWebEvidence(
            oldTree: "observed", newTree: scenario == "content" ? "changed" : "observed",
            complete: scenario != "incomplete", sameIdentity: scenario != "removed",
            sameGeometry: scenario != "scroll" && scenario != "relayout", hitMatches: scenario != "covered")
        inputs += 1
        Issue.record("changed target should be refused")
    } catch { #expect(error is AccessibilityError) }
    #expect(inputs == 0)
}

@Test func unchangedWebTargetPassesTheEvidenceGate() throws {
    try AXSnapshot.requireCurrentWebEvidence(oldTree: "observed", newTree: "observed", complete: true,
                                            sameIdentity: true, sameGeometry: true, hitMatches: true)
}

/// #249: the recapture that checks a web target walks with the filter the
/// snapshot was taken with; without it a filtered tree never equals the
/// fresh full one, and every input from a filtered observation is refused.
@Test(arguments: [String?.none, "continue"])
func theWebTargetRecaptureKeepsTheSnapshotsQuery(query: String?) throws {
    let element = AXElementInfo(index: 1, role: "AXButton", label: "Continue",
                                frame: CGRect(x: 10, y: 10, width: 40, height: 20))
    let snapshot = AXSnapshot(windowID: 7, elements: [element], tree: "[1] AXButton Continue",
                              handles: [1: AXUIElementCreateApplication(getpid())], web: [1], truncated: nil, query: query)
    let window = WindowInfo(pid: getpid(), windowID: 7, appName: "Test", title: "", frame: .zero)
    var asked: [String?] = []
    struct Stop: Error {}
    do {
        try snapshot.validateWebTarget(1, in: window) { _, q, _ in asked.append(q); throw Stop() }
        Issue.record("the recapture was expected to run and stop the check")
    } catch is Stop {}
    #expect(asked == [query])
}
