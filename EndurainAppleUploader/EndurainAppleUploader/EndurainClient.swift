//
//  EndurainClient.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation

// MARK: - Upload result

struct UploadResult {
    let statusCode: Int
    let responseBody: String   // primeros 500 chars, para debug
}

// MARK: - Errors

enum EndurainClientError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case networkError(Error)
    case unexpectedResponse
    /// Error específico de subida: incluye status code y body resumido
    case uploadError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "La URL del servidor no es válida."
        case .unauthorized:
            return "API Key no autorizada o sin scope activities:upload (401/403)."
        case .serverError(let code):
            return "Error del servidor: \(code)."
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

    // Endpoint de prueba de conexión
    private static let testConnectionPath = "/api/v1/user/me"

    // Endpoint de subida de actividades
    private static let uploadActivityPath = "/api/v1/activities/create/upload"

    // Nombre del campo multipart — cambiar aquí si Endurain espera otro nombre
    private static let fileFieldName = "file"

    private let serverURL: String
    private let apiKey: String

    init(serverURL: String, apiKey: String) {
        self.serverURL = serverURL
        self.apiKey = apiKey
    }

    // MARK: - Test connection

    /// GET /api/v1/user/me con Authorization: Bearer <apiKey>.
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
        let body = buildMultipartBody(tcxData: tcxData, filename: filename, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 60
        request.httpBody = body

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        let bodyString = String(data: responseData, encoding: .utf8) ?? ""
        let bodySummary = String(bodyString.prefix(500))

        switch http.statusCode {
        case 200...299:
            return UploadResult(statusCode: http.statusCode, responseBody: bodySummary)
        case 401, 403:
            throw EndurainClientError.unauthorized
        case 409:
            throw EndurainClientError.uploadError(409, "Duplicado: este entrenamiento ya existe en Endurain. \(bodySummary)")
        default:
            throw EndurainClientError.uploadError(http.statusCode, bodySummary)
        }
    }

    // MARK: - Multipart builder

    private func buildMultipartBody(tcxData: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Parte del fichero
        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"\(Self.fileFieldName)\"; filename=\"\(filename)\"\(crlf)")
        body.append("Content-Type: application/vnd.garmin.tcx+xml\(crlf)")
        body.append(crlf)
        body.append(tcxData)
        body.append(crlf)

        // Cierre
        body.append("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Data helper

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
