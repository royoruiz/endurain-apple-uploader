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
    @State private var userIdentifier: String = ""
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
        (try? ServerURLNormalizer.normalize(serverURL)) != nil
    }

    private var urlErrorMessage: String? {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try ServerURLNormalizer.normalize(serverURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        isValidURL
            && (try? UserIdentityNormalizer.normalize(userIdentifier)) != nil
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
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
                    Text("Dirección de tu instancia self-hosted. Si no indicas esquema se usará HTTPS.")
                }

                Section {
                    TextField("nicolas", text: $userIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Usuario Endurain")
                } footer: {
                    Text("Se usa como espacio local de deduplicación. Cambiarlo permite subir a otra cuenta del mismo servidor.")
                }

                // MARK: API Key
                Section {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Key")
                } footer: {
                    Text("API key will be used when uploading activities. Se guarda de forma segura en el Keychain de iOS.")
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

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedURL: String
        do {
            normalizedURL = try ServerURLNormalizer.normalize(serverURL)
        } catch {
            saveError = error.localizedDescription
            serverStatus = .idle
            return
        }

        // Comprobar conectividad básica antes de guardar. No valida la API key.
        let client = EndurainClient(serverURL: normalizedURL, apiKey: trimmedKey)
        do {
            _ = try await client.testConnection()
            serverStatus = .ok
        } catch {
            // Si no es accesible, mostrar advertencia pero permitir guardar
            serverStatus = .unreachable(error.localizedDescription)
        }

        // Guardar siempre, aunque el servidor no responda
        do {
            try store.save(serverURL: normalizedURL, userIdentifier: userIdentifier, apiKey: trimmedKey)
        } catch {
            saveError = "Error al guardar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView(store: SettingsStore())
}
