//
//  BackgroundUploadService.swift
//  EndurainAppleUploader
//
//  Background URLSession uploader for TCX files.
//

import Foundation
import os

@MainActor
final class BackgroundUploadService: NSObject, @preconcurrency URLSessionTaskDelegate, @preconcurrency URLSessionDataDelegate {

    static let sessionIdentifier = "es.overtus.endurainsync.upload"

    private static let multipartSubdir = SyncQueueStore.multipartSubdir

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

    func cancelActiveUploadsAndClearLocalState(namespaceID: String? = nil) async {
        let tasks = await session.allTasks
        for task in tasks {
            task.cancel()
        }
        responseBodies.removeAll()
        responseStatusCodes.removeAll()
        try? clearMultipartDirectory(namespaceID: namespaceID)
    }

    @discardableResult
    func scheduleUpload(
        namespaceID: String,
        uuid: String,
        tcxFileURL: URL,
        serverURL: String,
        apiKey: String
    ) throws -> Bool {
        if let existing = queue.item(namespaceID: namespaceID, uuid: uuid),
           existing.status == .uploading || existing.importJobID != nil {
            AppLog.upload.info("Skipping already active background upload for workout \(uuid, privacy: .private), task \(existing.backgroundTaskIdentifier ?? -1)")
            return false
        }

        let filename = "apple-health-\(uuid.lowercased()).tcx"
        let boundary = "Boundary-\(UUID().uuidString)"
        let request = try ActivityIngestionAPI.uploadRequest(
            serverURL: serverURL, apiKey: apiKey, filename: filename, boundary: boundary
        )
        let multipartFileURL = try writeMultipartFile(
            tcxFileURL: tcxFileURL,
            filename: filename,
            boundary: boundary,
            namespaceID: namespaceID,
            uuid: uuid
        )

        let receipts = queue.ingestionReceipts
        guard !receipts.exists(scope: namespaceID, filename: filename) else {
            throw EndurainClientError.importStateUnavailable
        }
        try receipts.record(jobID: nil, scope: namespaceID, filename: filename)
        let task = session.uploadTask(with: request, fromFile: multipartFileURL)
        let relativeMultipartPath = Self.multipartSubdir + "/" + namespaceID + "/" + multipartFileURL.lastPathComponent
        guard queue.markUploading(
            namespaceID: namespaceID,
            uuid: uuid,
            taskIdentifier: task.taskIdentifier,
            multipartFilePath: relativeMultipartPath
        ) else {
            task.cancel()
            try? receipts.remove(scope: namespaceID, filename: filename)
            throw EndurainClientError.importStateUnavailable
        }

        AppLog.upload.info("Scheduled background upload task \(task.taskIdentifier) for workout \(uuid, privacy: .private)")
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
        handleCompletedTask(
            taskIdentifier: task.taskIdentifier,
            error: error,
            statusCode: responseStatusCodes[task.taskIdentifier] ?? (task.response as? HTTPURLResponse)?.statusCode,
            bodyData: responseBodies[task.taskIdentifier] ?? Data()
        )
    }

