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
                tcxSection
                latestWorkoutSection
                dangerZoneSection
            }
            .navigationTitle("Estado")
            .confirmationDialog(
                "¿Borrar configuración?",
                isPresented: $showConfirmClear,
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) { clearConfiguration() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se eliminará la URL del servidor y la API Key. Tendrás que volver a configurar la app.")
            }
        }
    }

    // MARK: - Server section

    private var serverSection: some View {
        Section("Servidor") {
            LabeledContent("URL") {
                Text(store.serverURL)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - HealthKit permissions section

    private var healthKitPermissionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: permissionIcon)
                    .foregroundStyle(permissionColor)
                Text(permissionLabel)
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
        }
    }

    // MARK: - Last uploaded section

    private var lastUploadedSection: some View {
        Section("Último subido a Endurain") {
            Text("Ninguno todavía")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - TCX section

    private var tcxSection: some View {
        Section {
            Button {
                Task { await healthKitService.generateTCX() }
            } label: {
                HStack {
                    if healthKitService.isGeneratingTCX {
                        ProgressView().padding(.trailing, 4)
                    }
                    Text(healthKitService.isGeneratingTCX
                         ? "Generando TCX..."
                         : "Generar TCX del último entrenamiento")
                }
            }
            .disabled(healthKitService.latestWorkout == nil || healthKitService.isGeneratingTCX)

            if let tcxError = healthKitService.tcxErrorMessage {
                Text(tcxError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let detail = healthKitService.latestWorkoutDetail {
                tcxSummary(detail)
            }

        } header: {
            Text("TCX")
        } footer: {
            if healthKitService.latestWorkoutDetail == nil && healthKitService.tcxErrorMessage == nil {
                Text("Primero busca el último entrenamiento, luego genera el TCX.")
            }
        }
    }

    @ViewBuilder
    private func tcxSummary(_ detail: WorkoutDetail) -> some View {
        LabeledContent("Puntos de ruta", value: "\(detail.routePoints.count)")
        LabeledContent("Muestras de pulso", value: "\(detail.heartRateSamples.count)")

        if let tcx = healthKitService.tcxString {
            let kb = String(format: "%.1f KB", Double(tcx.utf8.count) / 1024.0)
            LabeledContent("Tamaño TCX", value: kb)
        }

        LabeledContent("Contiene ruta", value: detail.hasRoute ? "Sí" : "No")
        LabeledContent("Contiene pulso", value: detail.hasHeartRate ? "Sí" : "No")

        if !detail.hasRoute {
            Text("Este entrenamiento no tiene ruta GPS asociada o no se concedió permiso de rutas.")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if !detail.hasHeartRate {
            Text("No hay muestras de frecuencia cardíaca disponibles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if detail.hasRoute, let first = detail.routePoints.first, let last = detail.routePoints.last {
            VStack(alignment: .leading, spacing: 2) {
                Text("Primera coord: \(coordString(first)) @ \(timeString(first.timestamp))")
                Text("Última coord:  \(coordString(last)) @ \(timeString(last.timestamp))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }

        if let url = healthKitService.tcxFileURL {
            ShareLink(
                item: url,
                preview: SharePreview(
                    "workout_\(detail.id.uuidString.prefix(8)).tcx",
                    image: Image(systemName: "doc.text")
                )
            ) {
                Label("Compartir TCX", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Latest workout section

    private var latestWorkoutSection: some View {
        Section {
            Button {
                Task { await healthKitService.fetchLatestWorkout() }
            } label: {
                HStack {
                    if healthKitService.isLoading {
                        ProgressView().padding(.trailing, 4)
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
        } footer: {
            if healthKitService.latestWorkout == nil && healthKitService.errorMessage == nil {
                Text("Puedes revisar permisos en Ajustes → Salud → Acceso a datos y dispositivos → Endurain Apple Uploader.")
            }
        }
    }

    @ViewBuilder
    private func workoutDetails(_ w: WorkoutSummary) -> some View {
        LabeledContent("Tipo", value: w.activityTypeName)

        LabeledContent("Inicio") {
            Text(w.startDate, format: .dateTime).foregroundStyle(.secondary)
        }
        LabeledContent("Fin") {
            Text(w.endDate, format: .dateTime).foregroundStyle(.secondary)
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

    // MARK: - Danger zone section

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
                Text("Borrar configuración").frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Permission helpers

    private var isHealthKitAvailable: Bool {
        if case .available = healthKitService.permissionStatus { return true }
        return false
    }

    private var isPermissionButtonDisabled: Bool {
        if case .unavailable = healthKitService.permissionStatus { return true }
        return false
    }

    private var permissionLabel: String {
        switch healthKitService.permissionStatus {
        case .notRequested:    return "Permisos no solicitados"
        case .available:       return "Solicitud completada / HealthKit disponible"
        case .unavailable:     return "HealthKit no disponible en este dispositivo"
        case .error(let msg):  return "Error: \(msg)"
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
        return h > 0
            ? String(format: "%dh %02dm %02ds", h, m, s)
            : String(format: "%dm %02ds", m, s)
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func coordString(_ p: RoutePoint) -> String {
        String(format: "%.6f, %.6f", p.latitude, p.longitude)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f.string(from: date)
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
