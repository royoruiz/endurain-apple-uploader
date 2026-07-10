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

protocol EndurainActivityLookup {
    func containsEquivalentActivity(to item: SyncQueueItem) async throws -> Bool
}

struct EndurainServerActivity {
    let startDate: Date
    let durationSeconds: Double?
    let distanceMeters: Double?
}

// MARK: - Errors

enum EndurainClientError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case unauthorizedActivityLookup
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
            return "API Key no autorizada o sin scope activities:upload (401/403)."
        case .unauthorizedActivityLookup:
            return "API Key no autorizada o sin permisos profile/activities:read para comprobar duplicados en Endurain."
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

struct EndurainClient: EndurainActivityLookup {

    // Endpoint de prueba de conexión
    private static let testConnectionPath = "/api/v1/profile"

    // Endpoint de subida de actividades
    private static let uploadActivityPath = "/api/v1/activities/create/upload"

    private static let duplicateStartTolerance: TimeInterval = 2 * 60
    private static let duplicateDurationTolerance: TimeInterval = 2 * 60
    private static let duplicateDurationRatio = 0.05
    private static let duplicateDistanceTolerance = 250.0
    private static let duplicateDistanceRatio = 0.05

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
            AppLog.upload.error("Connection test failed: \(error.localizedDescription, privacy: .private)")
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EndurainClientError.unexpectedResponse
        }

        switch http.statusCode {
        case 200...299:
            guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                  contentType.localizedCaseInsensitiveContains("application/json") else {
                throw EndurainClientError.unexpectedResponse
            }
            return true
        case 401, 403:
            throw EndurainClientError.unauthorizedActivityLookup
        default:
            throw EndurainClientError.serverError(http.statusCode, "")
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
        let body = MultipartFormBuilder.body(tcxData: tcxData, filename: filename, boundary: boundary)

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

    func containsEquivalentActivity(to item: SyncQueueItem) async throws -> Bool {
        let userID = try await fetchCurrentUserID()
        let activities = try await fetchActivities(
            userID: userID,
            from: item.startDate.addingTimeInterval(-24 * 60 * 60),
            to: item.startDate.addingTimeInterval(24 * 60 * 60)
        )
        return activities.contains { Self.isEquivalent($0, to: item) }
    }

    private func fetchCurrentUserID() async throws -> Int {
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines) + Self.testConnectionPath
        guard let url = URL(string: urlString) else { throw EndurainClientError.invalidURL }

        var request = authenticatedJSONRequest(url: url)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw EndurainClientError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw EndurainClientError.unauthorizedActivityLookup }
            throw EndurainClientError.serverError(http.statusCode, "")
        }

        let object = try decodeJSONObject(from: data)
        guard let id = Self.findIntValue(named: "id", in: object) else {
            throw EndurainClientError.unexpectedResponse
        }
        return id
    }

    private func fetchActivities(userID: Int, from startDate: Date, to endDate: Date) async throws -> [EndurainServerActivity] {
        let start = Self.dateOnlyFormatter.string(from: startDate)
        let end = Self.dateOnlyFormatter.string(from: endDate)
        let path = "/api/v1/activities/user/\(userID)/page_number/1/num_records/200?start_date=\(start)&end_date=\(end)"
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines) + path) else {
            throw EndurainClientError.invalidURL
        }

        var request = authenticatedJSONRequest(url: url)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EndurainClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw EndurainClientError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw EndurainClientError.unauthorizedActivityLookup }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EndurainClientError.serverError(http.statusCode, String(body.prefix(500)))
        }

        let object = try decodeJSONObject(from: data)
        return Self.extractActivities(from: object)
    }

    private func decodeJSONObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EndurainClientError.unexpectedResponse
        }
    }

    private func authenticatedJSONRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("web", forHTTPHeaderField: "X-Client-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 20
        return request
    }

    static func extractActivities(from object: Any) -> [EndurainServerActivity] {
        var result: [EndurainServerActivity] = []
        collectActivityDictionaries(from: object).forEach { dictionary in
            guard let start = firstDate(in: dictionary, keys: ["start_time_tz_applied", "start_time", "startTime", "date"]) else {
                return
            }
            result.append(EndurainServerActivity(
                startDate: start,
                durationSeconds: firstDouble(in: dictionary, keys: ["total_timer_time", "duration", "duration_seconds", "moving_time"]),
                distanceMeters: firstDouble(in: dictionary, keys: ["distance", "total_distance", "distance_meters"])
            ))
        }
        return result
    }

    static func isEquivalent(_ activity: EndurainServerActivity, to item: SyncQueueItem) -> Bool {
        guard abs(activity.startDate.timeIntervalSince(item.startDate)) <= duplicateStartTolerance else { return false }

        if let duration = activity.durationSeconds {
            let delta = abs(duration - item.durationSeconds)
            let maxDelta = max(duplicateDurationTolerance, max(duration, item.durationSeconds) * duplicateDurationRatio)
            guard delta <= maxDelta else { return false }
        }

        if let serverDistance = activity.distanceMeters, let localDistance = item.distanceMeters {
            let delta = abs(serverDistance - localDistance)
            let maxDelta = max(duplicateDistanceTolerance, max(serverDistance, localDistance) * duplicateDistanceRatio)
            guard delta <= maxDelta else { return false }
        }

        return true
    }

    private static func collectActivityDictionaries(from object: Any) -> [[String: Any]] {
        if let array = object as? [Any] {
            return array.flatMap { collectActivityDictionaries(from: $0) }
        }

        guard let dictionary = object as? [String: Any] else { return [] }
        if firstDate(in: dictionary, keys: ["start_time_tz_applied", "start_time", "startTime", "date"]) != nil {
            return [dictionary]
        }

        return dictionary.values.flatMap { collectActivityDictionaries(from: $0) }
    }

    private static func findIntValue(named key: String, in object: Any) -> Int? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? String, let intValue = Int(value) { return intValue }
            for value in dictionary.values {
                if let found = findIntValue(named: key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findIntValue(named: key, in: value) { return found }
            }
        }
        return nil
    }

    private static func firstDouble(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double { return value }
            if let value = dictionary[key] as? Int { return Double(value) }
            if let value = dictionary[key] as? String, let doubleValue = Double(value) { return doubleValue }
        }
        return nil
    }

    private static func firstDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            if let date = iso8601DateFormatter.date(from: value)
                ?? fallbackDateFormatter.date(from: value)
                ?? localDateFormatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let iso8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
