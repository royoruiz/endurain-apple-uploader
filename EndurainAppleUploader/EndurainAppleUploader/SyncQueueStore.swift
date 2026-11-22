//
//  SyncQueueStore.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//
//  Cola persistente de entrenamientos pendientes de subir.
//  Almacenamiento: JSON en Application Support/EndurainAppleUploader/sync-queue.json
//  Escritura atómica: fichero temporal → move al destino final.
//

import Foundation
import os

// MARK: - SyncStatus

enum SyncStatus: String, Codable, Equatable, Hashable {
    case discovered     // detectado, aún no evaluado
    case queued         // listo para generar TCX y subir
    case generating     // generando TCX en este momento
    case readyToUpload  // TCX generado, pendiente de subir
    case uploading      // subida en curso
    case uploaded       // subido correctamente
    case failed         // falló; ver lastError
    case skipped        // omitido de forma intencional; ver lastError
}

// MARK: - SyncQueueItem

struct SyncQueueItem: Codable, Identifiable {
    var namespaceID: String? = nil      // nil en registros legacy previos al modelo server+user
    var normalizedServerURL: String? = nil
    var normalizedUserIdentifier: String? = nil
    var workoutUUID: String      // HKWorkout.uuid.uuidString — clave de deduplicación
    var startDate: Date
    var endDate: Date
    var activityTypeName: String
    var distanceMeters: Double?
    var durationSeconds: Double
    var status: SyncStatus
    var tcxFilePath: String?     // ruta relativa a Application Support/TCXQueue/<uuid>.tcx
    var retryCount: Int
    var lastError: String?
    var uploadedAt: Date?
    var serverURL: String?
    var fileHash: String?        // SHA256 del TCX, para detección de cambios (opcional)
    var backgroundTaskIdentifier: Int?
    var multipartFilePath: String?
    var uploadStartedAt: Date?
    var createdAt: Date
    var importJobID: String? = nil

    var id: String { (namespaceID ?? "legacy") + ":" + workoutUUID }

    var isLegacy: Bool { namespaceID == nil || namespaceID?.isEmpty == true }
}

// MARK: - SyncQueueStore

final class SyncQueueStore {

    private enum DuplicateTolerance {
        static let startDateSeconds: TimeInterval = 2 * 60
        static let durationSeconds: TimeInterval = 2 * 60
        static let durationRatio = 0.05
        static let distanceMeters = 250.0
        static let distanceRatio = 0.05
    }

    // MARK: - File paths

    private static let appSupportSubdir = "EndurainAppleUploader"
    private static let queueFilename    = "sync-queue.json"
    private static let tcxQueueSubdir   = "TCXQueue"
    static let multipartSubdir = "MultipartUploads"

    private let queueFileURL: URL
    let tcxQueueDirectoryURL: URL
    let storageDirectoryURL: URL
    var ingestionReceipts: IngestionReceiptStore {
        IngestionReceiptStore(directoryURL: storageDirectoryURL.appendingPathComponent("IngestionReceipts"))
    }

    // MARK: - State (acceso serializado por un actor interno)

