//
//  ContentView.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

struct ContentView: View {

    var store: SettingsStore
    var healthKitService: HealthKitService
    var uploadStore: UploadStore
    var syncEngine: SyncEngine
    var healthKitBackgroundObserver: HealthKitBackgroundObserver

    var body: some View {
        if store.isConfigured {
            StatusView(
                store: store,
                healthKitService: healthKitService,
                syncEngine: syncEngine,
                healthKitBackgroundObserver: healthKitBackgroundObserver
            )
                .task {
                    // Al abrir la app: sincronización automática si hay permisos.
                    // SyncEngine escanea desde 2000-01-01 y sube los pendientes.
                    await syncEngine.startSync()
                }
        } else {
            SettingsView(store: store)
        }
    }
}

#Preview {
    let settings = SettingsStore()
    let hk = HealthKitService()
    let queue = try! SyncQueueStore()
    let backgroundUploads = BackgroundUploadService(queue: queue)
    ContentView(
        store: settings,
        healthKitService: hk,
        uploadStore: UploadStore(),
        syncEngine: SyncEngine(
            hkService: hk,
            queue: queue,
            settings: settings,
            backgroundUploadService: backgroundUploads
        ),
        healthKitBackgroundObserver: HealthKitBackgroundObserver()
    )
}
