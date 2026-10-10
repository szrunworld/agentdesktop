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
