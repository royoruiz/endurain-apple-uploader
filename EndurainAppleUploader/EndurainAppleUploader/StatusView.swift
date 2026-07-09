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
    @State private var expandedFailedIDs: Set<UUID> = []

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                healthKitPermissionsSection
                lastUploadedSection
                latestWorkoutSection
                syncSection
                pendingSection
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
            if healthKitService.isLoading || healthKitService.isLoadingRecent {
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

                if uploadStore.isUploaded(workoutUUID: workout.id) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Ya subido").foregroundStyle(.green)
                    }
                    .font(.caption)
                }
            } else if let err = healthKitService.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if let err = healthKitService.pendingError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("No se ha detectado ningún entrenamiento.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sync section (CTA principal)

    private var syncSection: some View {
        Section {
            if healthKitService.isLoadingRecent {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("Buscando entrenamientos...")
                        .foregroundStyle(.secondary)
                }
            } else if healthKitService.isUploading {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text(uploadStepLabel).foregroundStyle(.secondary)
                }
            } else if healthKitService.uploadStep == .done {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Entrenamiento subido correctamente")
                        .foregroundStyle(.green).fontWeight(.medium)
                }
            } else if !isHealthKitAvailable {
                Button {
                    Task { await healthKitService.fetchLatestWorkout() }
                } label: {
                    Text("Buscar entrenamiento").frame(maxWidth: .infinity)
                }
                .disabled(!isHealthKitAvailable)
            } else if healthKitService.pendingCount == 0 && !healthKitService.recentWorkouts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo sincronizado").fontWeight(.medium)
                        Text("Todos los entrenamientos recientes están en Endurain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if healthKitService.pendingCount > 0 {
                if healthKitService.pendingCount > 1 {
                    Text("\(healthKitService.pendingCount) entrenamientos pendientes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    showUploadErrorDetail = false
                    Task {
                        await healthKitService.uploadNextPending(
                            uploadStore: uploadStore,
                            settings: store
                        )
                    }
                } label: {
                    Text("Subir siguiente pendiente").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(healthKitService.isUploading)
            } else {
                // recentWorkouts vacío — buscar manualmente
                Button {
                    Task {
                        await healthKitService.fetchRecentWorkouts(uploadStore: uploadStore)
                    }
                } label: {
                    Text("Buscar entrenamientos recientes").frame(maxWidth: .infinity)
                }
            }

            if let errMsg = healthKitService.uploadErrorMessage {
                Text(errMsg).font(.caption).foregroundStyle(.red)
                if let detail = healthKitService.uploadErrorDetail {
                    DisclosureGroup("Detalle técnico", isExpanded: $showUploadErrorDetail) {
                        Text(detail)
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }

        } header: {
            Text("Sincronización")
        } footer: {
            if healthKitService.pendingCount > 0 && !healthKitService.isUploading {
                Text("Se usa la API key configurada en Ajustes.")
            }
        }
    }

    // MARK: - Pending workouts section

    private var pendingSection: some View {
        Section {
            if healthKitService.isLoadingRecent {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("Cargando entrenamientos...").foregroundStyle(.secondary)
                }
            } else if healthKitService.recentWorkouts.isEmpty {
                if let err = healthKitService.pendingError {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else {
                    Text("No hay entrenamientos en los últimos \(HealthKitService.recentDaysWindow) días.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(healthKitService.recentWorkouts) { workout in
                    pendingWorkoutRow(workout)
                }
            }
        } header: {
            HStack {
                Text("Pendientes recientes (\(HealthKitService.recentDaysWindow) días)")
                Spacer()
                if !healthKitService.isLoadingRecent {
                    Button {
                        Task {
                            await healthKitService.fetchRecentWorkouts(uploadStore: uploadStore)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func pendingWorkoutRow(_ workout: PendingWorkout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.activityTypeName)
                        .fontWeight(.medium)
                    Text(workout.startDate, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(formattedDuration(workout.durationSeconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let dist = workout.totalDistanceMeters {
                            Text(formattedDistance(dist))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                statusBadge(for: workout)
            }

            // Error inline expandible
            if let msg = workout.failedMessage {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedFailedIDs.contains(workout.id) },
                        set: { expanded in
                            if expanded { expandedFailedIDs.insert(workout.id) }
                            else { expandedFailedIDs.remove(workout.id) }
                        }
                    )
                ) {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                } label: {
                    Text("Ver error")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        await healthKitService.uploadPendingWorkout(
                            workout,
                            uploadStore: uploadStore,
                            settings: store
                        )
                    }
                } label: {
                    Text("Reintentar")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(healthKitService.isUploading)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(for workout: PendingWorkout) -> some View {
        switch workout.uploadStatus {
        case .pending:
            Label("Pendiente", systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .uploaded:
            Label("Subido", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Debug section

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
                    Text(tcxError).font(.caption).foregroundStyle(.red)
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
                        .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    if !detail.hasRoute {
                        Text("Sin ruta GPS asociada.").font(.caption).foregroundStyle(.orange)
                    }
                    if !detail.hasHeartRate {
                        Text("Sin muestras de pulso.").font(.caption).foregroundStyle(.secondary)
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
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button(role: .destructive) {
                showConfirmClearHistory = true
            } label: {
                Text("Borrar historial de subidas").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showConfirmClear = true
            } label: {
                Text("Borrar configuración").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Zona de peligro")
        } footer: {
            Text("\"Borrar historial\" solo olvida las subidas locales. No elimina nada en Endurain.")
        }
    }

    // MARK: - Upload step label

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

    // MARK: - Route / HR labels

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
            // Recalcular estados de pending tras borrar historial
            for i in healthKitService.recentWorkouts.indices {
                if case .uploaded = healthKitService.recentWorkouts[i].uploadStatus {
                    healthKitService.recentWorkouts[i].uploadStatus = .pending
                }
            }
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
