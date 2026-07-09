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

// MARK: - SyncStatus

enum SyncStatus: String, Codable {
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

    // Identifiable — usa workoutUUID como ID
    var id: String { workoutUUID }
}

// MARK: - SyncQueueStore

final class SyncQueueStore {

    // MARK: - File paths

    private static let appSupportSubdir = "EndurainAppleUploader"
    private static let queueFilename    = "sync-queue.json"
    private static let tcxQueueSubdir   = "TCXQueue"

    private let queueFileURL: URL
    let tcxQueueDirectoryURL: URL

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

    init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let subdir = appSupport.appendingPathComponent(Self.appSupportSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

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
        } catch {
            print("[SyncQueueStore] Error al cargar cola: \(error). Empezando con cola vacía.")
            items = []
        }
    }

    // MARK: - Save (escritura atómica)

    func save() {
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
        } catch {
            print("[SyncQueueStore] Error al guardar cola: \(error)")
        }
    }

    // MARK: - Upsert

    /// Añade el workout a la cola si no existe, o lo ignora si ya está.
    /// Nunca regresa a queued un item que ya está uploaded.
    func upsertWorkout(
        uuid: String,
        startDate: Date,
        endDate: Date,
        activityTypeName: String,
        durationSeconds: Double,
        distanceMeters: Double?,
        serverURL: String
    ) {
        // Si ya existe, no hacer nada (preserva estado actual)
        if items.contains(where: { $0.workoutUUID == uuid }) { return }

        let item = SyncQueueItem(
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
            serverURL: serverURL,
            fileHash: nil,
            backgroundTaskIdentifier: nil,
            multipartFilePath: nil,
            uploadStartedAt: nil,
            createdAt: Date()
        )
        items.append(item)
        save()
    }

    // MARK: - Status transitions

    func markGenerating(uuid: String) {
        mutate(uuid: uuid) {
            $0.status = .generating
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func markReadyToUpload(uuid: String, tcxFilePath: String, fileHash: String? = nil) {
        mutate(uuid: uuid) {
            $0.status = .readyToUpload
            $0.tcxFilePath = tcxFilePath
            $0.fileHash = fileHash
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func markUploading(uuid: String, taskIdentifier: Int? = nil, multipartFilePath: String? = nil) {
        mutate(uuid: uuid) {
            $0.status = .uploading
            $0.backgroundTaskIdentifier = taskIdentifier
            $0.multipartFilePath = multipartFilePath
            $0.uploadStartedAt = Date()
        }
    }

    func markUploaded(uuid: String, serverURL: String) {
        mutate(uuid: uuid) {
            $0.status = .uploaded
            $0.uploadedAt = Date()
            $0.serverURL = serverURL
            $0.lastError = nil
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func markSkipped(uuid: String, reason: String) {
        mutate(uuid: uuid) {
            $0.status = .skipped
            $0.lastError = reason
            $0.uploadStartedAt = nil
        }
    }

    func markFailed(uuid: String, error: String) {
        mutate(uuid: uuid) {
            $0.status = .failed
            $0.lastError = error
            $0.retryCount += 1
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    func requeue(uuid: String, error: String? = nil) {
        mutate(uuid: uuid) {
            $0.status = $0.tcxFilePath == nil ? .queued : .readyToUpload
            $0.lastError = error
            $0.backgroundTaskIdentifier = nil
            $0.multipartFilePath = nil
            $0.uploadStartedAt = nil
        }
    }

    // Re-encola un item failed para volver a intentarlo
    func requeueFailed(uuid: String) {
        mutate(uuid: uuid) {
            guard $0.status == .failed else { return }
            $0.status = .queued
            $0.lastError = nil
        }
    }

    // MARK: - Queries

    func pendingItems() -> [SyncQueueItem] {
        items.filter { $0.status == .queued || $0.status == .readyToUpload }
            .sorted { $0.startDate < $1.startDate }
    }

    func failedItems() -> [SyncQueueItem] {
        items.filter { $0.status == .failed }
            .sorted { $0.startDate < $1.startDate }
    }

    func skippedItems() -> [SyncQueueItem] {
        items.filter { $0.status == .skipped }
            .sorted { $0.startDate < $1.startDate }
    }

    @discardableResult
    func cleanupInvalidReadyToUploadTCX(minTrackpoints: Int = 20) -> Int {
        var cleaned = 0

        for index in items.indices {
            guard items[index].status == .readyToUpload,
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

    func uploadedItems() -> [SyncQueueItem] {
        items.filter { $0.status == .uploaded }
            .sorted { ($0.uploadedAt ?? $0.startDate) > ($1.uploadedAt ?? $1.startDate) }
    }

    func latestUploaded() -> SyncQueueItem? {
        uploadedItems().first
    }

    func isUploaded(uuid: String) -> Bool {
        items.first(where: { $0.workoutUUID == uuid })?.status == .uploaded
    }

    func item(for uuid: String) -> SyncQueueItem? {
        items.first(where: { $0.workoutUUID == uuid })
    }

    func item(forTaskIdentifier taskIdentifier: Int) -> SyncQueueItem? {
        items.first(where: { $0.backgroundTaskIdentifier == taskIdentifier })
    }

    func activeBackgroundTaskIdentifiers() -> Set<Int> {
        Set(items.compactMap { $0.backgroundTaskIdentifier })
    }

    func reconcileUploadingItems(activeTaskIdentifiers: Set<Int>, staleAfter seconds: TimeInterval = 30 * 60) {
        var changed = false
        let now = Date()
        for i in items.indices {
            guard items[i].status == .uploading else { continue }
            if let uploadStartedAt = items[i].uploadStartedAt,
               now.timeIntervalSince(uploadStartedAt) < seconds {
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

    var pendingCount: Int {
        items.filter { $0.status == .queued || $0.status == .readyToUpload }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }

    var skippedCount: Int {
        items.filter { $0.status == .skipped }.count
    }

    var uploadingCount: Int {
        items.filter { $0.status == .uploading }.count
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

    private func mutate(uuid: String, transform: (inout SyncQueueItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.workoutUUID == uuid }) else { return }
        transform(&items[idx])
        save()
    }
}
