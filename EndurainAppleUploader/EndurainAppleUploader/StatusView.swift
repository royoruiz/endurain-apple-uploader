//
//  StatusView.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import SwiftUI

struct StatusView: View {

    var store: SettingsStore
    var healthKitService: HealthKitService

    @State private var showConfirmClear: Bool = false
    @State private var clearError: String? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                healthKitPermissionsSection
                lastUploadedSection
                latestWorkoutSection
                dangerZoneSection
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

    // MARK: - Sections

    private var serverSection: some View {
        Section("Servidor") {
            LabeledContent("URL") {
                Text(store.serverURL)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var healthKitPermissionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: permissionIcon)
                    .foregroundStyle(permissionColor)
                Text(permissionLabel)
                    .foregroundStyle(.primary)
            }

            Button {
                Task { await healthKitService.requestAuthorization() }
            } label: {
                Text("Solicitar permisos de Salud")
            }
            .disabled(isPermissionButtonDisabled)

        } header: {
            Text("Permisos de Apple Salud")
        } footer: {
            Text("Puedes revisar permisos en Ajustes → Salud → Acceso a datos y dispositivos → Endurain Apple Uploader.")
                .font(.caption)
        }
    }

    private var lastUploadedSection: some View {
        Section("Último subido a Endurain") {
            Text("Ninguno todavía")
                .foregroundStyle(.secondary)
        }
    }

    private var latestWorkoutSection: some View {
        Section {
            Button {
                Task { await healthKitService.fetchLatestWorkout() }
            } label: {
                HStack {
                    if healthKitService.isLoading {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Text(healthKitService.isLoading ? "Buscando..." : "Buscar último entrenamiento")
                }
            }
            .disabled(healthKitService.isLoading || !isHealthKitAvailable)

            if let errorMsg = healthKitService.errorMessage {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !healthKitService.isLoading {
                if let workout = healthKitService.latestWorkout {
                    workoutDetails(workout)
                } else if healthKitService.errorMessage == nil {
                    Text("No se ha detectado ningún entrenamiento. Puede ser porque no hay entrenos recientes o porque los permisos de Salud no están concedidos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

        } header: {
            Text("Último entrenamiento en Apple Salud")
        }
    }

    @ViewBuilder
    private func workoutDetails(_ w: WorkoutSummary) -> some View {
        LabeledContent("Tipo", value: w.activityTypeName)

        LabeledContent("Inicio") {
            Text(w.startDate, format: .dateTime)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Fin") {
            Text(w.endDate, format: .dateTime)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Duración", value: formattedDuration(w.durationSeconds))

        if let distanceM = w.totalDistanceMeters {
            LabeledContent("Distancia", value: formattedDistance(distanceM))
        }

        if let kcal = w.activeEnergyKcal {
            LabeledContent("Calorías activas", value: String(format: "%.0f kcal", kcal))
        }

        Text(w.id.uuidString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }

    private var dangerZoneSection: some View {
        Section {
            if let error = clearError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(role: .destructive) {
                showConfirmClear = true
            } label: {
                Text("Borrar configuración")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Permission helpers

    private var isHealthKitAvailable: Bool {
        if case .available = healthKitService.permissionStatus { return true }
        return false
    }

    private var isPermissionButtonDisabled: Bool {
        switch healthKitService.permissionStatus {
        case .unavailable: return true
        case .available:   return false
        default:           return false
        }
    }

    private var permissionLabel: String {
        switch healthKitService.permissionStatus {
        case .notRequested:
            return "Permisos no solicitados"
        case .available:
            return "Solicitud completada / HealthKit disponible"
        case .unavailable:
            return "HealthKit no disponible en este dispositivo"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    private var permissionIcon: String {
        switch healthKitService.permissionStatus {
        case .notRequested:  return "questionmark.circle"
        case .available:     return "checkmark.circle.fill"
        case .unavailable:   return "xmark.circle.fill"
        case .error:         return "exclamationmark.triangle.fill"
        }
    }

    private var permissionColor: Color {
        switch healthKitService.permissionStatus {
        case .notRequested:  return .secondary
        case .available:     return .green
        case .unavailable:   return .red
        case .error:         return .orange
        }
    }

    // MARK: - Format helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else {
            return String(format: "%dm %02ds", m, s)
        }
    }

    private func formattedDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
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
    StatusView(store: SettingsStore(), healthKitService: HealthKitService())
}
