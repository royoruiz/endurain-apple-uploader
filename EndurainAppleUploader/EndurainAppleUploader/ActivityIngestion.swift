import Foundation
import CryptoKit

struct ActivityIngestionJob: Decodable {
    enum Status: String, Decodable { case pending, processing, completed, failed }

    let id: String
    let kind: String
    let status: Status
    let errorCode: String?
    let activityIDs: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, kind, status
        case errorCode = "error_code"
        case activityIDs = "activity_ids"
    }

    var confirmsActivity: Bool { status == .completed && !(activityIDs ?? []).isEmpty }

    var failureCode: String {
        guard let errorCode, !errorCode.isEmpty, errorCode.count <= 80,
              errorCode.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
              }) else { return "unknown" }
        return errorCode
    }
}

enum ActivityIngestionAPI {
    static let uploadPath = "/api/v1/activities/upload"

    // Both transports use the same filename for an HKWorkout. Server-side keys
    // are caller-scoped; deriving the key needs no mutable or secret local state.
    static func idempotencyKey(filename: String) -> String {
        let digest = SHA256.hash(data: Data(filename.lowercased().utf8))
        return "apple-health-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func uploadRequest(serverURL: String, apiKey: String, filename: String,
                              boundary: String) throws -> URLRequest {
        var request = try request(serverURL: serverURL, path: uploadPath, apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey(filename: filename), forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    static func jobRequest(serverURL: String, apiKey: String, jobID: String) throws -> URLRequest {
        guard validJobID(jobID) else { throw EndurainClientError.unexpectedResponse }
        return try request(serverURL: serverURL,
                           path: "/api/v1/activities/ingestion-jobs/" + jobID, apiKey: apiKey)
    }

    static func decodeJob(_ data: Data) throws -> ActivityIngestionJob {
        let job = try JSONDecoder().decode(ActivityIngestionJob.self, from: data)
        guard validJobID(job.id), job.kind == "upload" else {
            throw EndurainClientError.unexpectedResponse
        }
        return job
    }

    private static func validJobID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 255 && id != "." && id != ".."
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
            }
    }

    private static func request(serverURL: String, path: String, apiKey: String) throws -> URLRequest {
        let normalized = try ServerURLNormalizer.normalize(serverURL)
        guard let components = URLComponents(string: normalized),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = URL(string: normalized + path) else {
            throw EndurainClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 60
        return request
    }
}

/// A small write-ahead receipt shared by both upload paths. It contains only a
/// job handle, never a workout, API key, server URL, or route.
struct IngestionReceiptStore {
    let directoryURL: URL

    private struct Receipt: Codable { let jobID: String? }

    static func applicationDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("EndurainAppleUploader/IngestionReceipts", isDirectory: true)
    }

    private func file(scope: String, filename: String) -> URL {
        let scopeHash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(scopeHash, isDirectory: true)
            .appendingPathComponent(ActivityIngestionAPI.idempotencyKey(filename: filename) + ".json")
    }

    func exists(scope: String, filename: String) -> Bool {
        FileManager.default.fileExists(atPath: file(scope: scope, filename: filename).path)
    }

    func jobID(scope: String, filename: String) throws -> String? {
        let url = file(scope: scope, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard let id = receipt.jobID else { throw EndurainClientError.importStateUnavailable }
        return id
    }

    func record(jobID: String?, scope: String, filename: String) throws {
        let url = file(scope: scope, filename: filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Receipt(jobID: jobID)).write(to: url, options: .atomic)
    }

    func remove(scope: String, filename: String) throws {
        let url = file(scope: scope, filename: filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removeScope(_ scope: String) throws {
        let directory = file(scope: scope, filename: "").deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
struct ActivityImportMonitor {
    let queue: SyncQueueStore
    var session: URLSession = .shared

    /// One bounded pass. Accepted jobs are never converted back into POSTs.
    func refresh(namespaceID: String, serverURL: String, apiKey: String) async {
        let client = EndurainClient(serverURL: serverURL, apiKey: apiKey, session: session)
        for item in queue.importingItems(namespaceID: namespaceID).prefix(10) {
            guard let id = item.importJobID else { continue }
            do {
                let job = try await client.ingestionJob(id: id)
                guard job.id == id else { throw EndurainClientError.unexpectedResponse }
                queue.applyIngestionJob(job, namespaceID: namespaceID, uuid: item.workoutUUID)
            } catch {
                // A GET failure is not permission to repeat an accepted upload.
                queue.recordImportPollError(namespaceID: namespaceID, uuid: item.workoutUUID,
                                            error: "Unable to confirm import. The saved job will be checked again.")
            }
        }
    }
}
