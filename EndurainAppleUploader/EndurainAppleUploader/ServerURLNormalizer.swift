//
//  ServerURLNormalizer.swift
//  EndurainAppleUploader
//

import Foundation
import CryptoKit

enum ServerURLNormalizer {
    enum NormalizationError: Error, LocalizedError, Equatable {
        case empty
        case invalidURL
        case unsupportedScheme

        var errorDescription: String? {
            switch self {
            case .empty:
                return "La URL del servidor no puede estar vacía."
            case .invalidURL:
                return "La URL del servidor no es válida."
            case .unsupportedScheme:
                return "La URL debe usar http:// o https://."
            }
        }
    }

    static func normalize(_ rawValue: String) throws -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NormalizationError.empty }

        if !value.contains("://") {
            value = "https://" + value
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw NormalizationError.invalidURL
        }

        guard scheme == "http" || scheme == "https" else {
            throw NormalizationError.unsupportedScheme
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        normalized.path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalized.path.isEmpty {
            normalized.path = "/" + normalized.path
        }

        guard var output = normalized.url?.absoluteString else {
            throw NormalizationError.invalidURL
        }
        while output.hasSuffix("/") {
            output.removeLast()
        }
        return output
    }
}

enum UserIdentityNormalizer {
    enum NormalizationError: Error, LocalizedError, Equatable {
        case empty

        var errorDescription: String? {
            "El usuario de Endurain no puede estar vacío."
        }
    }

    static func normalize(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { throw NormalizationError.empty }
        return value
    }
}

struct EndurainConfigurationIdentity: Equatable {
    let normalizedServerURL: String
    let normalizedUserIdentifier: String
    let namespaceID: String

    init(serverURL: String, userIdentifier: String) throws {
        let normalizedServerURL = try ServerURLNormalizer.normalize(serverURL)
        let normalizedUserIdentifier = try UserIdentityNormalizer.normalize(userIdentifier)
        self.normalizedServerURL = normalizedServerURL
        self.normalizedUserIdentifier = normalizedUserIdentifier
        self.namespaceID = Self.namespaceID(
            normalizedServerURL: normalizedServerURL,
            normalizedUserIdentifier: normalizedUserIdentifier
        )
    }

    static func namespaceID(normalizedServerURL: String, normalizedUserIdentifier: String) -> String {
        let input = normalizedServerURL + "\n" + normalizedUserIdentifier
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
