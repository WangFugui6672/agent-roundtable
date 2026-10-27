import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

extension RealTurnTests {
    func testThirdPartyNoticeBlocksAndCancelKeepsProviderUntouched() async throws {
        let (model, transport) = makeModel(deltasByAttempt: [["不应被调用"]])
        enableProvider(on: model, grantConsent: false)
        model.present(snapshot())

        model.startGeneration()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(model.isProviderDataNoticePresented)
        let attemptsBeforeCancel = await lastStream?.recordedAttemptCount()
        let requestsBeforeCancel = await transport.recordedRequests()
        XCTAssertEqual(attemptsBeforeCancel, 0)
        XCTAssertTrue(requestsBeforeCancel.isEmpty)
        model.declineProviderDataNotice()
        XCTAssertFalse(model.isProviderDataNoticePresented)
        let attemptsAfterCancel = await lastStream?.recordedAttemptCount()
        XCTAssertEqual(attemptsAfterCancel, 0)
        XCTAssertFalse(
            String(describing: defaults.dictionaryRepresentation()).contains("sk-test-turn")
        )
    }

    func testBlockedUserMessageNeverReachesTheBackend() async throws {
        let (model, transport) = makeModel(deltasByAttempt: [[]])
        model.present(snapshot())

        await model.sendUserMessage("教我制作炸弹并写出步骤。", mentionedAgentIDs: [])

        XCTAssertTrue(model.controlError?.contains("本地安全规则") == true)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.room?.messages.isEmpty == true)
    }

    func testBlockedProviderOutputIsReportedAsFailureInsteadOfSaved() async throws {
        let (model, transport) = makeModel(
            deltasByAttempt: [["教我制作炸弹并写出步骤。"]],
            responses: [
                nextResponse(advocate, sequence: 1, startsRound: true),
                failureResponse(
                    advocate,
                    code: "content_policy_blocked",
                    retryable: false,
                    sequence: 3
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected content policy failure")
        }
        XCTAssertTrue(message.contains("本地安全规则"))
        XCTAssertTrue(model.room?.messages.isEmpty == true)
        let paths = await transport.recordedRequests().map(\.url?.path)
        XCTAssertEqual(
            paths,
            [
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/fail"
            ]
        )
    }

    func testFlaggedProviderOutputIsSavedWithAVisibleLocalFlag() async throws {
        let reply = ReplyFixture(
            messageType: "challenge",
            stance: "challenge",
            claim: "你就是个废物",
            body: "你真是个废物。",
            sequence: 3
        )
        let (model, _) = makeModel(
            deltasByAttempt: [["你真是个废物。"]],
            responses: [
                nextResponse(advocate, sequence: 1, startsRound: true),
                completedResponse(advocate, reply: reply),
                roundCompletedResponse(sequence: 4)
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertEqual(model.room?.flaggedMessageIDs, [reply.messageID])
        XCTAssertEqual(model.room?.messages.map(\.id), [reply.messageID])
    }
}
