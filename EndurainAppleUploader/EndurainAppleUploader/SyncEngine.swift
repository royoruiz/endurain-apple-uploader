//
//  SyncEngine.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//
//  Orquestador principal de sincronización.
//
//  Responsabilidades:
//  - Escanear todos los entrenamientos de Apple Salud desde 2000-01-01.
//  - Encolar los no subidos en SyncQueueStore.
//  - Generar TCX para cada uno (en tarea detached para no bloquear MainActor).
//  - Subirlos a Endurain usando EndurainClient.
//  - Exponer estado observable simple para la UI.
//
//  Diseño de concurrencia:
//  - SyncEngine es @MainActor para que su estado sea siempre visible desde la UI.
//  - La generación TCX (potencialmente pesada) ocurre en Task.detached { } o en
//    servicios no @MainActor, y vuelve al MainActor solo para actualizar estado.
//

import Foundation
import HealthKit
import Observation
import os

// MARK: - EngineSyncState

enum EngineSyncState: Equatable {
    case idle
    case scanning
    case generating(name: String)
    case uploading(name: String, current: Int, total: Int)
    case backgroundUploading(count: Int)
    case synced
    case error(String)

    var isWorking: Bool {
        switch self {
        case .scanning, .generating, .uploading, .backgroundUploading: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:              return "Listo"
        case .scanning:          return "Buscando entrenamientos..."
        case .generating(let n): return "Preparando \(n)..."
        case .uploading(let n, let cur, let tot):
            return tot > 1
                ? "Sincronizando \(cur)/\(tot): \(n)..."
                : "Subiendo \(n)..."
        case .backgroundUploading(let count):
            return count > 1 ? "Subiendo en segundo plano (\(count))..." : "Subiendo en segundo plano..."
        case .synced:            return "Sincronizado"
        case .error:             return "Error de sincronización"
        }
    }
}

// MARK: - SyncEngine

@Observable
@MainActor
final class SyncEngine {

    // MARK: - Observable state (UI)

    var syncState: EngineSyncState = .idle
    var pendingCount: Int = 0
    var failedCount: Int = 0
    var skippedCount: Int = 0
    var uploadingCount: Int = 0
    var lastUploadedItem: SyncQueueItem? = nil
    var lastError: String? = nil

    // MARK: - Dependencies (inyectadas)

    private let hkService: HealthKitService
    private let queue: SyncQueueStore
    private let settings: SettingsStore
    private let backgroundUploadService: BackgroundUploadService

    private var isSyncInProgress = false
    private var automaticContinuationTask: Task<Void, Never>?
    private let maxUploadsPerBatch = 10
    private let maxQueueItemsPerRun = 100
    private let uploadDelayNanoseconds: UInt64 = 2_000_000_000
    private let minimumRoutePoints = 20
    private let minimumRouteDurationSeconds: TimeInterval = 60
    private let minimumRouteCoverageRatio = 0.50

    // MARK: - Init

    init(
        hkService: HealthKitService,
        queue: SyncQueueStore,
        settings: SettingsStore,
        backgroundUploadService: BackgroundUploadService
    ) {
        self.hkService = hkService
        self.queue = queue
        self.settings = settings
        self.backgroundUploadService = backgroundUploadService
        self.backgroundUploadService.onQueueChanged = { [weak self] in
            self?.refreshCounts()
            self?.refreshIdleStateAfterBackgroundEvent()
            self?.scheduleAutomaticContinuationIfNeeded()
        }
        // Cargar cola persistida y resetear items que quedaron en vuelo
        queue.load()
        queue.resetInFlightItems()
        let cleaned = queue.cleanupInvalidReadyToUploadTCX()
        if cleaned > 0 {
            AppLog.sync.info("Cleaned \(cleaned) invalid queued TCX file(s) on startup")
        }
        refreshCounts()
    }

    // MARK: - Public API

    /// Punto de entrada al abrir la app: escanea + sube pendientes automáticamente.
    func startSync() async {
        await syncAutomatically(scanHealthKit: true)
    }

    func handleConfigurationCleared() {
        automaticContinuationTask?.cancel()
        automaticContinuationTask = nil
        isSyncInProgress = false
        syncState = .idle
        lastError = nil
        lastUploadedItem = nil
        refreshCounts()
    }

