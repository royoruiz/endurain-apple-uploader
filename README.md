# Endurain Apple Uploader

App iOS que lee entrenamientos de Apple Salud y los sube a una instancia self-hosted de [Endurain](https://github.com/joaovitoriasilva/endurain).

---

## Configuración

1. Abre la app.
2. Introduce la URL de tu servidor Endurain. Si no indicas esquema, la app usará `https://`.
3. Introduce el usuario/cuenta de Endurain. Se usa como namespace local de deduplicación.
4. Introduce tu API key de Endurain.
5. Pulsa **Guardar**.
6. En la pantalla principal, pulsa **Dar permiso a Apple Salud** y acepta los permisos de lectura.
7. La app comenzará a sincronizar automáticamente.

---

## Cómo funciona

### Fase 8b (actual)

- **Escaneo completo**: al abrir la app, escanea todos los entrenamientos de Apple Salud desde el año 2000.
- **Cola persistente**: guarda el estado en `Application Support/EndurainAppleUploader/sync-queue.json`.
- **Deduplicación**: nunca sube dos veces el mismo entrenamiento para el mismo servidor+usuario (clave: `SHA256(servidor_normalizado + "\n" + usuario_normalizado) + HKWorkout.uuid`).
- **Sin lectura de Endurain**: las API keys de esta app solo necesitan `activities:upload`. La app no lee perfil ni lista de actividades del servidor.
- **Generación TCX**: lee ruta GPS y frecuencia cardíaca, genera un fichero TCX estándar (Garmin Training Center XML).
- **Omisión segura**: los entrenamientos sin al menos dos puntos GPS se marcan como omitidos. Endurain no importa correctamente TCX sin trackpoints.
- **Subida en background**: usa `URLSessionConfiguration.background` y `uploadTask(fromFile:)`. El multipart completo se escribe a disco antes de programar la tarea.
- **Detección best-effort**: registra `HKObserverQuery` para workouts y activa `enableBackgroundDelivery(..., .immediate)`.
- **Protección del servidor**: programa subidas en lotes automáticos de 10 y espera 2 segundos entre tareas.
- **Reanudación**: si la app se cierra durante una subida, al reabrir reanuda desde donde dejó.
- **Errores transitorios**: ante `429` o `5xx` se detiene ese lote para no saturar Endurain; la app conserva la cola para reanudar después.
- **Privacidad de logs**: la app no registra API keys, TCX completos ni coordenadas GPS en consola.

### Permisos de HealthKit requeridos (solo lectura)

- Entrenamientos (`HKWorkoutType`)
- Rutas de ejercicio (`HKWorkoutRoute`)
- Frecuencia cardíaca
- Energía activa
- Distancia en carrera/caminata
- Distancia en ciclismo

---

## Limitaciones actuales (Fase 8b)

- **iOS decide cuándo ejecutar**: HealthKit background delivery y URLSession background son best-effort.
- **No hay ejecución infinita**: si iOS suspende la app, las subidas ya programadas pueden continuar, pero no se garantiza procesamiento ilimitado.
- **Force quit**: si el usuario fuerza el cierre desde el app switcher, iOS puede no despertar la app hasta la próxima apertura manual.
- **Reanudación al abrir**: la app siempre reconcilia tareas URLSession, reescanea HealthKit y continúa sin duplicar por servidor+usuario+`HKWorkout.uuid`.
- **Sin paginación**: si tienes miles de entrenamientos, el escaneo inicial puede tardar varios segundos.
- **Lote limitado**: para proteger Endurain, la app programa como máximo 10 subidas por lote y lanza el siguiente lote automáticamente cuando termina el anterior.
- **Sin ruta GPS, no TCX**: actividades indoor o entrenos sin ruta se omiten en esta fase.

---

## Background Delivery En Xcode

- Capability `HealthKit` debe estar activa.
- Entitlement `com.apple.developer.healthkit.background-delivery` debe estar presente.
- No se usa `BGTaskScheduler` en esta fase.
- No hace falta guardar la API key fuera de Keychain. La API key es credencial, no identidad, y no participa en la deduplicación.
- La comprobación de servidor, si se ejecuta, solo verifica conectividad básica contra la URL base y no valida la API key.

## Cómo Probar

1. Ejecuta la app en un iPhone real.
2. Configura el servidor Endurain y el usuario/cuenta Endurain.
3. Crea una API key con scope `activities:upload`.
4. Concede permisos de lectura de Apple Salud.
5. Crea un entreno corto con ruta GPS.
6. Espera a que la app detecte y suba el entreno automáticamente.
7. Confirma que el entreno aparece en Endurain.
8. Confirma que el mapa/ruta aparece en Endurain.
9. Confirma que el pulso aparece si existía en Apple Salud.
10. Cierra y vuelve a abrir la app.
11. Confirma que no duplica entrenamientos ya subidos.
12. Bloquea el iPhone durante una subida larga.
13. Reabre la app y confirma que reanuda o queda sincronizado.

### Reset configuration behavior

1. Configura un servidor Endurain A y usuario `nicolas`.
2. Sube entrenamientos.
3. Pulsa **Borrar configuración**.
4. Deja sin marcar **Also delete upload history for this server/user**.
5. Reconfigura el mismo servidor A y usuario `nicolas` con otra API key.
6. La app no debe volver a subir entrenamientos ya registrados localmente para ese servidor+usuario.
7. Si quieres tratar el mismo servidor+usuario como fresco porque has recreado la base de datos Endurain, repite el borrado marcando **Also delete upload history for this server/user**.
8. Con esa casilla marcada, la app borra solo el historial de ese namespace y podrá volver a subir los entrenamientos al reconfigurar el mismo servidor+usuario.
9. Cambiar de servidor o cambiar de usuario crea otro namespace, así que los mismos entrenamientos son elegibles para ese destino.
10. Los permisos de HealthKit deben seguir concedidos salvo que se revoquen desde Ajustes de iOS.

### API keys y duplicados

- Endurain API keys para esta app solo requieren `activities:upload`.
- La app no usa `profile:read`, `activities:read`, `/api/v1/user/me`, `/api/v1/profile` ni endpoints de listado de actividades.
- Duplicate prevention combines local server/user/workout identity with Endurain's idempotency-key replay contract.
- Si solo rotas la API key para el mismo servidor y usuario, no borres el historial de subidas.
- Si recreas o vacías la base de datos de Endurain manteniendo el mismo servidor y usuario, la app no puede detectarlo desde la API. Para subir todo otra vez, borra la configuración marcando **Also delete upload history for this server/user**.

### Endurain v0.20.2 imports

- Uploads use `POST /api/v1/activities/upload`, multipart field `file`, and `X-API-Key`.
- A stable `Idempotency-Key` derived from the workout filename is reused after lost responses and restarts. Endurain scopes replay keys to the caller.
- HTTP 202 means **accepted**, not synchronized. The background queue saves the job ID and checks `GET /api/v1/activities/ingestion-jobs/{job_id}` using the same `activities:upload` permission.
- The TCX is retained until the job reports `completed` with an activity ID. Accepted jobs resume through GET, not another upload.
- Both upload paths retain a minimal write-ahead receipt containing only the job handle. A failed queue-snapshot write cannot silently make an accepted import eligible for another POST. If local receipt storage cannot be confirmed, automatic reposting stops with an explicit error.
- A terminal import failure keeps the TCX and job ID for diagnosis; it is not automatically reposted. A temporary status-query failure keeps the accepted job pending.
- Existing uploaded/skipped history is preserved. No HealthKit distance samples or original workouts are modified.
- The legacy foreground path also waits for job completion. If its bounded wait or a GET fails, a recreated client resumes the saved job through GET rather than repeating POST.

---

## App Store / TestFlight Preparation

- No activar Clinical Health Records; la app no lee historiales clínicos.
- Mantener HealthKit solo con permisos de lectura.
- Privacy Policy URL obligatoria en App Store Connect.
- Declarar uso de datos Health/Fitness en App Store Connect.
- Declarar uso de datos de Location si se suben rutas GPS incluidas en los entrenamientos.
- Explicar que los datos se envían únicamente al servidor Endurain configurado por el usuario.
- Explicar que no hay tracking ni publicidad.
- Explicar que no se venden datos.
- Explicar que la API key se guarda en Keychain.
- Explicar que la URL del servidor se guarda en preferencias locales.
- Explicar limitaciones de background sync:
  - iOS no garantiza ejecución continua.
  - si el usuario fuerza cierre desde el app switcher, background sync puede no ejecutarse.
  - la app reescanea al abrir para no perder entrenamientos.

---

## Comandos De Validación

### Hostless upload tests (no application launch or installation)

The dependency-free Swift package compiles only the upload core. HTTP fixtures
intercept every request; these tests do not access HealthKit, Keychain, devices,
or a real Endurain server.

```bash
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH"/{home,tmp,cache,config,security}
HOME="$SCRATCH/home" TMPDIR="$SCRATCH/tmp" swift test \
  --scratch-path "$SCRATCH/build" --cache-path "$SCRATCH/cache" \
  --config-path "$SCRATCH/config" --security-path "$SCRATCH/security"
# Remove your temporary SCRATCH directory after inspecting the results.
```

The Xcode test target below is app-hosted and may start synchronization. Do not
run it against a configured application during read-only diagnosis.

Listar schemes:

```bash
xcodebuild -list -project EndurainAppleUploader/EndurainAppleUploader.xcodeproj
```

Build Debug:

```bash
xcodebuild -project EndurainAppleUploader/EndurainAppleUploader.xcodeproj -scheme EndurainAppleUploader -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Ejecutar tests:

```bash
xcodebuild -project EndurainAppleUploader/EndurainAppleUploader.xcodeproj -scheme EndurainAppleUploader -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Si `iPhone 16` no existe en tu Xcode, cambia el destino por un simulador disponible desde Xcode.

---

## Estructura de ficheros de datos

```
Application Support/EndurainAppleUploader/
├── sync-queue.json          ← cola persistente de sincronización
├── TCXQueue/<namespace>/    ← ficheros TCX temporales durante generación
├── IngestionReceipts/      ← opaque import handles and unresolved submission intents
└── MultipartUploads/<namespace>/ ← ficheros multipart temporales para URLSession background
```

---

## Requisitos

- iOS 17+ (deployment target: iOS 26.5)
- iPhone o iPad con Apple Salud
- Cuenta Endurain con API key válida
- Servidor Endurain accesible por HTTPS
