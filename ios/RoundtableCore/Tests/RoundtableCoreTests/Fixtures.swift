import Foundation

enum Fixtures {
    static let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    static let eventID = UUID(uuidString: "0F9A0000-0000-4000-8000-000000000002")!
    static let advocateID = UUID(uuidString: "D00D0000-0000-4000-8000-000000000003")!
    static let messageID = UUID(uuidString: "6F0E0000-0000-4000-8000-000000000004")!

    static let messageJSON = """
    {
      "id": "6F0E0000-0000-4000-8000-000000000004",
      "author": {
        "roundtable_agent_id": "D00D0000-0000-4000-8000-000000000003",
        "agent_key": "advocate",
        "name": "方案派"
      },
      "message_type": "proposal",
      "claim": "先用一个两周的验证性实验确认假设。",
      "body": "写清假设、指标和停止条件。",
      "stance": null,
      "references": [],
      "confidence": 0.72,
      "created_at": "2026-10-26T01:02:04.000Z"
    }
    """

    static let snapshotJSON = """
    {
      "id": "C0DEC0DE-0000-4000-8000-000000000001",
      "topic": "该不该把验证周期压缩到两周？",
      "status": "ready",
      "mode": "decision",
      "max_rounds": 2,
      "current_round": 0,
      "last_sequence": 0,
      "created_at": "2026-10-26T01:02:03.456Z",
      "updated_at": "2026-10-26T01:02:03.456Z",
      "participants": [
        {
          "id": "D00D0000-0000-4000-8000-000000000003",
          "position": 0,
          "state": "waiting",
          "agent": {
            "id": "11111111-1111-4111-8111-111111111111",
            "key": "advocate",
            "name": "方案派",
            "tagline": "先给出可执行的方案，再谈权衡。",
            "expertise": "方案设计与执行拆解",
            "goal": "提出清晰、可执行的方案和下一步行动。",
            "default_stance": "倾向推进，优先寻找可落地的路径。",
            "style": "直接、结构化，先结论后理由。",
            "banned_behaviors": ["空泛表态"],
            "max_reply_chars": 180
          }
        },
        {
          "id": "E00E0000-0000-4000-8000-000000000005",
          "position": 1,
          "state": "waiting",
          "agent": {
            "id": "22222222-2222-4222-8222-222222222222",
            "key": "skeptic",
            "name": "质疑派",
            "tagline": "先把方案里最脆弱的地方找出来。",
            "expertise": "风险识别",
            "goal": "指出风险与反例。",
            "default_stance": "倾向怀疑。",
            "style": "克制、追问式。",
            "banned_behaviors": ["人身攻击"],
            "max_reply_chars": 180
          }
        },
        {
          "id": "F00F0000-0000-4000-8000-000000000006",
          "position": 2,
          "state": "waiting",
          "agent": {
            "id": "33333333-3333-4333-8333-333333333333",
            "key": "experience",
            "name": "体验派",
            "tagline": "从用户感受评价方案。",
            "expertise": "用户旅程",
            "goal": "评价方案是否可用。",
            "default_stance": "倾向用户侧价值。",
            "style": "具体、场景化。",
            "banned_behaviors": ["替用户做决定"],
            "max_reply_chars": 180
          }
        }
      ]
    }
    """

    static func envelope(
        eventType: String,
        sequence: Int,
        payload: String,
        eventID: UUID = Fixtures.eventID
    ) -> Data {
        Data("""
        {
          "event_id": "\(eventID.uuidString)",
          "room_id": "\(roomID.uuidString)",
          "sequence": \(sequence),
          "created_at": "2026-10-26T01:02:03.456Z",
          "event_type": "\(eventType)",
          "payload": \(payload)
        }
        """.utf8)
    }

    static var joinedEnvelope: Data {
        envelope(
            eventType: "room.joined",
            sequence: 0,
            payload: "{\"roundtable\": \(snapshotJSON), \"messages\": []}"
        )
    }

    /// Snapshot returned once the roundtable was created with a provider (Issue #3).
    static var providerSnapshotJSON: String {
        snapshotJSON.replacingOccurrences(
            of: "\"mode\": \"decision\",",
            with: """
            "mode": "decision",
              "provider": {
                "kind": "deepseek",
                "base_url": "https://api.deepseek.com/v1",
                "model": "deepseek-chat"
              },
            """
        )
    }
}
