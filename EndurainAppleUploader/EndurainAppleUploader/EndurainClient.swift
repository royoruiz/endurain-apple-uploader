//
//  EndurainClient.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import os

// MARK: - Upload result

struct UploadResult {
    let statusCode: Int
    let responseBody: String
}

// MARK: - Errors

enum EndurainClientError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int, String)
    case rateLimited(String)
    case duplicate(String)
    case networkError(Error)
    case unexpectedResponse
    /// Error específico de subida: incluye status code y body resumido
    case uploadError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "La URL del servidor no es válida."
        case .unauthorized:
            return "API key is not authorized for activity upload or is invalid."
        case .serverError(let code, let body):
            let summary = body.isEmpty ? "(sin body)" : body
            return "Error del servidor [\(code)]: \(summary)"
        case .rateLimited(let body):
            let summary = body.isEmpty ? "Too many requests. Please try again later." : body
            return "Demasiadas peticiones: \(summary)"
        case .duplicate(let body):
            let summary = body.isEmpty ? "este entrenamiento ya existe en Endurain." : body
            return "Duplicado: \(summary)"
        case .networkError(let error):
            return "Error de red: \(error.localizedDescription)"
        case .unexpectedResponse:
            return "Respuesta inesperada del servidor."
        case .uploadError(let code, let body):
            let summary = body.isEmpty ? "(sin body)" : body
            return "Error al subir [\(code)]: \(summary)"
        }
    }
}

// MARK: - Client

struct EndurainClient {

    // Endpoint de subida de actividades
    private static let uploadActivityPath = "/api/v1/activities/create/upload"

    private let serverURL: String
    private let apiKey: String
    private let session: URLSession

    init(serverURL: String, apiKey: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Test connection

    /// Basic connectivity check against the configured base URL. No API key is sent.
    func testConnection() async throws -> Bool {
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            throw EndurainClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            AppLog.upload.error("Connection test failed: \(error.localizedDescription, privacy: .private)")
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        return (200...499).contains(http.statusCode)
    }

    // MARK: - Upload activity TCX

    /// POST {serverURL}/api/v1/activities/create/upload
    /// Autenticación: X-API-Key header.
    /// Body: multipart/form-data con el fichero TCX en el campo "file".
    func uploadActivityTCX(tcxData: Data, filename: String) async throws -> UploadResult {
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines) + Self.uploadActivityPath
        guard let url = URL(string: urlString) else {
            throw EndurainClientError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = MultipartFormBuilder.body(tcxData: tcxData, filename: filename, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 60
        request.httpBody = body

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            AppLog.upload.error("Foreground upload failed: \(error.localizedDescription, privacy: .private)")
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        let bodyString = String(data: responseData, encoding: .utf8) ?? ""
        let bodySummary = String(bodyString.prefix(500))

        switch UploadStatusMapper.map(statusCode: http.statusCode, bodySummary: bodySummary) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

}
