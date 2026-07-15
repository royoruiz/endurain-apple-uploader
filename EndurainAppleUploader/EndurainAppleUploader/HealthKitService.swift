//
//  HealthKitService.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import HealthKit
import CoreLocation
import Observation

// MARK: - Permission status

enum HealthKitPermissionStatus {
    case notRequested
    case available
    case unavailable
    case error(String)
}

// MARK: - Upload step

enum UploadStep: Equatable {
    case idle
    case readingWorkout
    case readingRoute
    case generatingTCX
    case uploading
    case savingState
    case done
}

// MARK: - HealthKitService

@Observable
@MainActor
final class HealthKitService {

    // MARK: - Constants

    static let recentDaysWindow = 7

    // MARK: - Observable state — workout (último, para sección de detalle)

    var latestWorkout: WorkoutSummary? = nil
    var latestHKWorkout: HKWorkout? = nil
    var permissionStatus: HealthKitPermissionStatus = .notRequested
    var isLoading: Bool = false
    var errorMessage: String? = nil

    var latestWorkoutHasRoute: Bool? = nil
    var latestWorkoutHasHeartRate: Bool? = nil

    // MARK: - Observable state — TCX

    var latestWorkoutDetail: WorkoutDetail? = nil
    var tcxString: String? = nil
    var tcxFileURL: URL? = nil
    var isGeneratingTCX: Bool = false
    var tcxErrorMessage: String? = nil

    // MARK: - Observable state — upload

    var isUploading: Bool = false
    var uploadStep: UploadStep = .idle
    var uploadErrorMessage: String? = nil
    var uploadErrorDetail: String? = nil
    var lastUploadedAt: Date? = nil

    // MARK: - Observable state — pending workouts (últimos 7 días)

    var recentWorkouts: [PendingWorkout] = []
    var isLoadingRecent: Bool = false
    var pendingError: String? = nil

    var pendingCount: Int {
        recentWorkouts.filter { $0.isPending }.count
    }

