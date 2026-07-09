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

    var body: some View {
        if store.isConfigured {
            StatusView(store: store, healthKitService: healthKitService)
        } else {
            SettingsView(store: store)
        }
    }
}

#Preview {
    ContentView(store: SettingsStore(), healthKitService: HealthKitService())
}
