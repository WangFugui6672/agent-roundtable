import Foundation
import XCTest

@testable import RoundtableCore

private actor ProbeTransport: HTTPTransport {
    private let result: Result<HTTPResponse, Error>
    private(set) var requests: [URLRequest] = []

    init(result: Result<HTTPResponse, Error>) {
        self.result = result
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try result.get()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

final class ProviderProbeTests: XCTestCase {
    private let configuration = ProviderConfiguration(
        kind: .deepseek,
        baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat"
    )

    private func probe(_ result: Result<HTTPResponse, Error>) -> (ProviderProbe, ProbeTransport) {
        let transport = ProbeTransport(result: result)
        return (ProviderProbe(transport: transport), transport)
    }

    func testSuccessfulProbeReportsModelCount() async throws {
        let body = #"{"object":"list","data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#
        let (probe, transport) = probe(.success(.init(data: Data(body.utf8), statusCode: 200)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        XCTAssertEqual(outcome, .ok(modelCount: 2))
        XCTAssertTrue(outcome.message.contains("连接成功"))

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSuccessfulProbeWithoutModelListStillSucceeds() async {
        let (probe, _) = probe(.success(.init(data: Data("{}".utf8), statusCode: 200)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        XCTAssertEqual(outcome, .ok(modelCount: nil))
    }

    func testModelMissingFromProviderListIsReported() async {
        let body = #"{"data":[{"id":"some-other-model"}]}"#
        let (probe, _) = probe(.success(.init(data: Data(body.utf8), statusCode: 200)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        XCTAssertEqual(outcome, .modelMissing("deepseek-chat"))
        XCTAssertTrue(outcome.message.contains("deepseek-chat"))
        XCTAssertTrue(outcome.message.contains("不在"))
    }

    func testUnauthorizedKeyIsReported() async {
        for status in [401, 403] {
            let (probe, _) = probe(.success(.init(data: Data(), statusCode: status)))

            let outcome = await probe.check(configuration: configuration, apiKey: "sk-bad")

            XCTAssertEqual(outcome, .invalidKey, "status \(status)")
            XCTAssertTrue(outcome.message.contains("API Key"))
        }
    }

    func testNotFoundHintsAtBaseURL() async {
        let (probe, _) = probe(.success(.init(data: Data(), statusCode: 404)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        XCTAssertTrue(outcome.message.contains("BaseURL"))
    }

    func testBillingAndRateLimitHaveSpecificMessages() async {
        for (status, keyword) in [(402, "余额"), (429, "频繁")] {
            let (probe, _) = probe(.success(.init(data: Data(), statusCode: status)))

            let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

            XCTAssertTrue(outcome.message.contains(keyword), "status \(status): \(outcome.message)")
        }
    }

    func testServerErrorIsReportedWithStatus() async {
        let (probe, _) = probe(.success(.init(data: Data(), statusCode: 500)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        XCTAssertTrue(outcome.message.contains("500"))
    }

    func testNetworkFailureIsReportedAsUnreachable() async {
        let (probe, _) = probe(.failure(URLError(.cannotConnectToHost)))

        let outcome = await probe.check(configuration: configuration, apiKey: "sk-test")

        guard case .unreachable = outcome else {
            return XCTFail("expected unreachable, got \(outcome)")
        }
        XCTAssertTrue(outcome.message.contains("网络"))
    }

    func testBaseURLTrailingSlashDoesNotDuplicateSeparator() {
        let withSlash = ProviderURL.modelsEndpoint(baseURL: "https://example.com/v1/")

        XCTAssertEqual(withSlash?.absoluteString, "https://example.com/v1/models")
    }
}