    // MARK: - Private

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]
    }

    // MARK: - Persistence key

    private static let permissionsRequestedKey = "hk_has_requested_permissions"

    // MARK: - Init

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            let hasRequested = UserDefaults.standard.bool(forKey: Self.permissionsRequestedKey)
            permissionStatus = hasRequested ? .available : .notRequested
        } else {
            permissionStatus = .unavailable
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            permissionStatus = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            UserDefaults.standard.set(true, forKey: Self.permissionsRequestedKey)
            permissionStatus = .available
        } catch {
            permissionStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Auto load (arranque silencioso)

    /// Solo actúa si hay permisos disponibles. No solicita permisos automáticamente.
    func autoLoad(uploadStore: UploadStore) async {
        guard case .available = permissionStatus else { return }
        await fetchRecentWorkouts(uploadStore: uploadStore)
    }

    // MARK: - Auto sync (arranque + subida automática)

    /// Carga recientes y sube todos los pendientes uno a uno.
    /// Llamado desde ContentView.task al abrir la app.
    func autoSync(uploadStore: UploadStore, settings: SettingsStore) async {
        guard case .available = permissionStatus else { return }
        await fetchRecentWorkouts(uploadStore: uploadStore)
        // Subir pendientes en orden hasta que no queden más
        while recentWorkouts.contains(where: { $0.isPending }) && !isUploading {
            await uploadNextPending(uploadStore: uploadStore, settings: settings)
            // Si el último intento falló (uploadStep == .idle con error), detener el bucle
            if uploadErrorMessage != nil { break }
        }
    }

    // MARK: - Fetch Recent Workouts (últimos N días)

    func fetchRecentWorkouts(uploadStore: UploadStore) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            pendingError = "HealthKit no está disponible en este dispositivo."
            return
        }

        isLoadingRecent = true
        pendingError = nil

        do {
            let workouts = try await queryRecentHKWorkouts()

            // Actualizar el "último entrenamiento" con el primero de la lista
            if let first = workouts.first {
                latestHKWorkout = first
                latestWorkout = WorkoutSummary(
                    id: first.uuid,
                    activityTypeName: first.workoutActivityType.displayName,
                    startDate: first.startDate,
                    endDate: first.endDate,
                    durationSeconds: first.duration,
                    totalDistanceMeters: first.totalDistance?.doubleValue(for: .meter()),
                    activeEnergyKcal: activeEnergyKcal(first)
                )
                // Query ligera ruta/pulso solo para el primero
                async let hasRoute = checkHasRoute(for: first)
                async let hasHR = checkHasHeartRate(for: first)
                let (route, hr) = await (hasRoute, hasHR)
                latestWorkoutHasRoute = route
                latestWorkoutHasHeartRate = hr
            } else {
                latestHKWorkout = nil
                latestWorkout = nil
                latestWorkoutHasRoute = nil
                latestWorkoutHasHeartRate = nil
            }

            // Construir lista de PendingWorkout con estado calculado
            recentWorkouts = workouts.map { w in
                let status: UploadStatus = uploadStore.isUploaded(workoutUUID: w.uuid)
                    ? .uploaded
                    : .pending
                return PendingWorkout(
                    id: w.uuid,
                    activityTypeName: w.workoutActivityType.displayName,
                    startDate: w.startDate,
                    endDate: w.endDate,
                    durationSeconds: w.duration,
                    totalDistanceMeters: w.totalDistance?.doubleValue(for: .meter()),
                    uploadStatus: status
                )
            }
        } catch {
            pendingError = error.localizedDescription
        }

        isLoadingRecent = false
    }

    // MARK: - Upload next pending

    func uploadNextPending(uploadStore: UploadStore, settings: SettingsStore) async {
        guard let next = recentWorkouts.first(where: { $0.isPending }) else {
            uploadErrorMessage = "No hay entrenamientos pendientes."
            return
        }
        await uploadPendingWorkout(next, uploadStore: uploadStore, settings: settings)
    }

    // MARK: - Upload specific pending (incluye reintentar failed)

    func uploadPendingWorkout(
        _ pending: PendingWorkout,
        uploadStore: UploadStore,
        settings: SettingsStore
    ) async {
        guard !uploadStore.isUploaded(workoutUUID: pending.id) else {
            markPending(pending.id, as: .uploaded)
            return
        }

        let resolvedAPIKey: String
        do {
            guard let k = try settings.readAPIKey(), !k.isEmpty else {
                let msg = "No se encontró la API key. Revisa la configuración."
                markPending(pending.id, as: .failed(msg))
                uploadErrorMessage = msg
                return
            }
            resolvedAPIKey = k
        } catch {
            let msg = "Error al leer la API key: \(error.localizedDescription)"
            markPending(pending.id, as: .failed(msg))
            uploadErrorMessage = msg
            return
        }

        isUploading = true
        uploadErrorMessage = nil
        uploadErrorDetail = nil
        defer { isUploading = false }

        do {
            // 1. Recuperar HKWorkout nativo
            uploadStep = .readingWorkout
            guard let workout = try await fetchHKWorkout(uuid: pending.id) else {
                let msg = "No se encontró el entrenamiento en HealthKit."
                markPending(pending.id, as: .failed(msg))
                uploadErrorMessage = msg
                uploadStep = .idle
                return
            }

            // Actualizar latestHKWorkout si es el primero
            if latestWorkout?.id == pending.id {
                latestHKWorkout = workout
            }

            // 2. Leer ruta completa
            uploadStep = .readingRoute
            let locations = try await fetchRoutes(for: workout)
            let hrSamples = try await fetchHeartRateSamples(for: workout)

            let points: [RoutePoint] = locations.map { loc in
                RoutePoint(
                    timestamp: loc.timestamp,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                    horizontalAccuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
                )
            }

            let detail = WorkoutDetail(
                id: workout.uuid,
                activityType: workout.workoutActivityType,
                activityTypeName: workout.workoutActivityType.displayName,
                startDate: workout.startDate,
                endDate: workout.endDate,
                durationSeconds: workout.duration,
                totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                activeEnergyKcal: activeEnergyKcal(workout),
                routePoints: points,
                heartRateSamples: hrSamples
            )

            // Actualizar estado del detalle si es el último visible
            if latestWorkout?.id == pending.id {
                latestWorkoutDetail = detail
                latestWorkoutHasRoute = detail.hasRoute
                latestWorkoutHasHeartRate = detail.hasHeartRate
            }

            // 3. Generar TCX
            uploadStep = .generatingTCX
            let tcx = TCXGenerator.generate(from: detail)
            guard let tcxData = tcx.data(using: .utf8) else {
                let msg = "Error al codificar el TCX."
                markPending(pending.id, as: .failed(msg))
                uploadErrorMessage = msg
                uploadStep = .idle
                return
            }

            if latestWorkout?.id == pending.id {
                tcxString = tcx
                tcxFileURL = try? writeTCXToTemp(tcx, uuid: detail.id)
            }

            let filename = "apple-health-\(workout.uuid.uuidString.lowercased()).tcx"

            // 4. Subir a Endurain
            uploadStep = .uploading
            let client = EndurainClient(serverURL: settings.serverURL, apiKey: resolvedAPIKey)
            _ = try await client.uploadActivityTCX(tcxData: tcxData, filename: filename)

            // 5. Guardar estado local
            uploadStep = .savingState
            let record = UploadRecord(
                id: workout.uuid,
                startDate: workout.startDate,
                endDate: workout.endDate,
                uploadedAt: Date(),
                filename: filename,
                serverURL: settings.serverURL,
                activityTypeName: pending.activityTypeName,
                durationSeconds: pending.durationSeconds,
                totalDistanceMeters: pending.totalDistanceMeters
            )
            try uploadStore.save(record: record)
            lastUploadedAt = record.uploadedAt

            markPending(pending.id, as: .uploaded)
            uploadStep = .done

        } catch let error as EndurainClientError {
            let msg = error.errorDescription ?? error.localizedDescription
            markPending(pending.id, as: .failed(msg))
            uploadErrorMessage = msg
            if case .uploadError(let code, let body) = error {
                uploadErrorDetail = "HTTP \(code)\n\(body)"
            }
            uploadStep = .idle
        } catch {
            let msg = error.localizedDescription
            markPending(pending.id, as: .failed(msg))
            uploadErrorMessage = msg
            uploadStep = .idle
        }
    }

    // MARK: - Legacy uploadWorkout (compatibilidad Fase 4/5, delega en uploadPendingWorkout)

    func uploadWorkout(uploadStore: UploadStore, settings: SettingsStore) async {
        guard let workout = latestWorkout else {
            uploadErrorMessage = "Primero busca un entrenamiento."
            return
        }
        let pending = PendingWorkout(
            id: workout.id,
            activityTypeName: workout.activityTypeName,
            startDate: workout.startDate,
            endDate: workout.endDate,
            durationSeconds: workout.durationSeconds,
            totalDistanceMeters: workout.totalDistanceMeters,
            uploadStatus: .pending
        )
        await uploadPendingWorkout(pending, uploadStore: uploadStore, settings: settings)
    }

    // MARK: - Fetch Latest Workout (manual refresh, actualiza también recentWorkouts)

    func fetchLatestWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit no está disponible en este dispositivo."
            return
        }
        isLoading = true
        errorMessage = nil
        latestWorkoutHasRoute = nil
        latestWorkoutHasHeartRate = nil
        tcxString = nil
        tcxFileURL = nil
        latestWorkoutDetail = nil
        tcxErrorMessage = nil
        uploadStep = .idle
        uploadErrorMessage = nil
        uploadErrorDetail = nil

        do {
            if let workout = try await queryLatestHKWorkout() {
                latestHKWorkout = workout
                latestWorkout = WorkoutSummary(
                    id: workout.uuid,
                    activityTypeName: workout.workoutActivityType.displayName,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                durationSeconds: workout.duration,
                totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                activeEnergyKcal: activeEnergyKcal(workout)
            )
            async let hasRoute = checkHasRoute(for: workout)
                async let hasHR = checkHasHeartRate(for: workout)
                let (route, hr) = await (hasRoute, hasHR)
                latestWorkoutHasRoute = route
                latestWorkoutHasHeartRate = hr
            } else {
                latestHKWorkout = nil
                latestWorkout = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Generate TCX (standalone debug)

    func generateTCX() async {
        guard let workout = latestHKWorkout else {
            tcxErrorMessage = "Primero busca un entrenamiento."
            return
        }
        isGeneratingTCX = true
        tcxErrorMessage = nil
        defer { isGeneratingTCX = false }
        do {
            let detail = try await buildWorkoutDetail(for: workout)
            latestWorkoutDetail = detail
            let tcx = TCXGenerator.generate(from: detail)
            tcxString = tcx
            tcxFileURL = try writeTCXToTemp(tcx, uuid: detail.id)
        } catch {
            tcxErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Build WorkoutDetail

    func buildWorkoutDetail(for workout: HKWorkout) async throws -> WorkoutDetail {
        async let routeLocations = fetchRoutes(for: workout)
        async let hrSamples = fetchHeartRateSamples(for: workout)
        let (locations, samples) = try await (routeLocations, hrSamples)
        let points: [RoutePoint] = locations.map { loc in
            RoutePoint(
                timestamp: loc.timestamp,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                horizontalAccuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
            )
        }
        return WorkoutDetail(
            id: workout.uuid,
            activityType: workout.workoutActivityType,
            activityTypeName: workout.workoutActivityType.displayName,
            startDate: workout.startDate,
            endDate: workout.endDate,
            durationSeconds: workout.duration,
            totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
            activeEnergyKcal: activeEnergyKcal(workout),
            routePoints: points,
            heartRateSamples: samples
        )
    }

    // MARK: - Fetch Routes

    func fetchRoutes(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard !routes.isEmpty else { return [] }
        var allLocations: [CLLocation] = []
        for route in routes {
            let locations = try await fetchLocations(for: route)
            allLocations.append(contentsOf: locations)
        }
        allLocations.sort { $0.timestamp < $1.timestamp }
        return allLocations
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var accumulated: [CLLocation] = []
            var didResume = false
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                if let locations { accumulated.append(contentsOf: locations) }
                if done, !didResume {
                    didResume = true
                    continuation.resume(returning: accumulated)
                }
            }
            store.execute(query)
        }
    }

    private func activeEnergyKcal(_ workout: HKWorkout) -> Double? {
        guard let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return nil
        }
        return workout
            .statistics(for: activeEnergyType)?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())
    }

    // MARK: - Fetch Heart Rate

    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HeartRateSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: .strictStartDate
            )
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let hrSamples: [HeartRateSample] = (samples as? [HKQuantitySample] ?? []).map { s in
                    HeartRateSample(
                        timestamp: s.startDate,
                        bpm: s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    )
                }
                continuation.resume(returning: hrSamples)
            }
            store.execute(query)
        }
    }

    // MARK: - Private queries

    private func queryRecentHKWorkouts() async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let now = Date()
            let start = Calendar.current.date(
                byAdding: .day,
                value: -HealthKitService.recentDaysWindow,
                to: now
            ) ?? now
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: now,
                options: .strictStartDate
            )
            let sortDescriptor = NSSortDescriptor(
                key: HKSampleSortIdentifierEndDate,
                ascending: false
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - Fetch all workouts since the beginning of time (para scan completo)
    //
    // Ordena por startDate ascendente para procesar del más antiguo al más nuevo.
    // Esto garantiza que si la app se interrumpe, al reanudar los más recientes
    // siguen pendientes y el progreso es visible para el usuario.
    //
    func fetchWorkoutsSinceBeginning() async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            // Calendar(2000-01-01) como límite inferior práctico
            var components = DateComponents()
            components.year = 2000; components.month = 1; components.day = 1
            let epoch = Calendar.current.date(from: components) ?? .distantPast

            let predicate = HKQuery.predicateForSamples(
                withStart: epoch,
                end: Date(),
                options: .strictStartDate
            )
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    private func queryLatestHKWorkout() async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(
                key: HKSampleSortIdentifierEndDate,
                ascending: false
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    func fetchHKWorkout(uuid: UUID) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: uuid)
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    // MARK: - Query ligera: ¿existe ruta?

    private func checkHasRoute(for workout: HKWorkout) async -> Bool {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: !(samples ?? []).isEmpty)
            }
            store.execute(query)
        }
    }

    // MARK: - Query ligera: ¿existe pulso?

    private func checkHasHeartRate(for workout: HKWorkout) async -> Bool {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: !(samples ?? []).isEmpty)
            }
            store.execute(query)
        }
    }

    // MARK: - Helpers

    private func markPending(_ id: UUID, as status: UploadStatus) {
        if let idx = recentWorkouts.firstIndex(where: { $0.id == id }) {
            recentWorkouts[idx].uploadStatus = status
        }
    }

    private func writeTCXToTemp(_ tcx: String, uuid: UUID) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "workout_\(uuid.uuidString).tcx"
        let url = tempDir.appendingPathComponent(fileName)
        try tcx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
