//
//  UploadStore.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import Observation

// MARK: - UploadRecord

struct UploadRecord: Codable, Identifiable {
    let id: UUID          // workoutUUID — mismo que HKWorkout.uuid
    let startDate: Date
    let endDate: Date
    let uploadedAt: Date
    let filename: String
    let serverURL: String
}

// MARK: - UploadStore

@Observable
final class UploadStore {

    private(set) var records: [UploadRecord] = []

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let uploadRecords = "endurain_upload_records"
    }

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Query

    func isUploaded(workoutUUID: UUID) -> Bool {
        records.contains { $0.id == workoutUUID }
    }

    func record(for workoutUUID: UUID) -> UploadRecord? {
        records.first { $0.id == workoutUUID }
    }

    var lastRecord: UploadRecord? {
        records.sorted { $0.uploadedAt > $1.uploadedAt }.first
    }

    // MARK: - Save

    func save(record: UploadRecord) throws {
        // Evitar duplicados: si ya existe el UUID, no añadir
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
        try persist()
    }

    // MARK: - Clear

    func clear() throws {
        records = []
        defaults.removeObject(forKey: Keys.uploadRecords)
    }

    // MARK: - Private

    private func load() {
        guard let data = defaults.data(forKey: Keys.uploadRecords) else { return }
        records = (try? decoder.decode([UploadRecord].self, from: data)) ?? []
    }

    private func persist() throws {
        let data = try encoder.encode(records)
        defaults.set(data, forKey: Keys.uploadRecords)
    }
}
