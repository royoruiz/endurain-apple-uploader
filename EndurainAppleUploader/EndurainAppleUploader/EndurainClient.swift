//
//  EndurainClient.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation

// MARK: - Errors

enum EndurainClientError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case networkError(Error)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "La URL del servidor no es válida."
        case .unauthorized:
            return "API Key inválida o sin permisos (401)."
        case .serverError(let code):
            return "Error del servidor: \(code)."
        case .networkError(let error):
            return "Error de red: \(error.localizedDescription)"
        case .unexpectedResponse:
            return "Respuesta inesperada del servidor."
        }
    }
}

// MARK: - Client

struct EndurainClient {

    // Endpoint fácil de cambiar si /user/me no funciona con la API key
    private static let testConnectionPath = "/api/v1/user/me"

    private let serverURL: String
    private let apiKey: String

    init(serverURL: String, apiKey: String) {
        self.serverURL = serverURL
        self.apiKey = apiKey
    }

    // MARK: - Test connection

    /// Realiza GET a {serverURL}/api/v1/user/me con Authorization: Bearer <apiKey>.
    /// Devuelve true si la respuesta es 2xx, lanza EndurainClientError en cualquier otro caso.
    func testConnection() async throws -> Bool {
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines) + Self.testConnectionPath
        guard let url = URL(string: urlString) else {
            throw EndurainClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        switch http.statusCode {
        case 200...299:
            return true
        case 401, 403:
            throw EndurainClientError.unauthorized
        default:
            throw EndurainClientError.serverError(http.statusCode)
        }
    }
}
