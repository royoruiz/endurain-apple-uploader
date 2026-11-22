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
    case importPending
    case importFailed
    case importStateUnavailable
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
        case .importPending:
            return "Import is still pending. It has not been marked as uploaded."
        case .importFailed:
            return "Endurain could not import the file. It has not been marked as uploaded."
        case .importStateUnavailable:
            return "Import state could not be saved or confirmed. Check local storage and the server before retrying."
        case .uploadError(let code, let body):
            let summary = body.isEmpty ? "(sin body)" : body
            return "Error al subir [\(code)]: \(summary)"
        }
    }
}

// MARK: - Client

struct EndurainClient {

    private let serverURL: String
    private let apiKey: String
    private let session: URLSession
    private let receiptDirectoryURL: URL?
    private let namespaceID: String?

    init(serverURL: String, apiKey: String, session: URLSession = .shared,
         receiptDirectoryURL: URL? = nil, namespaceID: String? = nil) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.session = session
        self.receiptDirectoryURL = receiptDirectoryURL
        self.namespaceID = namespaceID
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

    /// POST {serverURL}/api/v1/activities/upload
    /// Autenticación: X-API-Key header.
    /// Body: multipart/form-data con el fichero TCX en el campo "file".
    func uploadActivityTCX(tcxData: Data, filename: String) async throws -> UploadResult {
        let receipts = IngestionReceiptStore(
            directoryURL: try receiptDirectoryURL ?? IngestionReceiptStore.applicationDirectory())
        let scope = try namespaceID ?? EndurainConfigurationIdentity.namespaceID(
            normalizedServerURL: ServerURLNormalizer.normalize(serverURL),
            normalizedUserIdentifier: apiKey)
        if let savedJobID = try receipts.jobID(scope: scope, filename: filename) {
            let saved = try await ingestionJob(id: savedJobID)
            guard saved.id == savedJobID else { throw EndurainClientError.unexpectedResponse }
            return try await awaitImportCompletion(saved)
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = MultipartFormBuilder.body(tcxData: tcxData, filename: filename, boundary: boundary)

        var request = try ActivityIngestionAPI.uploadRequest(
            serverURL: serverURL, apiKey: apiKey, filename: filename, boundary: boundary
        )
        request.httpBody = body
        try receipts.record(jobID: nil, scope: scope, filename: filename)

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            try? receipts.remove(scope: scope, filename: filename)
            AppLog.upload.error("Foreground upload failed: \(error.localizedDescription, privacy: .private)")
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        if http.statusCode == 202 {
            let job = try ActivityIngestionAPI.decodeJob(responseData)
            try receipts.record(jobID: job.id, scope: scope, filename: filename)
            return try await awaitImportCompletion(job)
        }
        try receipts.remove(scope: scope, filename: filename)

        let bodyString = String(data: responseData, encoding: .utf8) ?? ""
        let bodySummary = String(bodyString.prefix(500))

        switch UploadStatusMapper.map(statusCode: http.statusCode, bodySummary: bodySummary) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    private func awaitImportCompletion(_ initial: ActivityIngestionJob) async throws -> UploadResult {
        var job = initial
        for attempt in 0...20 {
            switch job.status {
            case .completed:
                guard job.confirmsActivity else { throw EndurainClientError.unexpectedResponse }
                return UploadResult(statusCode: 200, responseBody: "Import completed.")
            case .failed:
                throw EndurainClientError.importFailed
            case .pending, .processing:
                guard attempt < 20 else { throw EndurainClientError.importPending }
                if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                let refreshed = try await ingestionJob(id: job.id)
                guard refreshed.id == job.id else { throw EndurainClientError.unexpectedResponse }
                job = refreshed
            }
        }
        throw EndurainClientError.importPending
    }

    func ingestionJob(id: String) async throws -> ActivityIngestionJob {
        let request = try ActivityIngestionAPI.jobRequest(serverURL: serverURL, apiKey: apiKey, jobID: id)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EndurainClientError.unexpectedResponse }
        guard http.statusCode == 200 else {
            switch UploadStatusMapper.map(statusCode: http.statusCode, bodySummary: "") {
            case .failure(let error): throw error
            case .success: throw EndurainClientError.unexpectedResponse
            }
        }
        return try ActivityIngestionAPI.decodeJob(data)
    }

}
