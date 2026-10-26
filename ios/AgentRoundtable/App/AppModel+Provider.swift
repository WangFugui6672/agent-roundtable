import Foundation
import Observation
import RoundtableCore

/// Provider lifecycle: availability, save/delete, connectivity check.
extension AppModel {
    // MARK: - Provider

    /// Whether the selected provider can be used, including the reason when it
    /// cannot (missing Keychain item, unreadable Keychain).
    var providerAvailability: ProviderAvailability {
        providerStore.availability(for: activeProvider)
    }

    /// Non-secret snapshot submitted with a new roundtable, or nil when no
    /// provider is configured (Mock demo still works).
    var providerMetadata: ProviderMetadata? {
        guard case let .ready(metadata) = providerAvailability else { return nil }
        return metadata
    }

    /// Non-nil when a provider is selected but unusable. Creating a roundtable
    /// must surface this instead of silently falling back to Mock.
    var providerIncompleteMessage: String? {
        guard case let .incomplete(message) = providerAvailability else { return nil }
        return message
    }

    var providerSummary: String {
        switch providerAvailability {
        case .none:
            return "未配置 Provider，将使用 Mock 演示"
        case let .ready(metadata):
            return "\(metadata.kind.displayName) · \(metadata.model)"
        case .incomplete:
            return "Provider 配置不完整，请重新输入 API Key"
        }
    }

    var hasConfiguredProvider: Bool {
        providerMetadata != nil
    }

    func providerConfiguration(for kind: ProviderKind) -> ProviderConfiguration? {
        providerStore.configuration(for: kind)
    }

    func isProviderConfigured(_ kind: ProviderKind) -> Bool {
        providerStore.isConfigured(kind)
    }

    /// Saves the provider. An empty key field keeps the Keychain item that is
    /// already stored, so users can change BaseURL/Model without re-entering it —
    /// unless the BaseURL host changed, in which case the old key must not be
    /// reused (it may belong to a different service).
    @discardableResult
    func saveProvider(_ draft: ProviderDraft) -> Bool {
        isSavingProvider = true
        defer { isSavingProvider = false }
        providerError = nil
        providerCheckMessage = nil

        do {
            try providerStore.save(resolved(draft))
            setActiveProvider(draft.kind)
            return true
        } catch {
            providerError = Self.userMessage(for: error)
            return false
        }
    }

    /// Verifies BaseURL, key and model against the provider's `GET /models`
    /// endpoint. Failures produce a readable message instead of silently
    /// swapping models (PRD 7.13).
    func checkProvider(_ draft: ProviderDraft) async {
        isCheckingProvider = true
        providerError = nil
        providerCheckMessage = nil
        defer { isCheckingProvider = false }

        do {
            let (configuration, key) = try resolved(draft).validated()
            let outcome = await probe.check(configuration: configuration, apiKey: key)
            providerCheckMessage = outcome.message
        } catch {
            providerError = Self.userMessage(for: error)
        }
    }

    /// Fills an empty key field from the Keychain, but only while the BaseURL is
    /// unchanged: editing the address must not forward the old key to a new host.
    private func resolved(_ draft: ProviderDraft) -> ProviderDraft {
        guard draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return draft
        }
        let storedConfiguration = providerStore.configuration(for: draft.kind)
        let sameBaseURL = storedConfiguration.map {
            $0.baseURL == ProviderURL.normalized(baseURL: draft.baseURL)
        } ?? false
        guard sameBaseURL,
              let stored = try? providerStore.secret(for: draft.kind),
              !stored.isEmpty
        else { return draft }

        var resolved = draft
        resolved.apiKey = stored
        return resolved
    }

    @discardableResult
    func deleteProvider(_ kind: ProviderKind) -> Bool {
        providerError = nil
        providerCheckMessage = nil
        do {
            try providerStore.delete(kind)
            if activeProvider == kind {
                setActiveProvider(nil)
            }
            providerCheckMessage = "已删除该 Provider 及其 Keychain 中的 API Key。"
            return true
        } catch {
            providerError = Self.userMessage(for: error)
            return false
        }
    }

    /// Configuration for the active provider, but only when its Keychain item
    /// is still readable. Keeps the turn logic from reaching into the store.
    var activeConfiguration: ProviderConfiguration? {
        guard case let .ready(metadata) = providerAvailability else { return nil }
        return providerStore.configuration(for: metadata.kind)
    }

    func clearProviderFeedback() {
        providerError = nil
        providerCheckMessage = nil
    }

    func setActiveProvider(_ kind: ProviderKind?) {
        activeProvider = kind
        if let kind {
            defaults.set(kind.rawValue, forKey: Self.activeProviderKey)
        } else {
            defaults.removeObject(forKey: Self.activeProviderKey)
        }
    }
}
