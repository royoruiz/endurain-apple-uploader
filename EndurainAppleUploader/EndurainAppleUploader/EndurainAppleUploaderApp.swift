//
//  EndurainAppleUploaderApp.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

@main
struct EndurainAppleUploaderApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore: SettingsStore
    @State private var healthKitService: HealthKitService
    @State private var uploadStore: UploadStore
    @State private var syncQueueStore: SyncQueueStore
    @State private var backgroundUploadService: BackgroundUploadService
    @State private var healthKitBackgroundObserver: HealthKitBackgroundObserver
    @State private var syncEngine: SyncEngine

    init() {
        let settings = SettingsStore()
        let healthKit = HealthKitService()
        let uploads = UploadStore()
        let queue = try! SyncQueueStore()
        let backgroundUploads = BackgroundUploadService(queue: queue)
        let observer = HealthKitBackgroundObserver()
        let engine = SyncEngine(
            hkService: healthKit,
            queue: queue,
            settings: settings,
            backgroundUploadService: backgroundUploads
        )

        _settingsStore = State(initialValue: settings)
        _healthKitService = State(initialValue: healthKit)
        _uploadStore = State(initialValue: uploads)
        _syncQueueStore = State(initialValue: queue)
        _backgroundUploadService = State(initialValue: backgroundUploads)
        _healthKitBackgroundObserver = State(initialValue: observer)
        _syncEngine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: settingsStore,
                healthKitService: healthKitService,
                uploadStore: uploadStore,
                syncEngine: syncEngine,
                healthKitBackgroundObserver: healthKitBackgroundObserver
            )
            .task {
                await backgroundUploadService.reconnect()
                healthKitBackgroundObserver.start {
                    await syncEngine.startSync()
                }
            }
        }
    }
}
