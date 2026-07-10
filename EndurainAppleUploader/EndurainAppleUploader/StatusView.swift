//
//  StatusView.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI
import os

struct StatusView: View {

    var store: SettingsStore
    var healthKitService: HealthKitService
    var syncEngine: SyncEngine
    var healthKitBackgroundObserver: HealthKitBackgroundObserver
    var resetService: AppResetService

    @State private var showConfirmClear = false
    @State private var deleteUploadHistory = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                syncCard
                    .padding(.horizontal)
                    .padding(.top, 24)

                lastUploadedCard
                    .padding(.horizontal)
                    .padding(.top, 16)

                Spacer()

                bottomActions
                    .padding(.horizontal)
                    .padding(.bottom, 32)
            }
            .navigationTitle("Endurain")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showConfirmClear) {
                deleteConfigurationSheet
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Sync card

    private var syncCard: some View {
        VStack(spacing: 16) {
            // Icono
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 72, height: 72)
                iconView
                    .font(.system(size: 32))
                    .foregroundStyle(iconColor)
            }

            // Estado
            VStack(spacing: 6) {
                Text(syncEngine.syncState.label)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: syncEngine.syncState.label)

                Text(store.serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(store.userIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                queueSummary

                Text("Las subidas en segundo plano dependen de iOS. La app reanudará al abrirse.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            syncNotice
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var queueSummary: some View {
        let pending = syncEngine.pendingCount
        let failed = syncEngine.failedCount
        let skipped = syncEngine.skippedCount
        let uploading = syncEngine.uploadingCount

        if pending > 0 || failed > 0 || skipped > 0 || uploading > 0 {
            Text(summaryText(pending: pending, failed: failed, skipped: skipped, uploading: uploading))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch syncEngine.syncState {
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        case .scanning, .generating, .uploading, .backgroundUploading:
            ProgressView()
                .controlSize(.large)
                .tint(iconColor)
        case .synced:
            Image(systemName: "checkmark.circle.fill")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var iconBackground: Color {
        switch syncEngine.syncState {
        case .synced:  return .green.opacity(0.12)
        case .error:   return .red.opacity(0.12)
        default:       return .secondary.opacity(0.10)
        }
    }

    private var iconColor: Color {
        switch syncEngine.syncState {
        case .synced:  return .green
        case .error:   return .red
        default:       return .accentColor
        }
    }

    @ViewBuilder
    private var syncNotice: some View {
        let state = syncEngine.syncState

        // Sin permisos: mostrar botón de dar permiso
        if case .notRequested = healthKitService.permissionStatus {
            permissionButton
        } else if case .unavailable = healthKitService.permissionStatus {
            Text("HealthKit no disponible en este dispositivo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if case .error(let msg) = state {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        } else if state == .synced || !state.isWorking {
            Text("La app detecta y sube entrenamientos automáticamente.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        // Durante trabajo: no mostrar acción manual.
    }

    private var permissionButton: some View {
        Button {
            Task {
                await healthKitService.requestAuthorization()
                // Tras conceder permisos, arrancar sync automáticamente
                if case .available = healthKitService.permissionStatus {
                    healthKitBackgroundObserver.start {
                        await syncEngine.startSync()
                    }
                    await syncEngine.startSync()
                }
            }
        } label: {
            Label("Dar permiso a Apple Salud", systemImage: "heart.text.square")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Last uploaded card

    @ViewBuilder
    private var lastUploadedCard: some View {
        if let last = syncEngine.lastUploadedItem {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Último subido")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text(last.activityTypeName)
                            .fontWeight(.medium)
                        Text("·").foregroundStyle(.secondary)
                        Text(formattedDuration(last.durationSeconds)).foregroundStyle(.secondary)
                        if let dist = last.distanceMeters {
                            Text("·").foregroundStyle(.secondary)
                            Text(formattedDistance(dist)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)

                    if let uploadedAt = last.uploadedAt {
                        Text(uploadedAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Bottom actions

    private var bottomActions: some View {
        Button(role: .destructive) {
            deleteUploadHistory = false
            showConfirmClear = true
        } label: {
            Text("Borrar configuración")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private var deleteConfigurationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Delete server, user and API token from this device?")
                        .font(.body)

                    Toggle("Also delete upload history for this server/user", isOn: $deleteUploadHistory)

                    Text("If unchecked, reconfiguring the same server and user will not re-upload workouts. Check this only if you are starting with a fresh Endurain database or want to upload everything again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Delete configuration", role: .destructive) {
                        clearConfiguration(deleteHistory: deleteUploadHistory)
                    }
                    Button("Cancel", role: .cancel) {
                        showConfirmClear = false
                    }
                }
            }
            .navigationTitle("Borrar configuración")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Format helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0
            ? String(format: "%dh %02dm", h, m)
            : String(format: "%dm", m)
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func summaryText(pending: Int, failed: Int, skipped: Int, uploading: Int) -> String {
        var parts: [String] = []
        if uploading > 0 { parts.append("\(uploading) subiendo") }
        if pending > 0 { parts.append("\(pending) pendiente(s)") }
        if failed > 0 { parts.append("\(failed) fallido(s)") }
        if skipped > 0 { parts.append("\(skipped) omitido(s)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func clearConfiguration(deleteHistory: Bool) {
        Task {
            do {
                try await resetService.deleteConfiguration(deleteUploadHistory: deleteHistory)
                syncEngine.handleConfigurationCleared()
                showConfirmClear = false
            } catch {
                AppLog.settings.error("Failed to clear settings: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}

#Preview {
    let settings = SettingsStore()
    let hk = HealthKitService()
    let queue = try! SyncQueueStore()
    let backgroundUploads = BackgroundUploadService(queue: queue)
    let uploadStore = UploadStore()
    let resetService = AppResetService(
        settings: settings,
        queue: queue,
        uploadStore: uploadStore,
        backgroundUploadService: backgroundUploads
    )
    StatusView(
        store: settings,
        healthKitService: hk,
        syncEngine: SyncEngine(
            hkService: hk,
            queue: queue,
            settings: settings,
            backgroundUploadService: backgroundUploads
        ),
        healthKitBackgroundObserver: HealthKitBackgroundObserver(),
        resetService: resetService
    )
}
