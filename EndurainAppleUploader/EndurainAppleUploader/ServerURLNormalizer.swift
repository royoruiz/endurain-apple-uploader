//
//  ServerURLNormalizer.swift
//  EndurainAppleUploader
//

import Foundation

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
