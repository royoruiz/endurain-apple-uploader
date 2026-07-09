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
    case readingWorkout   // "Leyendo entrenamiento"
    case readingRoute     // "Leyendo ruta"
    case generatingTCX    // "Generando TCX"
    case uploading        // "Subiendo a Endurain"
    case savingState      // "Guardando estado"
    case done
}

// MARK: - HealthKitService

@Observable
@MainActor
final class HealthKitService {

    // MARK: - Observable state — workout

    var latestWorkout: WorkoutSummary? = nil
    var latestHKWorkout: HKWorkout? = nil       // Opción B: nativo, solo en memoria
    var permissionStatus: HealthKitPermissionStatus = .notRequested
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Query ligera: saber si hay ruta/pulso sin leer todos los puntos
    var latestWorkoutHasRoute: Bool? = nil      // nil = no verificado aún
    var latestWorkoutHasHeartRate: Bool? = nil  // nil = no verificado aún

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

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            permissionStatus = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            permissionStatus = .available
        } catch {
            permissionStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Auto load (arranque silencioso)

    /// Solo actúa si ya hay permisos disponibles y no hay workout en memoria.
    /// No solicita permisos automáticamente — el usuario debe hacerlo explícitamente.
    func autoLoad() async {
        guard case .available = permissionStatus else { return }
        guard latestWorkout == nil else { return }
        await fetchLatestWorkout()
    }

    // MARK: - Fetch Latest Workout

    func fetchLatestWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit no está disponible en este dispositivo."
            return
        }

        isLoading = true
        errorMessage = nil

        // Resetear estado derivado al buscar workout nuevo
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
                    activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                )
                // Query ligera: comprobar presencia de ruta y pulso
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

    // MARK: - Generate TCX (standalone, para debug/inspección)

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

    // MARK: - Upload workout

    func uploadWorkout(uploadStore: UploadStore, settings: SettingsStore) async {
        guard let workout = latestHKWorkout else {
            uploadErrorMessage = "Primero busca un entrenamiento."
            return
        }

        guard !uploadStore.isUploaded(workoutUUID: workout.uuid) else {
            uploadErrorMessage = "Este entrenamiento ya está subido a Endurain."
            return
        }

        let resolvedAPIKey: String
        do {
            guard let k = try settings.readAPIKey(), !k.isEmpty else {
                uploadErrorMessage = "No se encontró la API key. Revisa la configuración."
                return
            }
            resolvedAPIKey = k
        } catch {
            uploadErrorMessage = "Error al leer la API key: \(error.localizedDescription)"
            return
        }

        isUploading = true
        uploadErrorMessage = nil
        uploadErrorDetail = nil
        defer { isUploading = false }

        do {
            // 1. Leer entrenamiento base
            uploadStep = .readingWorkout
            let summary = latestWorkout

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
                activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                routePoints: points,
                heartRateSamples: hrSamples
            )

            // Actualizar estado observable del detalle
            latestWorkoutDetail = detail
            latestWorkoutHasRoute = detail.hasRoute
            latestWorkoutHasHeartRate = detail.hasHeartRate

            // 3. Generar TCX
            uploadStep = .generatingTCX
            let tcx = TCXGenerator.generate(from: detail)
            guard let tcxData = tcx.data(using: .utf8) else {
                uploadErrorMessage = "Error al codificar el TCX."
                uploadStep = .idle
                return
            }
            tcxString = tcx
            tcxFileURL = try? writeTCXToTemp(tcx, uuid: detail.id)

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
                activityTypeName: summary?.activityTypeName,
                durationSeconds: summary?.durationSeconds,
                totalDistanceMeters: summary?.totalDistanceMeters
            )
            try uploadStore.save(record: record)
            lastUploadedAt = record.uploadedAt

            uploadStep = .done

        } catch let error as EndurainClientError {
            uploadErrorMessage = error.errorDescription ?? error.localizedDescription
            if case .uploadError(let code, let body) = error {
                uploadErrorDetail = "HTTP \(code)\n\(body)"
            }
            uploadStep = .idle
        } catch {
            uploadErrorMessage = error.localizedDescription
            uploadStep = .idle
        }
    }

    // MARK: - Build WorkoutDetail (usado por generateTCX standalone)

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
            activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
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
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
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
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
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

    // MARK: - Fetch Heart Rate

    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HeartRateSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: .strictStartDate
            )
            let sortDescriptor = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate,
                ascending: true
            )
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
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

    // MARK: - Private HKWorkout query

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
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    // MARK: - Write TCX to temp file

    private func writeTCXToTemp(_ tcx: String, uuid: UUID) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "workout_\(uuid.uuidString).tcx"
        let url = tempDir.appendingPathComponent(fileName)
        try tcx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
