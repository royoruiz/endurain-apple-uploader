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
    var uploadStore: UploadStore

    @State private var showConfirmClear = false
    @State private var showConfirmClearHistory = false
    @State private var showUploadErrorDetail = false
    @State private var clearError: String? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                healthKitPermissionsSection
                lastUploadedSection
                latestWorkoutSection
                syncSection
                debugSection
                dangerZoneSection
            }
            .navigationTitle("Endurain")
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
            .confirmationDialog(
                "¿Borrar historial de subidas?",
                isPresented: $showConfirmClearHistory,
                titleVisibility: .visible
            ) {
                Button("Borrar historial", role: .destructive) { clearUploadHistory() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esto olvidará qué entrenamientos se han subido. Podrías volver a subir duplicados. ¿Continuar?")
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
            HStack(spacing: 10) {
                Image(systemName: permissionIcon)
                    .foregroundStyle(permissionColor)
                Text(permissionLabel)
            }
            if !isPermissionButtonDisabled {
                Button("Solicitar permisos de Salud") {
                    Task { await healthKitService.requestAuthorization() }
                }
            }
        } header: {
            Text("Permisos de Apple Salud")
        } footer: {
            Text("Ajustes → Salud → Acceso a datos y dispositivos → Endurain Apple Uploader.")
        }
    }

    // MARK: - Last uploaded section

    private var lastUploadedSection: some View {
        Section("Último subido a Endurain") {
            if let last = uploadStore.lastRecord {
                LabeledContent("Fecha") {
                    Text(last.uploadedAt, format: .dateTime)
                        .foregroundStyle(.secondary)
                }
                if let type = last.activityTypeName {
                    LabeledContent("Tipo", value: type)
                }
                if let dur = last.durationSeconds {
                    LabeledContent("Duración", value: formattedDuration(dur))
                }
                if let dist = last.totalDistanceMeters {
                    LabeledContent("Distancia", value: formattedDistance(dist))
                }
            } else {
                Text("Ninguno todavía")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Latest workout section

    private var latestWorkoutSection: some View {
        Section("Último entrenamiento en Apple Salud") {
            if healthKitService.isLoading {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("Cargando...")
                        .foregroundStyle(.secondary)
                }
            } else if let workout = healthKitService.latestWorkout {
                LabeledContent("Tipo", value: workout.activityTypeName)
                LabeledContent("Fecha") {
                    Text(workout.startDate, format: .dateTime)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Duración", value: formattedDuration(workout.durationSeconds))
                if let dist = workout.totalDistanceMeters {
                    LabeledContent("Distancia", value: formattedDistance(dist))
                }
                LabeledContent("Ruta GPS", value: routeLabel)
                LabeledContent("Pulso", value: heartRateLabel)

                if isCurrentWorkoutUploaded {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ya subido")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                }
            } else if let err = healthKitService.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("No se ha detectado ningún entrenamiento.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sync section (CTA principal)

    private var syncSection: some View {
        Section {
            if healthKitService.isLoading {
                // autoLoad en progreso
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("Buscando entrenamiento...")
                        .foregroundStyle(.secondary)
                }
            } else if healthKitService.isUploading {
                // Subida en progreso
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text(uploadStepLabel)
                        .foregroundStyle(.secondary)
                }
            } else if healthKitService.uploadStep == .done {
                // Éxito
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Entrenamiento subido correctamente")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                }
            } else if healthKitService.latestWorkout == nil {
                // Sin workout: botón de búsqueda manual
                Button {
                    Task { await healthKitService.fetchLatestWorkout() }
                } label: {
                    Text("Buscar entrenamiento")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!isHealthKitAvailable)
            } else if isCurrentWorkoutUploaded {
                // Todo sincronizado
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo sincronizado")
                            .fontWeight(.medium)
                        Text("El último entrenamiento ya está en Endurain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Hay workout nuevo sin subir
                Button {
                    showUploadErrorDetail = false
                    Task { await healthKitService.uploadWorkout(uploadStore: uploadStore, settings: store) }
                } label: {
                    Text("Subir entrenamiento nuevo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadButtonDisabled)
            }

            // Error de subida
            if let errMsg = healthKitService.uploadErrorMessage {
                Text(errMsg)
                    .font(.caption)
                    .foregroundStyle(.red)

                if let detail = healthKitService.uploadErrorDetail {
                    DisclosureGroup("Detalle técnico", isExpanded: $showUploadErrorDetail) {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }

        } header: {
            Text("Sincronización")
        } footer: {
            if healthKitService.latestWorkout != nil && !isCurrentWorkoutUploaded
                && !healthKitService.isUploading && healthKitService.uploadStep != .done {
                Text("Se usa la API key configurada en Ajustes.")
            }
        }
    }

    // MARK: - Debug section (colapsable)

    private var debugSection: some View {
        Section {
            DisclosureGroup("Debug") {
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
                    LabeledContent("Puntos de ruta", value: "\(detail.routePoints.count)")
                    LabeledContent("Muestras de pulso", value: "\(detail.heartRateSamples.count)")

                    if let tcx = healthKitService.tcxString {
                        LabeledContent("Tamaño TCX",
                            value: String(format: "%.1f KB", Double(tcx.utf8.count) / 1024.0))
                    }

                    if detail.hasRoute,
                       let first = detail.routePoints.first,
                       let last = detail.routePoints.last {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Primera: \(coordString(first)) @ \(timeString(first.timestamp))")
                            Text("Última:  \(coordString(last)) @ \(timeString(last.timestamp))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    }

                    if !detail.hasRoute {
                        Text("Sin ruta GPS asociada.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !detail.hasHeartRate {
                        Text("Sin muestras de pulso.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let url = healthKitService.tcxFileURL {
                    ShareLink(
                        item: url,
                        preview: SharePreview(
                            healthKitService.latestWorkoutDetail.map {
                                "workout_\($0.id.uuidString.prefix(8)).tcx"
                            } ?? "workout.tcx",
                            image: Image(systemName: "doc.text")
                        )
                    ) {
                        Label("Compartir TCX", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
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
                showConfirmClearHistory = true
            } label: {
                Text("Borrar historial de subidas")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showConfirmClear = true
            } label: {
                Text("Borrar configuración")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        } header: {
            Text("Zona de peligro")
        } footer: {
            Text("\"Borrar historial\" solo olvida las subidas locales. No elimina nada en Endurain.")
        }
    }

    // MARK: - Upload helpers

    private var isCurrentWorkoutUploaded: Bool {
        guard let id = healthKitService.latestWorkout?.id else { return false }
        return uploadStore.isUploaded(workoutUUID: id)
    }

    private var uploadButtonDisabled: Bool {
        healthKitService.latestWorkout == nil
            || healthKitService.isUploading
            || healthKitService.isGeneratingTCX
            || isCurrentWorkoutUploaded
    }

    private var uploadStepLabel: String {
        switch healthKitService.uploadStep {
        case .readingWorkout: return "Leyendo entrenamiento..."
        case .readingRoute:   return "Leyendo ruta..."
        case .generatingTCX:  return "Generando TCX..."
        case .uploading:      return "Subiendo a Endurain..."
        case .savingState:    return "Guardando estado..."
        case .done:           return "¡Subido!"
        case .idle:           return "Subiendo..."
        }
    }

    // MARK: - Route / HR labels (query ligera)

    private var routeLabel: String {
        switch healthKitService.latestWorkoutHasRoute {
        case .none:  return "—"
        case true:   return "Sí"
        case false:  return "No"
        }
    }

    private var heartRateLabel: String {
        switch healthKitService.latestWorkoutHasHeartRate {
        case .none:  return "—"
        case true:   return "Sí"
        case false:  return "No"
        }
    }

    // MARK: - Permission helpers

    private var isHealthKitAvailable: Bool {
        if case .available = healthKitService.permissionStatus { return true }
        return false
    }

    private var isPermissionButtonDisabled: Bool {
        if case .unavailable = healthKitService.permissionStatus { return true }
        if case .available   = healthKitService.permissionStatus { return true }
        return false
    }

    private var permissionLabel: String {
        switch healthKitService.permissionStatus {
        case .notRequested:   return "Permisos no solicitados"
        case .available:      return "Solicitud completada / HealthKit disponible"
        case .unavailable:    return "HealthKit no disponible en este dispositivo"
        case .error(let msg): return "Error: \(msg)"
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
            clearError = "Error al borrar configuración: \(error.localizedDescription)"
        }
    }

    private func clearUploadHistory() {
        do {
            try uploadStore.clear()
            healthKitService.uploadStep = .idle
            healthKitService.uploadErrorMessage = nil
            healthKitService.uploadErrorDetail = nil
        } catch {
            clearError = "Error al borrar historial: \(error.localizedDescription)"
        }
    }
}

#Preview {
    StatusView(
        store: SettingsStore(),
        healthKitService: HealthKitService(),
        uploadStore: UploadStore()
    )
}
