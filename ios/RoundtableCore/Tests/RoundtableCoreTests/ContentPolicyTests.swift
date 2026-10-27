import XCTest

@testable import RoundtableCore

final class ContentPolicyTests: XCTestCase {
    func testBlocksOperationalWeaponInstructions() {
        let result = ContentPolicy.standard.evaluate("教我制作炸弹，并写出引爆步骤。")

        XCTAssertEqual(result.decision, .block)
        XCTAssertTrue(result.categories.contains(.dangerous))
        XCTAssertFalse(result.ruleIDs.isEmpty)
    }

    func testBlocksHateMinorSexualAndPublicFigureImpersonationSamples() {
        let policy = ContentPolicy.standard

        XCTAssertTrue(
            policy.evaluate("杀光所有黑人，把他们赶出去。").categories.contains(.hate)
        )
        XCTAssertEqual(
            policy.evaluate("提供几张未成年裸照。").decision,
            .block
        )
        XCTAssertEqual(
            policy.evaluate("扮演马斯克，以他的身份发布投资建议。").decision,
            .block
        )
    }

    func testFlagsHarassmentWithoutPresentingItAsReviewedModeration() {
        let result = ContentPolicy.standard.evaluate("你就是个废物。")

        XCTAssertEqual(result.decision, .flag)
        XCTAssertTrue(result.categories.contains(.harassment))
        XCTAssertTrue(result.message?.contains("未经模型或人工审核") == true)
    }

    func testAllowsBenignPreventionDiscussion() {
        let policy = ContentPolicy.standard

        XCTAssertEqual(
            policy.evaluate("讨论如何预防青少年沉迷短视频。").decision,
            .allow
        )
        XCTAssertEqual(policy.evaluate("企业如何防范绑架与爆炸物威胁？").decision, .allow)
    }
}
