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
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var serverStatus: ServerStatus = .idle

    private enum ServerStatus {
        case idle
        case checking
        case ok
        case unreachable(String)
    }

    // MARK: - Validation

    private var isValidURL: Bool {
        serverURL.hasPrefix("https://") && serverURL.count > 8
    }

    private var urlErrorMessage: String? {
        guard !serverURL.isEmpty, !serverURL.hasPrefix("https://") else { return nil }
        return "La URL debe comenzar por https://"
    }

    private var canSave: Bool {
        isValidURL && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Servidor
                Section {
                    TextField("https://endurain.home.ejemplo.es", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: serverURL) { _, _ in
                            // Resetear estado del servidor al cambiar la URL
                            serverStatus = .idle
                        }

                    if let err = urlErrorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Estado del servidor inline
                    switch serverStatus {
                    case .idle:
                        EmptyView()
                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Comprobando servidor...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .ok:
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Servidor accesible")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    case .unreachable(let msg):
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                } header: {
                    Text("Servidor Endurain")
                } footer: {
                    Text("Dirección completa de tu instancia self-hosted. Debe usar HTTPS.")
                }

                // MARK: API Key
                Section {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Se guarda de forma segura en el Keychain de iOS.")
                }

                // MARK: Guardar
                Section {
                    Button {
                        Task { await saveSettings() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView().padding(.trailing, 4)
                            }
                            Text(isSaving ? "Guardando..." : "Guardar")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)

                    if let error = saveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Configuración")
        }
    }

    // MARK: - Save

    private func saveSettings() async {
        isSaving = true
        saveError = nil
        serverStatus = .checking
        defer { isSaving = false }

        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Comprobar servidor antes de guardar
        let client = EndurainClient(serverURL: trimmedURL, apiKey: trimmedKey)
        do {
            _ = try await client.testConnection()
            serverStatus = .ok
        } catch {
            // Si no es accesible, mostrar advertencia pero permitir guardar
            serverStatus = .unreachable(error.localizedDescription)
        }

        // Guardar siempre, aunque el servidor no responda
        do {
            try store.save(serverURL: trimmedURL, apiKey: trimmedKey)
        } catch {
            saveError = "Error al guardar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView(store: SettingsStore())
}
