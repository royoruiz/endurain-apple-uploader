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
    private(set) var userIdentifier: String = ""
    private(set) var isConfigured: Bool = false

    // MARK: - Private

    private let defaults: UserDefaults
    private let keychain: KeychainService

    private enum Keys {
        static let serverURL = "endurain_server_url"
        static let userIdentifier = "endurain_user_identifier"
    }

    enum ConfigurationKey {
        static let serverURL = Keys.serverURL
        static let userIdentifier = Keys.userIdentifier
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
        let user = defaults.string(forKey: Keys.userIdentifier) ?? ""
        serverURL = url
        userIdentifier = user
        isConfigured = !url.isEmpty && !user.isEmpty
    }

    // MARK: - Save

    func save(serverURL: String, userIdentifier: String, apiKey: String) throws {
        let identity = try EndurainConfigurationIdentity(serverURL: serverURL, userIdentifier: userIdentifier)
        defaults.set(identity.normalizedServerURL, forKey: Keys.serverURL)
        defaults.set(identity.normalizedUserIdentifier, forKey: Keys.userIdentifier)
        try keychain.save(apiKey)
        self.serverURL = identity.normalizedServerURL
        self.userIdentifier = identity.normalizedUserIdentifier
        self.isConfigured = true
    }

    // MARK: - Clear

    func clearConfigurationOnly() throws {
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.userIdentifier)
        try keychain.delete()
        serverURL = ""
        userIdentifier = ""
        isConfigured = false
    }

    func currentIdentity() throws -> EndurainConfigurationIdentity {
        try EndurainConfigurationIdentity(serverURL: serverURL, userIdentifier: userIdentifier)
    }

    func reload() {
        load()
    }

    // MARK: - Read API Key (for use in client)

    func readAPIKey() throws -> String? {
        try keychain.read()
    }
}
