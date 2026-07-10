//
//  SettingsStore.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import Observation

@Observable
final class SettingsStore {

    // MARK: - Published state

    private(set) var serverURL: String = ""
    private(set) var isConfigured: Bool = false

    // MARK: - Private

    private let defaults: UserDefaults
    private let keychain: KeychainService

    private enum Keys {
        static let serverURL = "endurain_server_url"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
        load()
    }

    // MARK: - Load

    private func load() {
        let url = defaults.string(forKey: Keys.serverURL) ?? ""
        serverURL = url
        isConfigured = !url.isEmpty
    }

    // MARK: - Save

    func save(serverURL: String, apiKey: String) throws {
        let normalizedURL = try ServerURLNormalizer.normalize(serverURL)
        defaults.set(normalizedURL, forKey: Keys.serverURL)
        try keychain.save(apiKey)
        self.serverURL = normalizedURL
        self.isConfigured = true
    }

    // MARK: - Clear

    func clear() throws {
        defaults.removeObject(forKey: Keys.serverURL)
        try keychain.delete()
        serverURL = ""
        isConfigured = false
    }

    // MARK: - Read API Key (for use in client)

    func readAPIKey() throws -> String? {
        try keychain.read()
    }
}
