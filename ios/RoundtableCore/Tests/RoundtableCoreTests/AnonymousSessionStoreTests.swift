import Foundation
import XCTest

@testable import RoundtableCore

final class AnonymousSessionStoreTests: XCTestCase {
    func testRotationFailureKeepsPreviousSessionAvailable() throws {
        let secrets = RotatingSecretStore()
        let store = AnonymousSessionStore(secrets: secrets)
        let old = UUID()
        let replacement = UUID()
        try store.save(old)
        secrets.failNextWrite = true

        XCTAssertThrowsError(try store.rotate(to: replacement))
        XCTAssertEqual(try store.load(), old)
    }
}

private final class RotatingSecretStore: SecretStore {
    var values: [String: String] = [:]
    var failNextWrite = false

    func secret(for account: String) throws -> String? {
        values[account]
    }

    func setSecret(_ secret: String, for account: String) throws {
        if failNextWrite {
            failNextWrite = false
            throw KeychainError(status: -1)
        }
        values[account] = secret
    }

    func removeSecret(for account: String) throws {
        values[account] = nil
    }
}
