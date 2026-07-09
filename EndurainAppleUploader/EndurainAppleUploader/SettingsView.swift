//
//  SettingsView.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

struct SettingsView: View {

    var store: SettingsStore

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""

    // Probar conexión
    @State private var isTesting: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false

    // Guardar
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    // MARK: - Validation

    private var isValidURL: Bool {
        serverURL.hasPrefix("https://") && serverURL.count > 8
    }

    private var canSave: Bool {
        isValidURL && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var urlErrorMessage: String? {
        if serverURL.isEmpty { return nil }
        if !serverURL.hasPrefix("https://") {
            return "La URL debe comenzar por https://"
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://endurain.home.ejemplo.es", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let error = urlErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Servidor Endurain")
                } footer: {
                    Text("Dirección completa de tu instancia self-hosted. Debe usar HTTPS.")
                }

                Section {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Key")
                } footer: {
                    Text("La API Key se guarda de forma segura en el Keychain de iOS.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isTesting ? "Probando..." : "Probar conexión")
                        }
                    }
                    .disabled(!canSave || isTesting || isSaving)

                    Button {
                        Task { await saveSettings() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isSaving ? "Guardando..." : "Guardar")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isTesting || isSaving)

                    if let error = saveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Configuración")
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        let client = EndurainClient(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            _ = try await client.testConnection()
            alertTitle = "Conexión exitosa"
            alertMessage = "El servidor respondió correctamente."
        } catch {
            alertTitle = "Error de conexión"
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }

    private func saveSettings() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            try store.save(
                serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            saveError = "Error al guardar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView(store: SettingsStore())
}
