# Setube (Android)

App de Android de Setube, el convertidor de YouTube a MP3, M4A, WAV y MP4. Hace lo mismo que la web (`setube`) y la API (`api-setube`), pero todo en el teléfono: no necesita servidor, ni Redis, ni PO token. yt-dlp, Python, QuickJS y ffmpeg van dentro del APK.

Hecho por [Sebxstt](https://github.com/GarcesSebastian).

## Qué hace

- Barra de comandos para links (uno o varios por línea: videos, Shorts, Music, `youtu.be` y playlists) o búsqueda por texto. Pegar varios links los agrega al momento. También acepta «Compartir» desde la app de YouTube.
- Búsquedas recientes (las 8 últimas) con borrar y deshacer.
- Selector de salida como en la web: Audio | Video, MP3 (128/192/320 kbps), M4A (original), WAV (16 bits, 44,1 kHz) y MP4 (360p a 1080p o «Mejor»), con el tamaño estimado de cada opción.
- Cola con ficha por video (canal, duración, resoluciones, tamaños, descripción), progreso real por fase y velocidad, reintentar, cancelar y deshacer al quitar o vaciar.
- Sin límites de duración ni de cantidad de videos.
- Un video se guarda como archivo en `Music/Setube` o `Movies/Setube`. Dos o más, en un ZIP en `Download/Setube`. MP3 y M4A llevan título, artista y portada.
- Registro de descargas: abrir el archivo, ir a su carpeta, compartir (WhatsApp y cualquier app del sistema) y borrar.
- Escuchar y ver antes de convertir: un solo reproductor (ExoPlayer) con controles en la pantalla de bloqueo, anterior y siguiente de la cola, cambio entre audio y video en el mismo segundo y pantalla completa.
- Las descargas siguen en segundo plano con una notificación de progreso. Al terminar, la notificación permite abrir o compartir el archivo.
- Sesión de YouTube opcional (ver abajo).
- Envío al PC por la Wi‑Fi con LocalSend (ver abajo): un botón en cada descarga o envío automático al terminar.
- Tema oscuro por defecto y claro opcional.

## Cómo funciona sin servidor

| En la API | En la app |
| --- | --- |
| yt-dlp + ffmpeg en Docker | [youtubedl-android](https://github.com/yausername/youtubedl-android) 0.18.1: Python 3.12, yt-dlp, QuickJS 2025-04-26 y ffmpeg, ejecutados desde `nativeLibraryDir` |
| Redis (caché, jobs, cola, pub/sub) | Caché en `cache/meta` y `cache/info`, cola en memoria y servicio en primer plano (`DownloadService`). Cada video pasa por tres etapas con su propio límite: preparar (info en lotes), descargar (3 a la vez) y convertir (un ffmpeg por núcleo, hasta 8) |
| `/file` y `/archive` en streaming | `FastDownload.kt` baja los formatos de googlevideo con 4 conexiones en paralelo; después `Convert.kt` convierte con una sola llamada a ffmpeg (los mismos argumentos que `args.ts`, con portada y metadatos y con progreso real); si eso falla, convierte yt-dlp. El resultado se copia a MediaStore (o a un ZIP sin comprimir). Si la descarga directa falla, descarga yt-dlp |
| Proxy de audio y HLS de video | ExoPlayer pide googlevideo directamente. El audio va en tramos de 10 MiB y el video es un MPD de DASH armado con los rangos `moov`/`sidx` de cada formato (`lib/core/dash.dart`) |
| Servicio `pot` (bgutil) + `player_client=default,mweb` | Los mismos clientes. El PO token de BotGuard lo genera un WebView de la app (como NewPipe) y se lo entrega a yt-dlp un plugin propio (`assets/ytdlp-plugins`) a través de un servidor local en `127.0.0.1` (`Helper.kt`) |
| Node para los retos JS (n/sig) | El mismo plugin resuelve los retos con los scripts EJS de yt-dlp en otro WebView (V8). Si falla, yt-dlp vuelve a QuickJS |
| Proxy y cookies contra el bloqueo | La IP es la del teléfono (residencial o móvil). Si YouTube aun así pide confirmar que no eres un bot, se usa la sesión |

yt-dlp se actualiza solo al abrir la app por primera vez y después una vez por semana (canal estable), y a mano desde Ajustes, sin instalar otro APK. En Ajustes → Diagnóstico se prueba un video con y sin sesión: muestra si hubo PO token, qué resolvió los retos JS, los formatos y la velocidad real de googlevideo, y se puede copiar el informe.

## Sesión de YouTube

En Ajustes → «Iniciar sesión» se abre Google en el WebView de la app, con un User-Agent de Chrome móvil y sin la cabecera `X-Requested-With`. La sesión queda en la base SQLite de cookies del WebView (`app_webview/Default/Cookies`). `CookieStore.kt` la lee como `cookies-db.ts` de la API (en Android el WebView no cifra las cookies), filtra `youtube.com` y `google.com` y escribe un `cookies.txt` temporal 0600 para cada proceso de yt-dlp. Al abrir la app, si pasaron más de 6 horas, un WebView sin interfaz abre YouTube unos segundos para que rote las cookies. Así la sesión dura lo que dura en un navegador.

Modos:

- **Solo cuando YouTube la pida** (por defecto): primero sin cookies; si yt-dlp responde «Sign in to confirm you're not a bot» o pide verificar la edad, repite con la sesión.
- **Siempre**: todas las llamadas con la sesión.
- **Nunca**.

Si Google no deja iniciar sesión en el WebView, se puede pegar un `cookies.txt` (formato Netscape). Usa una cuenta secundaria: YouTube puede limitar las cuentas que descargan mucho.

## Enviar al PC

Pensado para pasar las canciones a un PC con Windows (por ejemplo, para VirtualDJ) sin cables ni pasos técnicos. Usa el protocolo de [LocalSend](https://localsend.org) (v2), así que en el PC solo hace falta LocalSend.

Configuración, una sola vez:

1. En el PC, instalar LocalSend desde localsend.org. La primera vez Windows pregunta por el acceso a la red: «Permitir».
2. En LocalSend del PC, Ajustes: activar «Guardado rápido» (acepta sin preguntar), elegir en «Destino» la carpeta de la música y activar «Iniciar con el sistema».
3. En Setube, Ajustes → Enviar al PC → «Buscar PC» y «Usar este». Opcional: «Enviar cada descarga automáticamente».

Después, cada descarga tiene «Enviar al PC» (en la fila de la cola, en el aviso al terminar y en el registro). Un ZIP se envía ya descomprimido: las canciones llegan en una carpeta con el nombre de la tanda.

Cómo funciona (`PcSend.kt`, `PcService.kt`):

- Busca LocalSend en la red con multicast (224.0.0.167:53317) y, en paralelo, preguntando a cada IP de la red (`POST /api/localsend/v2/register`).
- LocalSend 1.18 exige certificado de cliente (mTLS). El teléfono genera una vez un certificado EC P-256 en el Keystore de Android; su SHA-256 es la huella que se anuncia.
- El certificado del PC es autofirmado: se acepta al elegir el PC y queda fijado. Si cambia, el envío se para y pide volver a buscarlo.
- Sube con `prepare-upload` y `upload` (3 archivos a la vez) desde un servicio en primer plano, con progreso en la app y en la notificación. Si el PC cambió de IP, lo vuelve a buscar por su huella.

Probado contra LocalSend CLI 1.18.2: registro con mTLS, `prepare-upload` y subida correctos. El CLI guarda los archivos sin la carpeta; la app de escritorio la conserva.

## Desarrollo

Requisitos: Flutter 3.50 (Dart 3.14), JDK 21 y Android SDK 36.

```bash
flutter pub get
flutter analyze
flutter test                      # lógica pura: links, formatos, MP4/DASH, búsqueda, errores
flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm
```

Los APK quedan en `build/app/outputs/flutter-apk/` (`app-arm64-v8a-release.apk` para casi todos los teléfonos actuales). La firma de release sale de `android/key.properties` (fuera del repo). Sin ese archivo se firma con la clave de debug.

`minSdk` es 29 (Android 10) para guardar en Música, Películas y Descargas sin pedir permisos de almacenamiento.
