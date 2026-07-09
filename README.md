# Endurain Apple Uploader

App iOS que lee entrenamientos de Apple Salud y los sube a una instancia self-hosted de [Endurain](https://github.com/joaovitoriasilva/endurain).

---

## Configuración

1. Abre la app.
2. Introduce la URL de tu servidor Endurain (debe comenzar por `https://`).
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

1. Crea un entreno corto con ruta GPS.
2. Abre la app y concede permisos de Salud.
3. Espera a que la app detecte y programe las subidas automáticamente.
4. Bloquea el iPhone durante una subida grande.
5. Vuelve a abrir la app.
6. Comprueba que no duplica y que continúa/reconcilia la cola.

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
