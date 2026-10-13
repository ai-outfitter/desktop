import XCTest
@testable import PiNative

/// Covers the pure draft-composition rules behind composer voice dictation.
final class VoiceDictationTests: XCTestCase {
    // MARK: - Partial results

    func testPartialResultKeepsCommittedPrefixFinalAndRestInterim() {
        var transcript = DictationTranscriptState(baseDraft: "Review the")
        transcript.apply(cumulativeTranscript: "Review the deployment", isFinal: false)
        transcript.apply(cumulativeTranscript: "Review the deployment plan", isFinal: false)

        XCTAssertEqual(transcript.finalizedText, "")
        XCTAssertEqual(transcript.interimText, "Review the deployment plan")
        XCTAssertEqual(transcript.composedDraft, "Review the Review the deployment plan")
    }

    func testPartialResultAfterFinalExtendsCommittedText() {
        var transcript = DictationTranscriptState(baseDraft: "Review the")
        transcript.apply(cumulativeTranscript: "deployment plan", isFinal: true)
        transcript.apply(cumulativeTranscript: "deployment plan for tomorrow", isFinal: false)

        XCTAssertEqual(transcript.finalizedText, "deployment plan")
        XCTAssertEqual(transcript.interimText, " for tomorrow")
        XCTAssertEqual(transcript.composedDraft, "Review the deployment plan for tomorrow")
    }

    func testRevisedCumulativeTranscriptFallsBackToInterim() {
        var transcript = DictationTranscriptState(baseDraft: "")
        transcript.apply(cumulativeTranscript: "Shipping today", isFinal: true)
        transcript.apply(cumulativeTranscript: "Shipping to Data", isFinal: false)

        XCTAssertEqual(transcript.finalizedText, "")
        XCTAssertEqual(transcript.interimText, "Shipping to Data")
        XCTAssertEqual(transcript.composedDraft, "Shipping to Data")
    }

    func testPartialResultsShrinkingBelowCommittedTextFallBackToInterim() {
        var transcript = DictationTranscriptState(baseDraft: "Note:")
        transcript.apply(cumulativeTranscript: "standup moves to nine", isFinal: true)
        transcript.apply(cumulativeTranscript: "standup", isFinal: false)

        XCTAssertEqual(transcript.finalizedText, "")
        XCTAssertEqual(transcript.interimText, "standup")
        XCTAssertEqual(transcript.composedDraft, "Note: standup")
    }

    // MARK: - Final results

    func testFinalResultCommitsWholeTranscriptAndClearsInterim() {
        var transcript = DictationTranscriptState(baseDraft: "Review the")
        transcript.apply(cumulativeTranscript: "Review the deployment", isFinal: false)
        transcript.apply(cumulativeTranscript: "Review the deployment plan", isFinal: true)

        XCTAssertEqual(transcript.finalizedText, "Review the deployment plan")
        XCTAssertEqual(transcript.interimText, "")
        XCTAssertEqual(transcript.composedDraft, "Review the Review the deployment plan")
    }

    // MARK: - Draft composition

    func testComposedDraftTrimsTrailingWhitespaceFromBase() {
        var transcript = DictationTranscriptState(baseDraft: "Check CI   \n")
        transcript.apply(cumulativeTranscript: "now", isFinal: true)

        XCTAssertEqual(transcript.composedDraft, "Check CI now")
    }

    func testComposedDraftWithNothingSpokenKeepsBaseDraft() {
        let transcript = DictationTranscriptState(baseDraft: "Draft text")

        XCTAssertEqual(transcript.composedDraft, "Draft text")
    }

    func testComposedDraftFromEmptyBaseOmitsLeadingSpace() {
        var transcript = DictationTranscriptState(baseDraft: "")
        transcript.apply(cumulativeTranscript: "hello world", isFinal: true)

        XCTAssertEqual(transcript.composedDraft, "hello world")
    }

    func testWhitespaceOnlyInterimDoesNotInjectStraySpaces() {
        var transcript = DictationTranscriptState(baseDraft: "Ready")
        transcript.apply(cumulativeTranscript: "  ", isFinal: false)

        XCTAssertEqual(transcript.composedDraft, "Ready")
    }

    func testEmptyPartialResultOnEmptyBaseComposesEmptyDraft() {
        var transcript = DictationTranscriptState(baseDraft: "")
        transcript.apply(cumulativeTranscript: "", isFinal: false)

        XCTAssertEqual(transcript.composedDraft, "")
    }
}
