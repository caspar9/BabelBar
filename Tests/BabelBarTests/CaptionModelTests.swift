import XCTest
@testable import BabelBar

@MainActor
final class CaptionModelTests: XCTestCase {
    private var model: CaptionModel!

    override func setUp() async throws {
        model = CaptionModel()
        model.expectsTranslation = true
    }

    private func original(_ text: String, speaker: String? = nil) -> TranscriptToken {
        TranscriptToken(text: text, isFinal: true, language: "en", speaker: speaker, kind: .original)
    }

    private func translation(_ text: String) -> TranscriptToken {
        TranscriptToken(text: text, isFinal: true, language: "zh", speaker: nil, kind: .translation)
    }

    private var nonEmpty: [CaptionSegment] {
        model.segments.filter { !$0.isEmpty }
    }

    // MARK: Sentence pairing

    func testTranslationPairsWithItsOriginalSentence() {
        model.apply(.final([original("Hello world.")]))
        model.apply(.final([translation("你好世界。")]))

        XCTAssertEqual(nonEmpty.count, 1)
        XCTAssertEqual(nonEmpty[0].originalFinal, "Hello world.")
        XCTAssertEqual(nonEmpty[0].translationFinal, "你好世界。")
        XCTAssertTrue(nonEmpty[0].isClosed)
    }

    func testSecondSentenceOpensNewBlockWhileTranslationLags() {
        // First sentence completes, translation hasn't arrived yet.
        model.apply(.final([original("First sentence.")]))
        // Original of the second sentence starts before translation of the first.
        model.apply(.final([original(" Second")]))
        // Translation for the first sentence arrives late.
        model.apply(.final([translation("第一句。")]))
        model.apply(.final([original(" sentence.")]))
        model.apply(.final([translation("第二句。")]))

        XCTAssertEqual(nonEmpty.count, 2)
        XCTAssertEqual(nonEmpty[0].originalFinal, "First sentence.")
        XCTAssertEqual(nonEmpty[0].translationFinal, "第一句。")
        XCTAssertEqual(nonEmpty[1].originalFinal, " Second sentence.")
        XCTAssertEqual(nonEmpty[1].translationFinal, "第二句。")
    }

    func testWithoutTranslationBlocksCloseOnSentenceEnd() {
        model.expectsTranslation = false
        model.apply(.final([original("Done.")]))

        XCTAssertEqual(nonEmpty.count, 1)
        XCTAssertTrue(nonEmpty[0].isClosed)
    }

    // MARK: Endpoint handling

    func testTranslationAfterUtteranceEndLandsInSealedBlock() {
        // Utterance ends before its translation arrives.
        model.apply(.final([original("No punctuation here")]))
        model.apply(.utteranceEnd)
        // The block is sealed (no more original text) but still open.
        model.apply(.final([translation("这里没有标点。")]))

        XCTAssertEqual(nonEmpty.count, 1, "translation must not create an orphan block")
        XCTAssertEqual(nonEmpty[0].originalFinal, "No punctuation here")
        XCTAssertEqual(nonEmpty[0].translationFinal, "这里没有标点。")
        XCTAssertTrue(nonEmpty[0].isClosed)
    }

    func testSealedBlockTakesNoMoreOriginalText() {
        model.apply(.final([original("Utterance one")]))
        model.apply(.utteranceEnd)
        model.apply(.final([original("Utterance two")]))

        XCTAssertEqual(nonEmpty.count, 2)
        XCTAssertEqual(nonEmpty[0].originalFinal, "Utterance one")
        XCTAssertEqual(nonEmpty[1].originalFinal, "Utterance two")
    }

    func testSecondEndpointForceClosesStragglers() {
        // Translation never arrives for utterance one.
        model.apply(.final([original("Utterance one")]))
        model.apply(.utteranceEnd)
        model.apply(.final([original("Utterance two")]))
        model.apply(.utteranceEnd)

        XCTAssertTrue(nonEmpty[0].isClosed, "unclosed block must not survive two endpoints")
        XCTAssertTrue(nonEmpty[1].originalSealed)
    }

    // MARK: Partials

    func testPartialsAreReplacedWholesale() {
        model.apply(.partial([TranscriptToken(
            text: "Hel", isFinal: false, language: "en", speaker: nil, kind: .original
        )]))
        XCTAssertEqual(model.segments[model.liveIndex].originalPartial, "Hel")

        model.apply(.partial([TranscriptToken(
            text: "Hello wor", isFinal: false, language: "en", speaker: nil, kind: .original
        )]))
        XCTAssertEqual(model.segments[model.liveIndex].originalPartial, "Hello wor")
    }

    func testReconnectClearsPartials() {
        model.apply(.partial([TranscriptToken(
            text: "doomed", isFinal: false, language: "en", speaker: nil, kind: .original
        )]))
        model.apply(.reconnecting(attempt: 1))
        XCTAssertTrue(model.segments.allSatisfy { $0.originalPartial.isEmpty })
    }

    func testFinishedClosesEverything() {
        model.apply(.final([original("Trailing text")]))
        model.apply(.finished)
        XCTAssertTrue(nonEmpty.allSatisfy(\.isClosed))
    }

    // MARK: Speaker

    func testSpeakerChangeStartsNewBlock() {
        model.apply(.final([original("Speaker one talks.", speaker: "1")]))
        model.apply(.final([translation("说话人一。")]))
        model.apply(.speakerChange("2"))
        model.apply(.final([original("Speaker two talks.", speaker: "2")]))

        XCTAssertEqual(nonEmpty[0].speaker, "1")
        XCTAssertEqual(nonEmpty[1].speaker, "2")
    }

    // MARK: History bounds

    func testHistoryIsTrimmedButOpenBlocksSurvive() {
        for i in 0..<80 {
            model.apply(.final([original("Sentence \(i).")]))
            model.apply(.final([translation("句子\(i)。")]))
        }
        XCTAssertLessThanOrEqual(model.segments.count, 51)  // maxSegments + live block
        // The newest closed block is intact.
        XCTAssertEqual(nonEmpty.last?.originalFinal, "Sentence 79.")
    }

    // MARK: Sentence detection

    func testEndsSentence() {
        XCTAssertTrue(CaptionModel.endsSentence("Hello."))
        XCTAssertTrue(CaptionModel.endsSentence("你好。"))
        XCTAssertTrue(CaptionModel.endsSentence("Really?!"))
        XCTAssertTrue(CaptionModel.endsSentence("\"Quoted.\""))
        XCTAssertTrue(CaptionModel.endsSentence("(Parenthetical.)"))
        XCTAssertTrue(CaptionModel.endsSentence("Trailing space. "))
        XCTAssertFalse(CaptionModel.endsSentence("No terminal"))
        XCTAssertFalse(CaptionModel.endsSentence("Comma,"))
        XCTAssertFalse(CaptionModel.endsSentence(""))
    }
}
