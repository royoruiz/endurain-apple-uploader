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

    var body: some View {
        if store.isConfigured {
            StatusView(store: store, healthKitService: healthKitService, uploadStore: uploadStore)
                .task {
                    // Arranque silencioso: carga entrenamientos recientes si hay permisos.
                    // No solicita permisos automáticamente — acción consciente del usuario.
                    await healthKitService.autoLoad(uploadStore: uploadStore)
                }
        } else {
            SettingsView(store: store)
        }
    }
}

#Preview {
    ContentView(
        store: SettingsStore(),
        healthKitService: HealthKitService(),
        uploadStore: UploadStore()
    )
}