    private var items: [SyncQueueItem] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    init(baseDirectoryURL: URL? = nil) throws {
        let baseDirectory: URL
        if let baseDirectoryURL {
            baseDirectory = baseDirectoryURL
        } else {
            baseDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        let subdir = baseDirectory.appendingPathComponent(Self.appSupportSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        storageDirectoryURL = subdir
        queueFileURL = subdir.appendingPathComponent(Self.queueFilename)

        tcxQueueDirectoryURL = subdir.appendingPathComponent(Self.tcxQueueSubdir, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tcxQueueDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Load

    func load() {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else {
            items = []
            return
        }
        do {
            let data = try Data(contentsOf: queueFileURL)
            items = try decoder.decode([SyncQueueItem].self, from: data)
            restoreImportReceipts()
        } catch {
            AppLog.queue.error("Failed to load sync queue: \(error.localizedDescription, privacy: .private)")
            items = []
        }
    }

    // MARK: - Save (escritura atómica)

    @discardableResult
    func save() -> Bool {
        do {
            let data = try encoder.encode(items)
            // Escribir a fichero temporal en el mismo directorio
            let tempURL = queueFileURL.deletingLastPathComponent()
                .appendingPathComponent("sync-queue.tmp.json")
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: queueFileURL.path) {
                _ = try FileManager.default.replaceItemAt(queueFileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: queueFileURL)
            }
            return true
        } catch {
            AppLog.queue.error("Failed to save sync queue: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    // MARK: - Clear

    func clearAll() throws {
        resetInMemoryState()
        try deleteStorageFile()
        try clearDirectoryContents(tcxQueueDirectoryURL)
        try clearDirectoryContents(storageDirectoryURL.appendingPathComponent(Self.multipartSubdir, isDirectory: true))
        try clearDirectoryContents(ingestionReceipts.directoryURL)
    }

    func deleteHistory(namespaceID: String) throws {
        try ingestionReceipts.removeScope(namespaceID)
        let removed = items.filter { $0.namespaceID == namespaceID }
        items.removeAll { $0.namespaceID == namespaceID }
        save()

        for item in removed {
            if let tcxFilePath = item.tcxFilePath {
                try? FileManager.default.removeItem(at: tcxQueueDirectoryURL.appendingPathComponent(tcxFilePath))
            }
            if let multipartFilePath = item.multipartFilePath {
                try? FileManager.default.removeItem(at: storageDirectoryURL.appendingPathComponent(multipartFilePath))
            }
        }

        try? removeDirectoryIfEmpty(tcxQueueDirectoryURL.appendingPathComponent(namespaceID, isDirectory: true))
        try? removeDirectoryIfEmpty(
            storageDirectoryURL
                .appendingPathComponent(Self.multipartSubdir, isDirectory: true)
                .appendingPathComponent(namespaceID, isDirectory: true)
        )
    }

    func deleteStorageFile() throws {
        if FileManager.default.fileExists(atPath: queueFileURL.path) {
            try FileManager.default.removeItem(at: queueFileURL)
        }
    }

    func resetInMemoryState() {
        items = []
    }

    // MARK: - Upsert

    /// Añade el workout a la cola si no existe, o lo ignora si ya está.
    /// Nunca regresa a queued un item que ya está uploaded.
    func upsertWorkout(
        namespaceID: String,
        normalizedServerURL: String,
        normalizedUserIdentifier: String,
        uuid: String,
        startDate: Date,
        endDate: Date,
        activityTypeName: String,
        durationSeconds: Double,
        distanceMeters: Double?,
    ) {
        // Si ya existe, no hacer nada (preserva estado actual)
        if items.contains(where: { $0.namespaceID == namespaceID && $0.workoutUUID == uuid }) { return }

        let item = SyncQueueItem(
            namespaceID: namespaceID,
            normalizedServerURL: normalizedServerURL,
            normalizedUserIdentifier: normalizedUserIdentifier,
            workoutUUID: uuid,
            startDate: startDate,
            endDate: endDate,
            activityTypeName: activityTypeName,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            status: .queued,
            tcxFilePath: nil,
            retryCount: 0,
            lastError: nil,
            uploadedAt: nil,
            serverURL: normalizedServerURL,
            fileHash: nil,
            backgroundTaskIdentifier: nil,
            multipartFilePath: nil,
            uploadStartedAt: nil,
            createdAt: Date()
        )
        items.append(item)
        save()
    }

    func likelyDuplicate(
        namespaceID: String,
        uuid: String,
        startDate: Date,
        activityTypeName: String,
        durationSeconds: Double,
        distanceMeters: Double?
    ) -> SyncQueueItem? {
        items.first { item in
            guard item.namespaceID == namespaceID else { return false }
            guard item.workoutUUID != uuid else { return false }
            return isLikelySameActivity(
                item,
                startDate: startDate,
                activityTypeName: activityTypeName,
                durationSeconds: durationSeconds,
                distanceMeters: distanceMeters
            )
        }
    }

    func likelyDuplicate(of item: SyncQueueItem, restrictedTo statuses: Set<SyncStatus>? = nil) -> SyncQueueItem? {
        guard let namespaceID = item.namespaceID else { return nil }
        return items.first { candidate in
            guard candidate.namespaceID == namespaceID else { return false }
            guard candidate.workoutUUID != item.workoutUUID else { return false }
            if let statuses, !statuses.contains(candidate.status) { return false }
            return isLikelySameActivity(
                candidate,
                startDate: item.startDate,
                activityTypeName: item.activityTypeName,
                durationSeconds: item.durationSeconds,
                distanceMeters: item.distanceMeters
            )
        }
    }

    // MARK: - Status transitions

    func markGenerating(namespaceID: String, uuid: String) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .generating
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func markReadyToUpload(namespaceID: String, uuid: String, tcxFilePath: String, fileHash: String? = nil) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .readyToUpload
            $0.tcxFilePath = tcxFilePath
            $0.fileHash = fileHash
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    @discardableResult
    func markUploading(namespaceID: String, uuid: String, taskIdentifier: Int? = nil, multipartFilePath: String? = nil) -> Bool {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .uploading
            $0.backgroundTaskIdentifier = taskIdentifier
            $0.multipartFilePath = multipartFilePath
            $0.uploadStartedAt = Date()
        }
    }

    @discardableResult
    func markUploaded(namespaceID: String, uuid: String, serverURL: String) -> Bool {
        let saved = mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .uploaded
            $0.uploadedAt = Date()
            $0.serverURL = serverURL
            $0.lastError = nil
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
        if saved { try? ingestionReceipts.remove(scope: namespaceID, filename: uploadFilename(uuid)) }
        return saved
    }

    func markSkipped(namespaceID: String, uuid: String, reason: String) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .skipped
            $0.lastError = reason
            $0.uploadStartedAt = nil
        }
    }

    func markFailed(namespaceID: String, uuid: String, error: String) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.status = .failed
            $0.lastError = error
            $0.retryCount += 1
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func requeue(namespaceID: String, uuid: String, error: String? = nil) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            guard $0.importJobID == nil,
                  !ingestionReceipts.exists(scope: namespaceID, filename: uploadFilename(uuid)) else { return }
            $0.status = $0.tcxFilePath == nil ? .queued : .readyToUpload
            $0.lastError = error
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    // Re-encola un item failed para volver a intentarlo
    func requeueFailed(namespaceID: String, uuid: String) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            guard $0.status == .failed, $0.importJobID == nil,
                  !ingestionReceipts.exists(scope: namespaceID, filename: uploadFilename(uuid)) else { return }
            $0.status = .queued
            $0.lastError = nil
        }
    }

    // MARK: - Queries

    @discardableResult
    func markImportAccepted(namespaceID: String, uuid: String, jobID: String) -> Bool {
        do {
            try ingestionReceipts.record(jobID: jobID, scope: namespaceID, filename: uploadFilename(uuid))
        } catch {
            return false
        }
        mutate(namespaceID: namespaceID, uuid: uuid) {
            $0.importJobID = jobID
            $0.status = .uploading
            $0.lastError = nil
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
        // The receipt remains durable even when the queue snapshot cannot save.
        return true
    }

    func importingItems(namespaceID: String) -> [SyncQueueItem] {
        restoreImportReceipts()
        return items.filter { $0.namespaceID == namespaceID && $0.status == .uploading && $0.importJobID != nil }
    }

    func unconfirmedUploadError(namespaceID: String) -> String? {
        restoreImportReceipts()
        return items.first {
            $0.namespaceID == namespaceID && $0.status == .uploading
                && $0.importJobID == nil && $0.backgroundTaskIdentifier == nil
                && ingestionReceipts.exists(scope: namespaceID, filename: uploadFilename($0.workoutUUID))
        }?.lastError
    }

    func recordImportPollError(namespaceID: String, uuid: String, error: String) {
        mutate(namespaceID: namespaceID, uuid: uuid) {
            guard $0.importJobID != nil, $0.status == .uploading else { return }
            $0.lastError = error
        }
    }

    func applyIngestionJob(_ job: ActivityIngestionJob, namespaceID: String, uuid: String) {
        guard let item = item(namespaceID: namespaceID, uuid: uuid),
              item.status == .uploading, item.importJobID == job.id else { return }
        switch job.status {
        case .pending, .processing:
            mutate(namespaceID: namespaceID, uuid: uuid) { $0.lastError = nil }
        case .failed:
            markFailed(namespaceID: namespaceID, uuid: uuid,
                       error: "Endurain import failed (\(job.failureCode)). The TCX and job identifier have been retained.")
        case .completed:
            guard job.confirmsActivity else {
                markFailed(namespaceID: namespaceID, uuid: uuid,
                           error: "Import completed without an activity identifier. The TCX has been retained.")
                return
            }
            if markUploaded(namespaceID: namespaceID, uuid: uuid,
                            serverURL: item.normalizedServerURL ?? item.serverURL ?? ""),
               let path = item.tcxFilePath {
                try? FileManager.default.removeItem(at: tcxQueueDirectoryURL.appendingPathComponent(path))
            }
        }
    }

    func pendingItems(namespaceID: String) -> [SyncQueueItem] {
        items.filter { $0.namespaceID == namespaceID && $0.importJobID == nil
            && !ingestionReceipts.exists(scope: namespaceID, filename: uploadFilename($0.workoutUUID))
            && ($0.status == .queued || $0.status == .readyToUpload) }
            .sorted { $0.startDate < $1.startDate }
    }

    func failedItems(namespaceID: String) -> [SyncQueueItem] {
        items.filter { $0.namespaceID == namespaceID && $0.status == .failed }
            .sorted { $0.startDate < $1.startDate }
    }

    func skippedItems(namespaceID: String) -> [SyncQueueItem] {
        items.filter { $0.namespaceID == namespaceID && $0.status == .skipped }
            .sorted { $0.startDate < $1.startDate }
    }

    @discardableResult
    func cleanupInvalidReadyToUploadTCX(minTrackpoints: Int = 20) -> Int {
        var cleaned = 0

        for index in items.indices {
            guard items[index].namespaceID != nil,
                  items[index].status == .readyToUpload,
                  let relativePath = items[index].tcxFilePath else { continue }

            let fileURL = tcxQueueDirectoryURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                items[index].status = .queued
                items[index].tcxFilePath = nil
                cleaned += 1
                continue
            }

            guard let tcx = try? String(contentsOf: fileURL, encoding: .utf8) else {
                items[index].status = .failed
                items[index].lastError = "TCX guardado no es UTF-8 válido."
                items[index].retryCount += 1
                cleaned += 1
                continue
            }

            let trackpoints = tcx.components(separatedBy: "<Trackpoint>").count - 1
            if trackpoints < minTrackpoints {
                items[index].status = .skipped
                items[index].lastError = "TCX guardado sin puntos GPS suficientes; no se sube a Endurain."
                items[index].tcxFilePath = nil
                try? FileManager.default.removeItem(at: fileURL)
                cleaned += 1
            }
        }

        if cleaned > 0 { save() }
        return cleaned
    }

    func uploadedItems(namespaceID: String) -> [SyncQueueItem] {
        items.filter { $0.namespaceID == namespaceID && $0.status == .uploaded }
            .sorted { ($0.uploadedAt ?? $0.startDate) > ($1.uploadedAt ?? $1.startDate) }
    }

    func latestUploaded(namespaceID: String) -> SyncQueueItem? {
        uploadedItems(namespaceID: namespaceID).first
    }

    func isUploaded(namespaceID: String, uuid: String) -> Bool {
        items.first(where: { $0.namespaceID == namespaceID && $0.workoutUUID == uuid })?.status == .uploaded
    }

    func item(namespaceID: String, uuid: String) -> SyncQueueItem? {
        items.first(where: { $0.namespaceID == namespaceID && $0.workoutUUID == uuid })
    }

    func legacyItems() -> [SyncQueueItem] {
        items.filter(\.isLegacy)
    }

    func item(forTaskIdentifier taskIdentifier: Int) -> SyncQueueItem? {
        items.first(where: { $0.backgroundTaskIdentifier == taskIdentifier })
    }

    func activeBackgroundTaskIdentifiers() -> Set<Int> {
        Set(items.compactMap { $0.backgroundTaskIdentifier })
    }

    func reconcileUploadingItems(activeTaskIdentifiers: Set<Int>, staleAfter seconds: TimeInterval = 30 * 60) {
        restoreImportReceipts()
        var changed = false
        let now = Date()
        for i in items.indices {
            guard items[i].status == .uploading, items[i].importJobID == nil else { continue }
            if let uploadStartedAt = items[i].uploadStartedAt,
               now.timeIntervalSince(uploadStartedAt) < seconds {
                continue
            }
            if let namespace = items[i].namespaceID,
               ingestionReceipts.exists(scope: namespace, filename: uploadFilename(items[i].workoutUUID)) {
                if let taskID = items[i].backgroundTaskIdentifier, activeTaskIdentifiers.contains(taskID) {
                    continue
                }
                // An unresolved durable intent must not silently become another POST.
                items[i].backgroundTaskIdentifier = nil
                items[i].lastError = EndurainClientError.importStateUnavailable.localizedDescription
                changed = true
                continue
            }
            guard let taskID = items[i].backgroundTaskIdentifier else {
                items[i].status = items[i].tcxFilePath == nil ? .queued : .readyToUpload
                items[i].uploadStartedAt = nil
                changed = true
                continue
            }
            if !activeTaskIdentifiers.contains(taskID) {
                items[i].status = items[i].tcxFilePath == nil ? .queued : .readyToUpload
                items[i].backgroundTaskIdentifier = nil
                items[i].multipartFilePath = nil
                items[i].uploadStartedAt = nil
                changed = true
            }
        }
        if changed { save() }
    }

    func pendingCount(namespaceID: String) -> Int {
        pendingItems(namespaceID: namespaceID).count
    }

    func failedCount(namespaceID: String) -> Int {
        items.filter { $0.namespaceID == namespaceID && $0.status == .failed }.count
    }

    func skippedCount(namespaceID: String) -> Int {
        items.filter { $0.namespaceID == namespaceID && $0.status == .skipped }.count
    }

    func uploadingCount(namespaceID: String) -> Int {
        items.filter { $0.namespaceID == namespaceID && $0.status == .uploading }.count
    }

    var totalCount: Int { items.count }

    // MARK: - Reset items that got stuck mid-flight on previous launch

    /// Al arrancar la app, los items en estado generating/uploading no terminaron.
    /// Los reponemos a queued para que se reintenten.
    func resetInFlightItems() {
        var changed = false
        for i in items.indices {
            if items[i].status == .generating {
                items[i].status = .queued
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Private

    private func uploadFilename(_ uuid: String) -> String { "apple-health-\(uuid.lowercased()).tcx" }

    private func restoreImportReceipts() {
        for i in items.indices {
            guard items[i].status != .uploaded, items[i].status != .skipped,
                  items[i].importJobID == nil, let namespace = items[i].namespaceID else { continue }
            let filename = uploadFilename(items[i].workoutUUID)
            guard ingestionReceipts.exists(scope: namespace, filename: filename) else { continue }
            if let jobID = try? ingestionReceipts.jobID(scope: namespace, filename: filename) {
                items[i].importJobID = jobID
                items[i].status = .uploading
                items[i].backgroundTaskIdentifier = nil
                items[i].multipartFilePath = nil
                items[i].uploadStartedAt = nil
            } else if items[i].status != .failed {
                items[i].status = .uploading
                items[i].lastError = EndurainClientError.importStateUnavailable.localizedDescription
            }
        }
    }

    @discardableResult
    private func mutate(namespaceID: String, uuid: String, transform: (inout SyncQueueItem) -> Void) -> Bool {
        guard let idx = items.firstIndex(where: { $0.namespaceID == namespaceID && $0.workoutUUID == uuid }) else { return false }
        transform(&items[idx])
        return save()
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        if contents.isEmpty {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func clearDirectoryContents(_ directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isLikelySameActivity(
        _ item: SyncQueueItem,
        startDate: Date,
        activityTypeName: String,
        durationSeconds: Double,
        distanceMeters: Double?
    ) -> Bool {
        guard item.activityTypeName == activityTypeName else { return false }

        let startDelta = abs(item.startDate.timeIntervalSince(startDate))
        guard startDelta <= DuplicateTolerance.startDateSeconds else { return false }

        let durationDelta = abs(item.durationSeconds - durationSeconds)
        let maxDurationDelta = max(
            DuplicateTolerance.durationSeconds,
            max(item.durationSeconds, durationSeconds) * DuplicateTolerance.durationRatio
        )
        guard durationDelta <= maxDurationDelta else { return false }

        switch (item.distanceMeters, distanceMeters) {
        case let (.some(existing), .some(incoming)):
            let distanceDelta = abs(existing - incoming)
            let maxDistanceDelta = max(
                DuplicateTolerance.distanceMeters,
                max(existing, incoming) * DuplicateTolerance.distanceRatio
            )
            return distanceDelta <= maxDistanceDelta
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}
