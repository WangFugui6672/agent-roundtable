import Foundation
import RoundtableCore

@testable import AgentRoundtable

extension RealTurnTests {
    func summaryResponse(
        sequence: Int,
        referenceMessageID: UUID,
        degraded: Bool = false,
        version: Int = 1
    ) -> HTTPResponse {
        let summary = summaryFixture(
            referenceMessageID: referenceMessageID,
            degraded: degraded,
            version: version
        )
        let wire = roundtableWire(status: "completed", lastSequence: sequence)
        return jsonResponse(
            [
                "roundtable": wire,
                "summary": summary,
                "events": [
                    event(
                        "summary.completed",
                        sequence: sequence,
                        payload: ["summary": summary]
                    )
                ]
            ],
            statusCode: 201
        )
    }

    private func summaryFixture(
        referenceMessageID: UUID,
        degraded: Bool,
        version: Int
    ) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "version": version,
            "degraded": degraded,
            "consensus": [
                [
                    "text": "先完成可验证的小实验。",
                    "reference_message_ids": [referenceMessageID.uuidString]
                ]
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
            "created_at": "2026-10-26T01:05:03.456Z",
            "updated_at": "2026-10-26T01:05:03.456Z"
        ]
    }

    private func roundtableWire(status: String, lastSequence: Int) -> [String: Any] {
        [
            "id": roomID.uuidString,
            "topic": "该不该把验证周期压缩到两周？",
            "status": status,
            "mode": "decision",
            "max_rounds": 2,
            "current_round": 2,
            "last_sequence": lastSequence,
            "created_at": "2026-10-26T01:02:03.456Z",
            "updated_at": "2026-10-26T01:05:03.456Z",
            "participants": [advocate, skeptic, experience].map { turn in
                [
                    "id": turn.agentID.uuidString,
                    "position": turn.position,
                    "state": "completed",
                    "agent": [
                        "id": UUID().uuidString,
                        "key": turn.key,
                        "name": turn.name,
                        "tagline": "定位",
                        "expertise": "专长",
                        "goal": "目标",
                        "default_stance": "默认立场",
                        "style": "直接",
                        "banned_behaviors": [],
                        "max_reply_chars": 180
                    ]
                ]
            }
        ]
    }
}
