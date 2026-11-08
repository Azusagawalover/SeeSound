import Foundation

/// Reject empty/control/punctuation-only decoder output; preserve readable text
/// even if the speaker repeats words. This is a format guard, not an accuracy score.
enum SpeechTranscriptPolicy {
    static func hasReadableContent(_ text:String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
}
