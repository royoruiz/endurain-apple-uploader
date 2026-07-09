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
    private let tcxLogPreviewLimit = 1_500
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
            print("[SyncEngine] Cleaned \(cleaned) invalid TCX files from the persistent queue.")
        }
        refreshCounts()
    }

    // MARK: - Public API

    /// Punto de entrada al abrir la app: escanea + sube pendientes automáticamente.
    func startSync() async {
        await syncAutomatically(scanHealthKit: true)
    }

    /// Escanea HealthKit y programa el siguiente lote. Los lotes posteriores se lanzan solos
    /// cuando terminan las subidas en background.
    func syncAutomatically(scanHealthKit: Bool = true) async {
        guard !isSyncInProgress else { return }
        isSyncInProgress = true
        defer { isSyncInProgress = false }

        lastError = nil

        await backgroundUploadService.reconnect()
        refreshCounts()

        if queue.uploadingCount > 0 {
            syncState = .backgroundUploading(count: queue.uploadingCount)
            return
        }

        if scanHealthKit {
            await scanAllWorkouts()
        }

        requeueFailedItemsForRetry()

        let cleaned = queue.cleanupInvalidReadyToUploadTCX()
        if cleaned > 0 {
            print("[SyncEngine] Cleaned \(cleaned) invalid TCX files before syncing.")
            refreshCounts()
        }

        let pending = queue.pendingItems()
        guard !pending.isEmpty else {
            syncState = .synced
            refreshCounts()
            return
        }

        await processPendingItems(pending)
    }

    // MARK: - Scan

    private func scanAllWorkouts() async {
        syncState = .scanning

        guard case .available = hkService.permissionStatus else {
            syncState = .idle
            return
        }

        do {
            let workouts = try await hkService.fetchWorkoutsSinceBeginning()
            let serverURL = settings.serverURL

            for workout in workouts {
                let uuid = workout.uuid.uuidString
                // Si ya está uploaded, ignorar
                if queue.isUploaded(uuid: uuid) { continue }
                // Si ya existe en cualquier otro estado, no duplicar
                if queue.item(for: uuid) != nil { continue }
                // Nuevo: encolar
                queue.upsertWorkout(
                    uuid: uuid,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    activityTypeName: workout.workoutActivityType.displayName,
                    durationSeconds: workout.duration,
                    distanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                    serverURL: serverURL
                )
            }
            refreshCounts()
        } catch {
            print("[SyncEngine] Error en scan: \(error)")
            // No fatal — continuamos con lo que haya en cola
        }
    }

    // MARK: - Process queue

    private func processPendingItems(_ items: [SyncQueueItem]) async {
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

            guard let currentItem = queue.item(for: item.workoutUUID),
                  currentItem.status == .queued || currentItem.status == .readyToUpload else {
                continue
            }

            inspectedItems += 1
            current += 1
            let name = currentItem.activityTypeName
            syncState = .uploading(name: name, current: current, total: total)

            do {
                let tcxFileURL = queue.tcxQueueDirectoryURL
                    .appendingPathComponent("\(item.workoutUUID).tcx")

                let tcxData: Data
                if currentItem.status == .readyToUpload,
                   FileManager.default.fileExists(atPath: tcxFileURL.path) {
                    tcxData = try Data(contentsOf: tcxFileURL)
                    if let tcxString = String(data: tcxData, encoding: .utf8) {
                        if let rejectionReason = savedTCXRejectionReason(tcxString, item: currentItem) {
                            print("[SyncEngine] Skipping \(item.workoutUUID): \(rejectionReason)")
                            queue.markSkipped(
                                uuid: item.workoutUUID,
                                reason: rejectionReason
                            )
                            try? FileManager.default.removeItem(at: tcxFileURL)
                            refreshCounts()
                            continue
                        }

                        logTCXDebug(tcxString, fileURL: tcxFileURL, uuid: item.workoutUUID)
                    } else {
                        print("[SyncEngine][Debug] existing-tcx uuid=\(item.workoutUUID) file=\(tcxFileURL.path) bytes=\(tcxData.count) not valid UTF-8")
                        queue.markFailed(uuid: item.workoutUUID, error: "TCX guardado no es UTF-8 válido.")
                        refreshCounts()
                        continue
                    }
                } else {
                    // 1. Recuperar HKWorkout nativo
                    guard let workoutUUID = UUID(uuidString: item.workoutUUID),
                          let workout = try await hkService.fetchHKWorkout(uuid: workoutUUID) else {
                        queue.markFailed(uuid: item.workoutUUID, error: "No se encontró el entrenamiento en HealthKit.")
                        refreshCounts()
                        continue
                    }

                    // 2. Marcar generating
                    queue.markGenerating(uuid: item.workoutUUID)
                    syncState = .generating(name: name)

                    // 3a. Leer ruta y pulso completos (awaitable, HealthKit callbacks son thread-safe)
                    let detail: WorkoutDetail
                    do {
                        detail = try await hkService.buildWorkoutDetail(for: workout)
                    } catch {
                        queue.markFailed(uuid: item.workoutUUID, error: error.localizedDescription)
                        refreshCounts()
                        continue
                    }

                    if let rejectionReason = routeRejectionReason(for: detail) {
                        logWorkoutDetail(detail, uuid: item.workoutUUID, stage: "skip-invalid-route")
                        queue.markSkipped(
                            uuid: item.workoutUUID,
                            reason: rejectionReason
                        )
                        refreshCounts()
                        continue
                    }

                    // 3b. Generar XML TCX en Task.detached (puro, sin estado de UI, puede ser costoso)
                    let tcxString: String = await Task.detached(priority: .userInitiated) {
                        TCXGenerator.generate(from: detail)
                    }.value

                    guard let data = tcxString.data(using: .utf8) else {
                        queue.markFailed(uuid: item.workoutUUID, error: "Error al codificar el TCX.")
                        refreshCounts()
                        continue
                    }

                    // 4. Guardar TCX en Application Support/TCXQueue/<uuid>.tcx
                    try tcxString.write(to: tcxFileURL, atomically: true, encoding: .utf8)
                    logWorkoutDetail(detail, uuid: item.workoutUUID, stage: "generated-tcx")
                    logTCXDebug(tcxString, fileURL: tcxFileURL, uuid: item.workoutUUID)

                    let relativePath = "\(item.workoutUUID).tcx"
                    queue.markReadyToUpload(uuid: item.workoutUUID, tcxFilePath: relativePath)
                    tcxData = data
                }

                // 5. Programar subida background. El delegate confirmará uploaded tras HTTP 2xx.
                syncState = .backgroundUploading(count: uploadAttempts + 1)

                print("[SyncEngine] Scheduling background upload \(item.workoutUUID) bytes=\(tcxData.count) tcxFile=\(tcxFileURL.path)")
                let scheduled = try backgroundUploadService.scheduleUpload(
                    uuid: item.workoutUUID,
                    tcxFileURL: tcxFileURL,
                    serverURL: settings.serverURL,
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
                let debugTCXPath = queue.tcxQueueDirectoryURL
                    .appendingPathComponent("\(item.workoutUUID).tcx")
                    .path
                print("[SyncEngine] Upload failed for \(item.workoutUUID): \(msg)")
                print("[SyncEngine] Kept TCX for debug at: \(debugTCXPath)")
                refreshCounts()
                // Para 401/403 (API key inválida) — detener la cola, no tiene sentido continuar
                if case .unauthorized = error {
                    queue.requeue(uuid: item.workoutUUID, error: msg)
                    let authMsg = "API key no autorizada. Revisa la configuración."
                    syncState = .error(authMsg)
                    lastError = authMsg
                    return
                }
                if case .duplicate(_) = error {
                    queue.markUploaded(uuid: item.workoutUUID, serverURL: settings.serverURL)
                    lastUploadedItem = queue.latestUploaded()
                    refreshCounts()
                    continue
                }
                if case .rateLimited(_) = error {
                    queue.requeue(uuid: item.workoutUUID, error: msg)
                    syncState = .error("Endurain limitó las peticiones. Espera unos minutos y reintenta.")
                    lastError = msg
                    return
                }
                if case .serverError(_, _) = error {
                    queue.markFailed(uuid: item.workoutUUID, error: msg)
                    syncState = .error("Endurain devolvió un error de servidor. Se ha detenido la sincronización.")
                    lastError = msg
                    return
                }
                queue.markFailed(uuid: item.workoutUUID, error: msg)
                refreshCounts()
            } catch {
                let msg = error.localizedDescription
                print("[SyncEngine] Error inesperado para \(item.workoutUUID): \(msg)")
                queue.markFailed(uuid: item.workoutUUID, error: msg)
                refreshCounts()
            }
        }

        // Tras procesar todos: calcular estado final
        let remainingPending = queue.pendingCount
        let remainingFailed = queue.failedCount
        let remainingSkipped = queue.skippedCount
        let remainingUploading = queue.uploadingCount

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
        pendingCount = queue.pendingCount
        failedCount = queue.failedCount
        skippedCount = queue.skippedCount
        uploadingCount = queue.uploadingCount
        if lastUploadedItem == nil {
            lastUploadedItem = queue.latestUploaded()
        }
    }

    private func refreshIdleStateAfterBackgroundEvent() {
        guard !isSyncInProgress else { return }
        if queue.uploadingCount > 0 {
            syncState = .backgroundUploading(count: queue.uploadingCount)
        } else if queue.pendingCount > 0 {
            syncState = .idle
            lastError = "Quedan \(queue.pendingCount) entrenamiento(s) pendientes. La app continuará automáticamente."
        } else if queue.failedCount > 0 {
            syncState = .error("\(queue.failedCount) entrenamiento(s) no se pudieron subir.")
        } else {
            syncState = .synced
            lastUploadedItem = queue.latestUploaded()
        }
    }

    private func scheduleAutomaticContinuationIfNeeded() {
        guard !isSyncInProgress else { return }
        guard queue.uploadingCount == 0, queue.pendingCount > 0 else { return }
        guard automaticContinuationTask == nil else { return }

        automaticContinuationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.automaticContinuationTask = nil
            await self?.syncAutomatically(scanHealthKit: false)
        }
    }

    private func requeueFailedItemsForRetry() {
        for failed in queue.failedItems() {
            queue.requeue(uuid: failed.workoutUUID, error: failed.lastError)
        }
        refreshCounts()
    }

    private func logWorkoutDetail(_ detail: WorkoutDetail, uuid: String, stage: String) {
        let first = detail.routePoints.first
        let last = detail.routePoints.last
        let distance = detail.totalDistanceMeters.map { String(format: "%.2f", $0) } ?? "nil"
        let kcal = detail.activeEnergyKcal.map { String(format: "%.0f", $0) } ?? "nil"

        print("""
        [SyncEngine][Debug] \(stage) uuid=\(uuid)
          type=\(detail.activityTypeName) hkType=\(detail.activityType.rawValue)
          start=\(detail.startDate) end=\(detail.endDate) duration=\(String(format: "%.2f", detail.durationSeconds))s
          distanceMeters=\(distance) activeEnergyKcal=\(kcal)
          routePoints=\(detail.routePoints.count) heartRateSamples=\(detail.heartRateSamples.count)
          firstPoint=\(debugPoint(first))
          lastPoint=\(debugPoint(last))
        """)
    }

    private func logTCXDebug(_ tcx: String, fileURL: URL, uuid: String) {
        let preview = String(tcx.prefix(tcxLogPreviewLimit))
            .replacingOccurrences(of: "\n", with: "\\n")
        let trackpointCount = tcx.components(separatedBy: "<Trackpoint>").count - 1
        let hasActivity = tcx.contains("<Activity Sport=")
        let hasLap = tcx.contains("<Lap StartTime=")
        let hasTrack = tcx.contains("<Track>")

        print("""
        [SyncEngine][Debug] tcx uuid=\(uuid)
          file=\(fileURL.path)
          characters=\(tcx.count) utf8Bytes=\(tcx.utf8.count)
          trackpoints=\(trackpointCount) hasActivity=\(hasActivity) hasLap=\(hasLap) hasTrack=\(hasTrack)
          preview=\(preview)
        """)
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

    private func debugPoint(_ point: RoutePoint?) -> String {
        guard let point else { return "nil" }
        return String(
            format: "time=%@ lat=%.7f lon=%.7f alt=%@ hAcc=%@",
            String(describing: point.timestamp),
            point.latitude,
            point.longitude,
            point.altitude.map { String(format: "%.2f", $0) } ?? "nil",
            point.horizontalAccuracy.map { String(format: "%.2f", $0) } ?? "nil"
        )
    }

    private static let tcxDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
