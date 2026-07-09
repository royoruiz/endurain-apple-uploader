//
//  PendingWorkout.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation

// MARK: - UploadStatus

enum UploadStatus: Equatable {
    case pending
    case uploaded
    case failed(String)   // mensaje de error del último intento

    static func == (lhs: UploadStatus, rhs: UploadStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending):     return true
        case (.uploaded, .uploaded):   return true
        case (.failed(let a), .failed(let b)): return a == b
        default:                       return false
        }
    }
}

// MARK: - PendingWorkout

struct PendingWorkout: Identifiable {
    let id: UUID
    let activityTypeName: String
    let startDate: Date
    let endDate: Date
    let durationSeconds: TimeInterval
    let totalDistanceMeters: Double?
    var uploadStatus: UploadStatus

    var isPending: Bool {
        if case .pending = uploadStatus { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = uploadStatus { return true }
        return false
    }

    var failedMessage: String? {
        if case .failed(let msg) = uploadStatus { return msg }
        return nil
    }
}
