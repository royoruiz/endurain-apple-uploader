//
//  WorkoutDetail.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import HealthKit

// MARK: - RoutePoint

struct RoutePoint {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
}

// MARK: - HeartRateSample

struct HeartRateSample {
    let timestamp: Date
    let bpm: Double
}

// MARK: - WorkoutDetail

struct WorkoutDetail {
    let id: UUID
    let activityType: HKWorkoutActivityType
    let activityTypeName: String
    let startDate: Date
    let endDate: Date
    let durationSeconds: TimeInterval
    let totalDistanceMeters: Double?
    let activeEnergyKcal: Double?
    let routePoints: [RoutePoint]
    let heartRateSamples: [HeartRateSample]

    var hasRoute: Bool { !routePoints.isEmpty }
    var hasHeartRate: Bool { !heartRateSamples.isEmpty }
}
