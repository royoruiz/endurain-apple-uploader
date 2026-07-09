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
    case available       // requestAuthorization completó sin error del sistema
    case unavailable     // HKHealthStore.isHealthDataAvailable() == false
    case error(String)
}

// MARK: - HealthKitService

@Observable
@MainActor
final class HealthKitService {

    // MARK: - Observable state

    // Resumen ligero para UI (Fase 2)
    var latestWorkout: WorkoutSummary? = nil

    // Opción B: objeto HK nativo guardado en memoria, solo en memoria
    var latestHKWorkout: HKWorkout? = nil

    var permissionStatus: HealthKitPermissionStatus = .notRequested
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Estado TCX (Fase 3)
    var latestWorkoutDetail: WorkoutDetail? = nil
    var tcxString: String? = nil
    var tcxFileURL: URL? = nil
    var isGeneratingTCX: Bool = false
    var tcxErrorMessage: String? = nil

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

    // MARK: - Request Authorization

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

    // MARK: - Fetch Latest Workout

    func fetchLatestWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit no está disponible en este dispositivo."
            return
        }

        isLoading = true
        errorMessage = nil

        // Resetear estado TCX al buscar un workout nuevo
        tcxString = nil
        tcxFileURL = nil
        latestWorkoutDetail = nil
        tcxErrorMessage = nil

        do {
            if let workout = try await queryLatestHKWorkout() {
                latestHKWorkout = workout   // Opción B: guardar nativo
                latestWorkout = WorkoutSummary(
                    id: workout.uuid,
                    activityTypeName: workout.workoutActivityType.displayName,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    durationSeconds: workout.duration,
                    totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                    activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                )
            } else {
                latestHKWorkout = nil
                latestWorkout = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Generate TCX

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
            activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            routePoints: points,
            heartRateSamples: samples
        )
    }

    // MARK: - Fetch Routes

    func fetchRoutes(for workout: HKWorkout) async throws -> [CLLocation] {
        // Paso 1: obtener objetos HKWorkoutRoute asociados al workout
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

        // Paso 2: para cada ruta, acumular CLLocation con HKWorkoutRouteQuery
        var allLocations: [CLLocation] = []
        for route in routes {
            let locations = try await fetchLocations(for: route)
            allLocations.append(contentsOf: locations)
        }

        // Ordenar por timestamp
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
                if let locations {
                    accumulated.append(contentsOf: locations)
                }
                if done {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: accumulated)
                    }
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