    /// Escanea HealthKit y programa el siguiente lote. Los lotes posteriores se lanzan solos
    /// cuando terminan las subidas en background.
    func syncAutomatically(scanHealthKit: Bool = true) async {
        guard !isSyncInProgress else { return }
        isSyncInProgress = true
        defer {
            isSyncInProgress = false
            if let identity = try? settings.currentIdentity(),
               !queue.importingItems(namespaceID: identity.namespaceID).isEmpty {
                scheduleAutomaticContinuationIfNeeded()
            }
        }

        lastError = nil

        await backgroundUploadService.reconnect()
        refreshCounts()

        let identity: EndurainConfigurationIdentity
        do {
            identity = try settings.currentIdentity()
        } catch {
            syncState = .error(error.localizedDescription)
            lastError = error.localizedDescription
            return
        }

        if !queue.importingItems(namespaceID: identity.namespaceID).isEmpty {
            do {
                guard let apiKey = try settings.readAPIKey(), !apiKey.isEmpty else {
                    throw EndurainClientError.unauthorized
                }
                await ActivityImportMonitor(queue: queue).refresh(
                    namespaceID: identity.namespaceID, serverURL: identity.normalizedServerURL, apiKey: apiKey
                )
                refreshCounts()
            } catch {
                lastError = "Unable to check accepted imports. Review the API key configuration."
            }
        }

        if queue.uploadingCount(namespaceID: identity.namespaceID) > 0 {
            if let error = queue.unconfirmedUploadError(namespaceID: identity.namespaceID) {
                syncState = .error(error)
                lastError = error
            } else {
                syncState = .backgroundUploading(count: queue.uploadingCount(namespaceID: identity.namespaceID))
            }
            return
        }

        if scanHealthKit {
            await scanAllWorkouts(identity: identity)
        }

        requeueFailedItemsForRetry(namespaceID: identity.namespaceID)

        let cleaned = queue.cleanupInvalidReadyToUploadTCX()
        if cleaned > 0 {
            AppLog.sync.info("Cleaned \(cleaned) invalid queued TCX file(s) before syncing")
            refreshCounts()
        }

        let pending = queue.pendingItems(namespaceID: identity.namespaceID)
        guard !pending.isEmpty else {
            refreshCounts()
            if failedCount > 0 {
                syncState = .error("An activity could not be imported.")
                lastError = queue.failedItems(namespaceID: identity.namespaceID).first?.lastError
            } else {
                syncState = .synced
            }
            return
        }

        await processPendingItems(pending, identity: identity)
    }

    // MARK: - Scan

    private func scanAllWorkouts(identity: EndurainConfigurationIdentity) async {
        syncState = .scanning

        guard case .available = hkService.permissionStatus else {
            syncState = .idle
            return
        }

        do {
            let workouts = try await hkService.fetchWorkoutsSinceBeginning()
            for workout in workouts {
                let uuid = workout.uuid.uuidString
                // Si ya está uploaded, ignorar
                if queue.isUploaded(namespaceID: identity.namespaceID, uuid: uuid) { continue }
                // Si ya existe en cualquier otro estado, no duplicar
                if queue.item(namespaceID: identity.namespaceID, uuid: uuid) != nil { continue }
                if queue.likelyDuplicate(
                    namespaceID: identity.namespaceID,
                    uuid: uuid,
                    startDate: workout.startDate,
                    activityTypeName: workout.workoutActivityType.displayName,
                    durationSeconds: workout.duration,
                    distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
                ) != nil {
                    continue
                }
                // Nuevo: encolar
                queue.upsertWorkout(
                    namespaceID: identity.namespaceID,
                    normalizedServerURL: identity.normalizedServerURL,
                    normalizedUserIdentifier: identity.normalizedUserIdentifier,
                    uuid: uuid,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    activityTypeName: workout.workoutActivityType.displayName,
                    durationSeconds: workout.duration,
                    distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
                )
            }
            refreshCounts()
        } catch {
            AppLog.sync.error("HealthKit scan failed: \(error.localizedDescription, privacy: .private)")
            // No fatal — continuamos con lo que haya en cola
        }
    }

    // MARK: - Process queue

