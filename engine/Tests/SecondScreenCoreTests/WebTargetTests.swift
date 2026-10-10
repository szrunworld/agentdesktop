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

/// #249: a web target is checked against the whole tree, never the
/// filtered one `state` showed: the recapture is unfiltered (the capture
/// takes no query) and compared with the snapshot's unfiltered tree.
/// Filtered on both sides, a change outside the filter (the item a reused
/// Delete button acts on) would pass; a filtered tree against a full one
/// would refuse every input.
@Test func theWebTargetIsCheckedAgainstTheWholeTree() {
    let element = AXElementInfo(index: 1, role: "AXButton", label: "Delete",
                                frame: CGRect(x: 10, y: 10, width: 40, height: 20))
    func snapshot(tree: String, fullTree: String? = nil) -> AXSnapshot {
        AXSnapshot(windowID: 7, elements: [element], tree: tree, handles: [:], web: [1], truncated: nil, fullTree: fullTree)
    }
    let button = "- [1] AXButton \"Delete\""
    // Observed with a filter: `tree` shows the button, `fullTree` also the
    // item it deletes.
    let observed = snapshot(tree: button, fullTree: "- AXStaticText = \"Invoice 17\"\n" + button)
    // Unchanged page, captured unfiltered: the trees compared are equal.
    let same = observed.webEvidenceTrees(against: snapshot(tree: "- AXStaticText = \"Invoice 17\"\n" + button))
    #expect(same.old == same.new)
    // The button stayed, the item changed: the trees compared differ.
    let changed = observed.webEvidenceTrees(against: snapshot(tree: "- AXStaticText = \"Invoice 18\"\n" + button))
    #expect(changed.old != changed.new)
    #expect(throws: AccessibilityError.self) {
        try AXSnapshot.requireCurrentWebEvidence(oldTree: changed.old, newTree: changed.new, complete: true,
                                                sameIdentity: true, sameGeometry: true, hitMatches: true)
    }
    // Never the filtered tree.
    #expect(changed.old != observed.tree)
}
