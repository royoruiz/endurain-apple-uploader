# Endurain Apple Uploader

App iOS que lee entrenamientos de Apple Salud y los sube a una instancia self-hosted de [Endurain](https://github.com/joaovitoriasilva/endurain).

---

## Configuración

1. Abre la app.
2. Introduce la URL de tu servidor Endurain. Si no indicas esquema, la app usará `https://`.
3. Introduce tu API key de Endurain.
4. Pulsa **Guardar**.
5. En la pantalla principal, pulsa **Dar permiso a Apple Salud** y acepta los permisos de lectura.
6. La app comenzará a sincronizar automáticamente.

---

## Cómo funciona

### Fase 8b (actual)

- **Escaneo completo**: al abrir la app, escanea todos los entrenamientos de Apple Salud desde el año 2000.
- **Cola persistente**: guarda el estado en `Application Support/EndurainAppleUploader/sync-queue.json`.
- **Deduplicación**: nunca sube dos veces el mismo entrenamiento (clave: `HKWorkout.uuid`).
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
- **Reanudación al abrir**: la app siempre reconcilia tareas URLSession, reescanea HealthKit y continúa sin duplicar por `HKWorkout.uuid`.
- **Sin paginación**: si tienes miles de entrenamientos, el escaneo inicial puede tardar varios segundos.
- **Lote limitado**: para proteger Endurain, la app programa como máximo 10 subidas por lote y lanza el siguiente lote automáticamente cuando termina el anterior.
- **Sin ruta GPS, no TCX**: actividades indoor o entrenos sin ruta se omiten en esta fase.

---

## Background Delivery En Xcode

- Capability `HealthKit` debe estar activa.
- Entitlement `com.apple.developer.healthkit.background-delivery` debe estar presente.
- No se usa `BGTaskScheduler` en esta fase.
- No hace falta guardar la API key fuera de Keychain.

## Cómo Probar

1. Ejecuta la app en un iPhone real.
2. Configura el servidor Endurain del usuario.
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
└── TCXQueue/                ← ficheros TCX temporales durante generación
```

---

## Requisitos

- iOS 17+ (deployment target: iOS 26.5)
- iPhone o iPad con Apple Salud
- Cuenta Endurain con API key válida
- Servidor Endurain accesible por HTTPS