    private func processPendingItems(_ items: [SyncQueueItem], identity: EndurainConfigurationIdentity) async {
        let total = items.count
        var current = 0
        var uploadAttempts = 0
        var inspectedItems = 0

        let resolvedAPIKey: String
        do {
            guard let k = try settings.readAPIKey(), !k.isEmpty else {
                syncState = .error("No se encontró la API key. Revisa la configuración.")
                lastError = "No se encontró la API key."
                return
            }
            resolvedAPIKey = k
        } catch {
            let msg = "Error al leer la API key: \(error.localizedDescription)"
            syncState = .error(msg)
            lastError = msg
            return
        }

        for item in items {
            if uploadAttempts >= maxUploadsPerBatch { break }
            if inspectedItems >= maxQueueItemsPerRun { break }

            guard let currentItem = queue.item(namespaceID: identity.namespaceID, uuid: item.workoutUUID),
                  currentItem.status == .queued || currentItem.status == .readyToUpload else {
                continue
            }

            inspectedItems += 1
            current += 1
            let name = currentItem.activityTypeName
            syncState = .uploading(name: name, current: current, total: total)

            do {
                if queue.likelyDuplicate(
                    of: currentItem,
                    restrictedTo: [.uploaded, .uploading, .readyToUpload]
                ) != nil {
                    queue.markSkipped(
                        namespaceID: identity.namespaceID,
                        uuid: item.workoutUUID,
                        reason: "Duplicado probable de una actividad ya sincronizada."
                    )
                    refreshCounts()
                    continue
                }

                let namespaceTCXDirectoryURL = queue.tcxQueueDirectoryURL
                    .appendingPathComponent(identity.namespaceID, isDirectory: true)
                try FileManager.default.createDirectory(at: namespaceTCXDirectoryURL, withIntermediateDirectories: true)
                let tcxFileURL = namespaceTCXDirectoryURL
                    .appendingPathComponent("\(item.workoutUUID).tcx")

                let tcxData: Data
                if currentItem.status == .readyToUpload,
                   FileManager.default.fileExists(atPath: tcxFileURL.path) {
                    tcxData = try Data(contentsOf: tcxFileURL)
                    if let tcxString = String(data: tcxData, encoding: .utf8) {
                        if let rejectionReason = savedTCXRejectionReason(tcxString, item: currentItem) {
                            AppLog.sync.info("Skipping queued workout with invalid TCX: \(rejectionReason, privacy: .private)")
                            queue.markSkipped(
                                namespaceID: identity.namespaceID,
                                uuid: item.workoutUUID,
                                reason: rejectionReason
                            )
                            try? FileManager.default.removeItem(at: tcxFileURL)
                            refreshCounts()
                            continue
                        }

                    } else {
                        AppLog.sync.error("Queued TCX file is not valid UTF-8")
                        queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: "TCX guardado no es UTF-8 válido.")
                        refreshCounts()
                        continue
                    }
                } else {
                    // 1. Recuperar HKWorkout nativo
                    guard let workoutUUID = UUID(uuidString: item.workoutUUID),
                          let workout = try await hkService.fetchHKWorkout(uuid: workoutUUID) else {
                        queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: "No se encontró el entrenamiento en HealthKit.")
                        refreshCounts()
                        continue
                    }

                    // 2. Marcar generating
                    queue.markGenerating(namespaceID: identity.namespaceID, uuid: item.workoutUUID)
                    syncState = .generating(name: name)

                    // 3a. Leer ruta y pulso completos (awaitable, HealthKit callbacks son thread-safe)
                    let detail: WorkoutDetail
                    do {
                        detail = try await hkService.buildWorkoutDetail(for: workout)
                    } catch {
                        queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: error.localizedDescription)
                        refreshCounts()
                        continue
                    }

                    if let rejectionReason = routeRejectionReason(for: detail) {
                        queue.markSkipped(
                            namespaceID: identity.namespaceID,
                            uuid: item.workoutUUID,
                            reason: rejectionReason
                        )
                        refreshCounts()
                        continue
                    }

                    // 3b. Generar XML TCX en Task.detached (puro, sin estado de UI, puede ser costoso)
                    let tcxString: String = await {
                        await Task.detached(priority: .userInitiated) {
                            await TCXGenerator.generate(from: detail)
                        }.value
                    }()

                    guard let data = tcxString.data(using: .utf8) else {
                        queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: "Error al codificar el TCX.")
                        refreshCounts()
                        continue
                    }

