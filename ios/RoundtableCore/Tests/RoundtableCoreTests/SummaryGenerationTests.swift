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
