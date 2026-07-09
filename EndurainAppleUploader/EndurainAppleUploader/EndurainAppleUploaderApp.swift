//
//  EndurainAppleUploaderApp.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

@main
struct EndurainAppleUploaderApp: App {

    @State private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: settingsStore)
        }
    }
}
