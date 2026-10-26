import XCTest

@testable import RoundtableCore

private struct FailureCase {
    let error: ProviderError
    let code: String
    let retryable: Bool
}

final class ProviderErrorClassificationTests: XCTestCase {
    func testProviderFailureCodesAndRetryabilityAreStable() {
        let cases = [
            FailureCase(
                error: .http(status: 401, detail: ""),
                code: "provider_unauthorized",
                retryable: false
            ),
            FailureCase(
                error: .http(status: 403, detail: ""),
                code: "provider_unauthorized",
                retryable: false
            ),
            FailureCase(
                error: .http(status: 402, detail: ""),
                code: "provider_insufficient_balance",
                retryable: false
            ),
            FailureCase(
                error: .http(status: 404, detail: ""),
                code: "provider_model_not_found",
                retryable: false
            ),
            FailureCase(
                error: .http(status: 429, detail: ""),
                code: "provider_rate_limited",
                retryable: true
            ),
            FailureCase(
                error: .http(status: 500, detail: ""),
                code: "provider_server_error",
                retryable: true
            ),
            FailureCase(
                error: .emptyReply,
                code: "provider_empty_reply",
                retryable: true
            ),
            FailureCase(
                error: .invalidResponse("bad"),
                code: "provider_invalid_response",
                retryable: true
            ),
            FailureCase(
                error: .timeout,
                code: "provider_timeout",
                retryable: true
            ),
            FailureCase(
                error: .transport("offline"),
                code: "provider_network",
                retryable: true
            )
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.error.failureCode, testCase.code)
            XCTAssertEqual(testCase.error.retryable, testCase.retryable)
        }
    }
}
