//
//  HealthKitBackgroundObserver.swift
//  EndurainAppleUploader
//
//  Best-effort observer for new HealthKit workouts.
//

import Foundation
import HealthKit
import os

final class HealthKitBackgroundObserver {

    private static let anchorDefaultsKey = "hk_workout_anchor_data"

    private let store = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var onWorkoutsChanged: (() async -> Void)?

    func start(onWorkoutsChanged: @escaping () async -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        self.onWorkoutsChanged = onWorkoutsChanged
        let workoutType = HKObjectType.workoutType()

        if observerQuery == nil {
            let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error {
                    AppLog.healthKit.error("HealthKit observer failed: \(error.localizedDescription, privacy: .private)")
                    completionHandler()
                    return
                }

                Task { [weak self] in
                    await self?.handleWorkoutChange()
                }
                completionHandler()
            }
            observerQuery = query
            store.execute(query)
        }

        store.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
            if let error {
                AppLog.healthKit.error("HealthKit background delivery failed: \(error.localizedDescription, privacy: .private)")
            } else if success {
                AppLog.healthKit.info("HealthKit background delivery enabled")
            }
        }
    }

    private func handleWorkoutChange() async {
        await runAnchoredWorkoutQuery()
        await onWorkoutsChanged?()
    }

    private func runAnchoredWorkoutQuery() async {
        await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: loadAnchor(),
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, _, _, newAnchor, error in
                if let error {
                    AppLog.healthKit.error("HealthKit anchored query failed: \(error.localizedDescription, privacy: .private)")
                }
                if let newAnchor {
                    self?.saveAnchor(newAnchor)
                }
                continuation.resume()
            }
            store.execute(query)
        }
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorDefaultsKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.anchorDefaultsKey)
    }
}