                    // 4. Guardar TCX en Application Support/TCXQueue/<uuid>.tcx
                    try tcxString.write(to: tcxFileURL, atomically: true, encoding: .utf8)
                    let relativePath = identity.namespaceID + "/" + item.workoutUUID + ".tcx"
                    queue.markReadyToUpload(namespaceID: identity.namespaceID, uuid: item.workoutUUID, tcxFilePath: relativePath)
                    tcxData = data
                }

                // Completion is confirmed only after the accepted import job succeeds.
                syncState = .backgroundUploading(count: uploadAttempts + 1)

                let scheduled = try backgroundUploadService.scheduleUpload(
                    namespaceID: identity.namespaceID,
                    uuid: item.workoutUUID,
                    tcxFileURL: tcxFileURL,
                    serverURL: identity.normalizedServerURL,
                    apiKey: resolvedAPIKey
                )
                if scheduled {
                    uploadAttempts += 1
                }
                refreshCounts()

                if current < total {
                    try? await Task.sleep(nanoseconds: uploadDelayNanoseconds)
                }

            } catch let error as EndurainClientError {
                let msg = error.errorDescription ?? error.localizedDescription
                AppLog.sync.error("Upload scheduling failed: \(msg, privacy: .private)")
                refreshCounts()
                // Para 401/403 (API key inválida) — detener la cola, no tiene sentido continuar
                if case .unauthorized = error {
                    queue.requeue(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: msg)
                    let authMsg = "API key is not authorized for activity upload or is invalid."
                    syncState = .error(authMsg)
                    lastError = authMsg
                    return
                }
                if case .duplicate(_) = error {
                    queue.markSkipped(
                        namespaceID: identity.namespaceID,
                        uuid: item.workoutUUID,
                        reason: "skippedExistingServerActivity"
                    )
                    refreshCounts()
                    continue
                }
                if case .rateLimited(_) = error {
                    queue.requeue(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: msg)
                    syncState = .error("Endurain limitó las peticiones. Espera unos minutos y reintenta.")
                    lastError = msg
                    return
                }
                if case .serverError(_, _) = error {
                    queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: msg)
                    syncState = .error("Endurain devolvió un error de servidor. Se ha detenido la sincronización.")
                    lastError = msg
                    return
                }
                queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: msg)
                refreshCounts()
            } catch {
                let msg = error.localizedDescription
                AppLog.sync.error("Unexpected sync error: \(msg, privacy: .private)")
                queue.markFailed(namespaceID: identity.namespaceID, uuid: item.workoutUUID, error: msg)
                refreshCounts()
            }
        }

        // Tras procesar todos: calcular estado final
        let remainingPending = queue.pendingCount(namespaceID: identity.namespaceID)
        let remainingFailed = queue.failedCount(namespaceID: identity.namespaceID)
        let remainingSkipped = queue.skippedCount(namespaceID: identity.namespaceID)
        let remainingUploading = queue.uploadingCount(namespaceID: identity.namespaceID)

        if remainingUploading > 0 {
            syncState = .backgroundUploading(count: remainingUploading)
        } else if remainingPending == 0 && remainingFailed == 0 {
            syncState = .synced
        } else if remainingPending == 0 && remainingFailed > 0 {
            syncState = .error("\(remainingFailed) entrenamiento(s) no se pudieron subir.")
            lastError = "\(remainingFailed) entrenamiento(s) fallaron. La app los reintentará automáticamente."
        } else if remainingPending > 0 {
            syncState = .idle
            lastError = "Quedan \(remainingPending) entrenamiento(s) pendientes. La app continuará automáticamente."
            scheduleAutomaticContinuationIfNeeded()
        } else if remainingSkipped > 0 {
            syncState = .synced
        } else {
            syncState = .synced
        }
        refreshCounts()
    }

    // MARK: - Helpers

    private func refreshCounts() {
        guard let identity = try? settings.currentIdentity() else {
            pendingCount = 0
            failedCount = 0
            skippedCount = 0
            uploadingCount = 0
            lastUploadedItem = nil
            return
        }
        pendingCount = queue.pendingCount(namespaceID: identity.namespaceID)
        failedCount = queue.failedCount(namespaceID: identity.namespaceID)
        skippedCount = queue.skippedCount(namespaceID: identity.namespaceID)
        uploadingCount = queue.uploadingCount(namespaceID: identity.namespaceID)
        if let importError = queue.importingItems(namespaceID: identity.namespaceID).compactMap(\.lastError).first {
            lastError = importError
        }
        if lastUploadedItem == nil {
            lastUploadedItem = queue.latestUploaded(namespaceID: identity.namespaceID)
        }
    }

    private func refreshIdleStateAfterBackgroundEvent() {
        guard !isSyncInProgress else { return }
        guard let identity = try? settings.currentIdentity() else {
            syncState = .idle
            refreshCounts()
            return
        }
        if queue.uploadingCount(namespaceID: identity.namespaceID) > 0 {
            syncState = .backgroundUploading(count: queue.uploadingCount(namespaceID: identity.namespaceID))
        } else if queue.pendingCount(namespaceID: identity.namespaceID) > 0 {
            syncState = .idle
            lastError = "Quedan \(queue.pendingCount(namespaceID: identity.namespaceID)) entrenamiento(s) pendientes. La app continuará automáticamente."
        } else if queue.failedCount(namespaceID: identity.namespaceID) > 0 {
            syncState = .error("\(queue.failedCount(namespaceID: identity.namespaceID)) entrenamiento(s) no se pudieron subir.")
        } else {
            syncState = .synced
            lastUploadedItem = queue.latestUploaded(namespaceID: identity.namespaceID)
        }
    }

    private func scheduleAutomaticContinuationIfNeeded() {
        guard !isSyncInProgress else { return }
        guard let identity = try? settings.currentIdentity() else { return }
        let hasImports = !queue.importingItems(namespaceID: identity.namespaceID).isEmpty
        guard hasImports || (queue.uploadingCount(namespaceID: identity.namespaceID) == 0
                             && queue.pendingCount(namespaceID: identity.namespaceID) > 0) else { return }
        guard automaticContinuationTask == nil else { return }

        automaticContinuationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: hasImports ? 5_000_000_000 : 1_500_000_000)
            } catch { return }
            self?.automaticContinuationTask = nil
            await self?.syncAutomatically(scanHealthKit: false)
        }
    }

    private func requeueFailedItemsForRetry(namespaceID: String) {
        for failed in queue.failedItems(namespaceID: namespaceID) where failed.importJobID == nil {
            queue.requeue(namespaceID: namespaceID, uuid: failed.workoutUUID, error: failed.lastError)
        }
        refreshCounts()
    }

    private func tcxTrackpointCount(_ tcx: String) -> Int {
        tcx.components(separatedBy: "<Trackpoint>").count - 1
    }

    private func savedTCXRejectionReason(_ tcx: String, item: SyncQueueItem) -> String? {
        let trackpoints = tcxTrackpointCount(tcx)
        guard trackpoints >= minimumRoutePoints else {
            return "TCX guardado con ruta insuficiente: solo \(trackpoints) punto(s)."
        }

        let times = tcxTrackpointTimes(tcx)
        guard let first = times.first, let last = times.last else {
            return "TCX guardado sin tiempos de trackpoint."
        }

        let routeDuration = last.timeIntervalSince(first)
        guard routeDuration >= minimumRouteDurationSeconds else {
            return "TCX guardado con ruta parcial: solo cubre \(Int(routeDuration))s."
        }

        guard item.durationSeconds > 0 else {
            return "Duración del entrenamiento no válida."
        }

        let coverage = routeDuration / item.durationSeconds
        guard coverage >= minimumRouteCoverageRatio else {
            return String(
                format: "TCX guardado con ruta parcial: cubre %.0f%% del entrenamiento.",
                coverage * 100
            )
        }

        return nil
    }

    private func tcxTrackpointTimes(_ tcx: String) -> [Date] {
        var dates: [Date] = []
        var searchStart = tcx.startIndex

        while let openRange = tcx.range(of: "<Time>", range: searchStart..<tcx.endIndex),
              let closeRange = tcx.range(of: "</Time>", range: openRange.upperBound..<tcx.endIndex) {
            let value = String(tcx[openRange.upperBound..<closeRange.lowerBound])
            if let date = Self.tcxDateFormatter.date(from: value) {
                dates.append(date)
            }
            searchStart = closeRange.upperBound
        }

        return dates
    }

    private func routeRejectionReason(for detail: WorkoutDetail) -> String? {
        guard detail.routePoints.count >= minimumRoutePoints else {
            return "Ruta GPS insuficiente: solo \(detail.routePoints.count) punto(s)."
        }

        guard let first = detail.routePoints.first,
              let last = detail.routePoints.last else {
            return "Sin ruta GPS."
        }

        let routeDuration = last.timestamp.timeIntervalSince(first.timestamp)
        guard routeDuration >= minimumRouteDurationSeconds else {
            return "Ruta GPS parcial: solo cubre \(Int(routeDuration))s del entrenamiento."
        }

        guard detail.durationSeconds > 0 else {
            return "Duración del entrenamiento no válida."
        }

        let coverage = routeDuration / detail.durationSeconds
        guard coverage >= minimumRouteCoverageRatio else {
            return String(
                format: "Ruta GPS parcial: cubre %.0f%% del entrenamiento.",
                coverage * 100
            )
        }

        return nil
    }

    private static let tcxDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