    func handleCompletedTask(
        taskIdentifier: Int,
        error: Error?,
        statusCode: Int?,
        bodyData: Data
    ) {
        let taskID = taskIdentifier
        guard let item = queue.item(forTaskIdentifier: taskID) else {
            cleanup(taskIdentifier: taskID, multipartPath: nil)
            return
        }
        guard let namespaceID = item.namespaceID else {
            cleanup(taskIdentifier: taskID, multipartPath: item.multipartFilePath)
            return
        }

        let body = String(data: bodyData, encoding: .utf8) ?? ""
        let bodySummary = String(body.prefix(500))

        defer {
            cleanup(taskIdentifier: taskID, multipartPath: item.multipartFilePath)
            onQueueChanged?()
        }

        if let error {
            discardUploadIntent(item, namespaceID: namespaceID)
            AppLog.upload.error("Background upload task \(taskID) failed: \(error.localizedDescription, privacy: .private)")
            queue.requeue(namespaceID: namespaceID, uuid: item.workoutUUID, error: "Error de red en background upload: \(error.localizedDescription)")
            return
        }

        guard let statusCode else {
            discardUploadIntent(item, namespaceID: namespaceID)
            AppLog.upload.error("Background upload task \(taskID) completed without HTTP response")
            queue.requeue(namespaceID: namespaceID, uuid: item.workoutUUID, error: "Respuesta HTTP ausente en background upload.")
            return
        }

        if statusCode == 202 {
            do {
                let job = try ActivityIngestionAPI.decodeJob(bodyData)
                guard queue.markImportAccepted(namespaceID: namespaceID, uuid: item.workoutUUID, jobID: job.id) else {
                    throw EndurainClientError.importStateUnavailable
                }
                queue.applyIngestionJob(job, namespaceID: namespaceID, uuid: item.workoutUUID)
            } catch EndurainClientError.importStateUnavailable {
                queue.markFailed(namespaceID: namespaceID, uuid: item.workoutUUID,
                                 error: EndurainClientError.importStateUnavailable.localizedDescription)
            } catch {
                queue.markFailed(namespaceID: namespaceID, uuid: item.workoutUUID,
                                 error: "Invalid import acknowledgement. The TCX has been retained for an idempotent retry.")
            }
            return
        }

        discardUploadIntent(item, namespaceID: namespaceID)
        switch UploadStatusMapper.map(statusCode: statusCode, bodySummary: bodySummary) {
        case .success:
            queue.markUploaded(namespaceID: namespaceID, uuid: item.workoutUUID, serverURL: item.normalizedServerURL ?? item.serverURL ?? "")
            deleteTCXIfPresent(item)
            AppLog.upload.info("Background upload task \(taskID) completed with status \(statusCode)")
        case .failure(.unauthorized):
            queue.markFailed(namespaceID: namespaceID, uuid: item.workoutUUID, error: "API key is not authorized for activity upload or is invalid")
        case .failure(.duplicate):
            queue.markSkipped(namespaceID: namespaceID, uuid: item.workoutUUID, reason: "skippedExistingServerActivity")
            deleteTCXIfPresent(item)
        case .failure(.rateLimited):
            queue.requeue(namespaceID: namespaceID, uuid: item.workoutUUID, error: "Endurain limitó las peticiones. Se reintentará automáticamente.")
        case .failure(.serverError):
            queue.requeue(namespaceID: namespaceID, uuid: item.workoutUUID, error: "Endurain devolvió un error de servidor. Se reintentará automáticamente.")
        case .failure:
            queue.markFailed(namespaceID: namespaceID, uuid: item.workoutUUID, error: "Endurain devolvió HTTP \(statusCode).")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundURLSessionCompletionStore.callCompletionHandler()
    }

    // MARK: - Private

    private func discardUploadIntent(_ item: SyncQueueItem, namespaceID: String) {
        try? queue.ingestionReceipts.remove(
            scope: namespaceID, filename: "apple-health-\(item.workoutUUID.lowercased()).tcx")
    }

    private func writeMultipartFile(
        tcxFileURL: URL,
        filename: String,
        boundary: String,
        namespaceID: String,
        uuid: String
    ) throws -> URL {
        let directory = queue.tcxQueueDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.multipartSubdir, isDirectory: true)
            .appendingPathComponent(namespaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory.appendingPathComponent("\(uuid).multipart")
        try MultipartFormBuilder.writeBodyFile(
            tcxFileURL: tcxFileURL,
            filename: filename,
            boundary: boundary,
            outputURL: outputURL
        )

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

    private func clearMultipartDirectory(namespaceID: String?) throws {
        var directory = queue.storageDirectoryURL.appendingPathComponent(Self.multipartSubdir, isDirectory: true)
        if let namespaceID {
            directory = directory.appendingPathComponent(namespaceID, isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try FileManager.default.removeItem(at: url)
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
