//
//  BackgroundUploadService.swift
//  EndurainAppleUploader
//
//  Background URLSession uploader for TCX files.
//

import Foundation

@MainActor
final class BackgroundUploadService: NSObject, @preconcurrency URLSessionTaskDelegate, @preconcurrency URLSessionDataDelegate {

    static let sessionIdentifier = "es.overtus.endurainsync.upload"

    private static let uploadPath = "/api/v1/activities/create/upload"
    private static let fileFieldName = "file"
    private static let tcxContentType = "application/vnd.garmin.tcx+xml"
    private static let multipartSubdir = "MultipartUploads"

    private let queue: SyncQueueStore
    private var responseBodies: [Int: Data] = [:]
    private var responseStatusCodes: [Int: Int] = [:]
    var onQueueChanged: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    init(queue: SyncQueueStore) {
        self.queue = queue
        super.init()
    }

    func reconnect() async {
        let tasks = await session.allTasks
        let active = Set(tasks.map(\.taskIdentifier))
        queue.reconcileUploadingItems(activeTaskIdentifiers: active)
        onQueueChanged?()
    }

    @discardableResult
    func scheduleUpload(
        uuid: String,
        tcxFileURL: URL,
        serverURL: String,
        apiKey: String
    ) throws -> Bool {
        if let existing = queue.item(for: uuid), existing.status == .uploading {
            print("[BackgroundUploadService] Skip already-uploading uuid=\(uuid) task=\(existing.backgroundTaskIdentifier.map(String.init) ?? "nil")")
            return false
        }

        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedServer + Self.uploadPath) else {
            throw EndurainClientError.invalidURL
        }

        let filename = "apple-health-\(uuid.lowercased()).tcx"
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartFileURL = try writeMultipartFile(
            tcxFileURL: tcxFileURL,
            filename: filename,
            boundary: boundary,
            uuid: uuid
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 60

        let task = session.uploadTask(with: request, fromFile: multipartFileURL)
        let relativeMultipartPath = Self.multipartSubdir + "/" + multipartFileURL.lastPathComponent
        queue.markUploading(
            uuid: uuid,
            taskIdentifier: task.taskIdentifier,
            multipartFilePath: relativeMultipartPath
        )

        print("[BackgroundUploadService] Scheduled upload uuid=\(uuid) task=\(task.taskIdentifier) file=\(multipartFileURL.path)")
        task.resume()
        return true
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            responseStatusCodes[dataTask.taskIdentifier] = http.statusCode
        }
        completionHandler(.allow)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        guard let item = queue.item(forTaskIdentifier: taskID) else {
            cleanup(taskIdentifier: taskID, multipartPath: nil)
            return
        }

        let bodyData = responseBodies[taskID] ?? Data()
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        let bodySummary = String(body.prefix(500))
        let statusCode = responseStatusCodes[taskID] ?? (task.response as? HTTPURLResponse)?.statusCode

        print("[BackgroundUploadService] Completed task=\(taskID) uuid=\(item.workoutUUID) status=\(statusCode.map(String.init) ?? "nil") error=\(error?.localizedDescription ?? "nil") body=\(bodySummary)")

        defer {
            cleanup(taskIdentifier: taskID, multipartPath: item.multipartFilePath)
            onQueueChanged?()
        }

        if let error {
            queue.requeue(uuid: item.workoutUUID, error: "Error de red en background upload: \(error.localizedDescription)")
            return
        }

        guard let statusCode else {
            queue.requeue(uuid: item.workoutUUID, error: "Respuesta HTTP ausente en background upload.")
            return
        }

        switch statusCode {
        case 200...299:
            queue.markUploaded(uuid: item.workoutUUID, serverURL: item.serverURL ?? "")
            deleteTCXIfPresent(item)
            print("[BackgroundUploadService] Uploaded uuid=\(item.workoutUUID) status=\(statusCode)")
        case 401, 403:
            queue.markFailed(uuid: item.workoutUUID, error: "API key no autorizada o sin scope activities:upload")
        case 409:
            queue.markUploaded(uuid: item.workoutUUID, serverURL: item.serverURL ?? "")
            deleteTCXIfPresent(item)
        case 429, 500...599:
            queue.requeue(uuid: item.workoutUUID, error: "HTTP \(statusCode): \(bodySummary)")
        default:
            queue.markFailed(uuid: item.workoutUUID, error: "HTTP \(statusCode): \(bodySummary)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundURLSessionCompletionStore.callCompletionHandler()
    }

    // MARK: - Private

    private func writeMultipartFile(
        tcxFileURL: URL,
        filename: String,
        boundary: String,
        uuid: String
    ) throws -> URL {
        let directory = queue.tcxQueueDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.multipartSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory.appendingPathComponent("\(uuid).multipart")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(Self.fileFieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Type: \(Self.tcxContentType)\r\n\r\n".utf8))
        try handle.write(contentsOf: Data(contentsOf: tcxFileURL))
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))

        return outputURL
    }

    private func cleanup(taskIdentifier: Int, multipartPath: String?) {
        responseBodies[taskIdentifier] = nil
        responseStatusCodes[taskIdentifier] = nil

        if let multipartPath {
            let url = queue.tcxQueueDirectoryURL.deletingLastPathComponent().appendingPathComponent(multipartPath)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteTCXIfPresent(_ item: SyncQueueItem) {
        guard let tcxFilePath = item.tcxFilePath else { return }
        let url = queue.tcxQueueDirectoryURL.appendingPathComponent(tcxFilePath)
        try? FileManager.default.removeItem(at: url)
    }
}

enum BackgroundURLSessionCompletionStore {
    @MainActor private static var completionHandler: (() -> Void)?

    @MainActor
    static func setCompletionHandler(_ handler: @escaping () -> Void) {
        completionHandler = handler
    }

    @MainActor
    static func callCompletionHandler() {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }
}
