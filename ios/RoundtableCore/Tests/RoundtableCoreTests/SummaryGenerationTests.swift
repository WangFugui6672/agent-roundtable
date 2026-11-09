import Foundation
import XCTest

@testable import RoundtableCore

final class SummaryGenerationTests: XCTestCase {
    func testStructuredSummaryMapsCandidateIndexesToExistingMessageIDs() throws {
        let transcript = try transcriptMessages()
        let output = """
        {
          "consensus": [
            {"text": "先完成可验证的小实验。", "reference_indexes": [0]}
          ],
          "dissent": [
            {"text": "验证成本可能被低估。", "reference_indexes": [1]}
          ],
          "recommendations": [],
          "unresolved": []
        }
        """

        let draft = try StructuredSummaryParser.parse(output, transcript: transcript)

        XCTAssertFalse(draft.degraded)
        XCTAssertEqual(draft.consensus, [
            SummaryItem(
                text: "先完成可验证的小实验。",
                referenceMessageIds: [Fixtures.messageID]
            )
        ])
        XCTAssertEqual(draft.dissent[0].referenceMessageIds, [transcript[1].id])
    }

    func testStructuredSummaryRejectsAnIndexOutsideTheDiscussion() throws {
        let output = """
        {
          "consensus": [{"text": "没有依据的结论。", "reference_indexes": [99]}],
          "dissent": [],
          "recommendations": [],
          "unresolved": []
        }
        """

        XCTAssertThrowsError(
            try StructuredSummaryParser.parse(output, transcript: transcriptMessages())
        ) { error in
            XCTAssertEqual(error as? StructuredSummaryError, .invalidReference)
        }
    }

    func testStructuredSummaryTruncatesExtraReferencesInsteadOfFailing() throws {
        let base = try transcriptMessages()
        let messages = (0 ..< 4).map { index in
            Message(
                id: UUID(uuidString: "6F0E0000-0000-4000-8000-00000000001\(index)")!,
                roundNumber: 1,
                author: base[0].author,
                messageType: .proposal,
                claim: "第 \(index) 条主张。",
                body: "第 \(index) 条正文。",
                stance: .support,
                references: [],
                createdAt: base[0].createdAt
            )
        }
        let output = """
        {
          "consensus": [{"text": "多给了引用。", "reference_indexes": [0, 1, 2, 3]}],
          "dissent": [],
          "recommendations": [],
          "unresolved": []
        }
        """

        let draft = try StructuredSummaryParser.parse(output, transcript: messages)

        XCTAssertEqual(
            draft.consensus[0].referenceMessageIds,
            messages.prefix(3).map { $0.id }
        )
    }

    func testStructuredSummaryRejectsUnknownFields() throws {
        let output = """
        {
          "consensus": [
            {
              "text": "先完成可验证的小实验。",
              "reference_indexes": [0],
              "source_url": "https://example.com"
            }
          ],
          "dissent": [],
          "recommendations": [],
          "unresolved": []
        }
        """

        XCTAssertThrowsError(
            try StructuredSummaryParser.parse(output, transcript: transcriptMessages())
        ) { error in
            XCTAssertEqual(error as? StructuredSummaryError, .invalidJSON)
        }
    }

    func testRuleBasedFallbackIsMarkedDegradedAndOnlyCitesExistingClaims() throws {
        let transcript = try transcriptMessages()

        let draft = RuleBasedSummary.make(transcript: transcript)

        XCTAssertTrue(draft.degraded)
        XCTAssertEqual(draft.recommendations[0].referenceMessageIds, [Fixtures.messageID])
        XCTAssertEqual(draft.dissent[0].referenceMessageIds, [transcript[1].id])
        let referenced = Set(
            (draft.consensus + draft.dissent + draft.recommendations + draft.unresolved)
                .flatMap(\.referenceMessageIds)
        )
        XCTAssertTrue(referenced.isSubset(of: Set(transcript.map(\.id))))
    }

    private func transcriptMessages() throws -> [Message] {
        let first = try JSONDecoder.roundtable.decode(
            Message.self,
            from: Data(Fixtures.messageJSON.utf8)
        )
        let second = Message(
            id: UUID(uuidString: "6F0E0000-0000-4000-8000-000000000005")!,
            roundNumber: 2,
            author: MessageAuthor(
                roundtableAgentId: UUID(uuidString: "E00E0000-0000-4000-8000-000000000005")!,
                agentKey: "skeptic",
                name: "质疑派"
            ),
            messageType: .challenge,
            claim: "验证成本可能被低估。",
            body: "团队注意力也会成为成本。",
            stance: .challenge,
            references: [first.id],
            createdAt: Date(timeIntervalSince1970: 1_792_976_524)
        )
        return [first, second]
    }
}
