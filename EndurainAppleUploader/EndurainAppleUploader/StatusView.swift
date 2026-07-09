//
//  StatusView.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

struct StatusView: View {

    var store: SettingsStore

    @State private var showConfirmClear: Bool = false
    @State private var clearError: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                VStack(spacing: 8) {
                    Text("Configuración guardada")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(store.serverURL)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                if let error = clearError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Button(role: .destructive) {
                    showConfirmClear = true
                } label: {
                    Text("Borrar configuración")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("Estado")
            .confirmationDialog(
                "¿Borrar configuración?",
                isPresented: $showConfirmClear,
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) {
                    clearConfiguration()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se eliminará la URL del servidor y la API Key. Tendrás que volver a configurar la app.")
            }
        }
    }

    // MARK: - Actions

    private func clearConfiguration() {
        clearError = nil
        do {
            try store.clear()
        } catch {
            clearError = "Error al borrar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    let store = SettingsStore()
    StatusView(store: store)
}
