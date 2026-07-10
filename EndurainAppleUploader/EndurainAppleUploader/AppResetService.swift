//
//  AppResetService.swift
//  EndurainAppleUploader
//

import Foundation
import os

@MainActor
final class AppResetService {

    private let settings: SettingsStore
    private let queue: SyncQueueStore
    private let uploadStore: UploadStore
    private let backgroundUploadService: BackgroundUploadService

    init(
        settings: SettingsStore,
        queue: SyncQueueStore,
        uploadStore: UploadStore,
        backgroundUploadService: BackgroundUploadService
    ) {
        self.settings = settings
        self.queue = queue
        self.uploadStore = uploadStore
        self.backgroundUploadService = backgroundUploadService
    }

    func deleteConfiguration(deleteUploadHistory: Bool) async throws {
        let identity = try? settings.currentIdentity()
        await backgroundUploadService.cancelActiveUploadsAndClearLocalState(namespaceID: identity?.namespaceID)
        if deleteUploadHistory, let identity {
            try queue.deleteHistory(namespaceID: identity.namespaceID)
        }
        try settings.clearConfigurationOnly()
        AppLog.settings.info("Configuration cleared")
    }
}
