import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopGUI

// GUI-003 detail: element_text_equals compares after cross-platform
// normalization, which removes only invisible bidi formatting and relies on
// canonical equivalence; it never becomes a fuzzy match.
@Suite("GoalVerifier normalization")
struct GoalVerifierNormalizationTests {
    @Test(arguments: [
        ("\u{200E}10\u{200E}", "10", true),                 // macOS Calculator display
        ("\u{2066}已保存：Ada\u{2069}", "已保存：Ada", true),
        ("\u{FEFF}OK", "OK", true),
        ("Cafe\u{0301}", "Café", true),                      // NFD vs NFC
        ("10 ", "10", false),                                // trailing space still matters
        ("１０", "10", false),                                // full width digits are different text
        ("ada", "Ada", false),
        ("\u{200B}10", "10", false),                         // zero width space is not bidi formatting
        ("100", "10", false),
    ])
    func normalizedEquality(observed: String, expected: String, equal: Bool) {
        #expect((GoalVerifier.normalized(observed) == GoalVerifier.normalized(expected)) == equal, "\(observed.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}
