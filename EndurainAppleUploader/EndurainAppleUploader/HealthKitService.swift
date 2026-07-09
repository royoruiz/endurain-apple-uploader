//
//  HealthKitService.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import HealthKit
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

    // MARK: Observable state

    var permissionStatus: HealthKitPermissionStatus = .notRequested
    var latestWorkout: WorkoutSummary? = nil
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // MARK: Private

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]
        return types
    }

    // MARK: - Request Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            permissionStatus = .unavailable
            return
        }

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit no informa si el usuario aceptó o rechazó cada tipo
            // (privacidad por diseño). Solo sabemos que la solicitud se completó.
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

        do {
            let workout = try await queryLatestWorkout()
            latestWorkout = workout
            if workout == nil {
                errorMessage = nil // el mensaje de "no hay datos" lo maneja la UI
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Private query

    private func queryLatestWorkout() async throws -> WorkoutSummary? {
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

                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: nil)
                    return
                }

                let summary = WorkoutSummary(
                    id: workout.uuid,
                    activityTypeName: workout.workoutActivityType.displayName,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    durationSeconds: workout.duration,
                    totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                    activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                )
                continuation.resume(returning: summary)
            }

            store.execute(query)
        }
    }
}
