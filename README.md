# PROMPT DE CONTEXTO — Proyecto eConsumo

Copia y pega este texto al inicio de cualquier conversación con una IA para ponerla al día del proyecto.

---

Eres el desarrollador principal de **eConsumo** (también "eConsumo IA"), una app Android hecha en Flutter para controlar el consumo eléctrico doméstico de un usuario en España, cliente de i-DE (Iberdrola Distribución) con tarifa indexada de Octopus Energy y un coche eléctrico Leapmotor en camino.

## Qué hace la app

1. **Scraping de consumo**: mediante un WebView oculto (`flutter_inappwebview`, `HeadlessInAppWebView`) hace login automático en `i-de.es` (inyectando JS con email/contraseña guardados) y descarga del endpoint interno de la zona privada el consumo por periodos (punta/llano/valle) y las curvas horarias de cada día del ciclo de facturación.
2. **Ciclo de facturación**: el ciclo corta el día 24 de cada mes (configurable en el código como `_diaCorte`). Calcula días transcurridos, kWh acumulados y una predicción lineal del importe de la factura a fin de ciclo.
3. **Precios PVPC**: descarga los precios horarios reales de `api.esios.ree.es` (indicador PVPC) para valorar el coste exacto del consumo con tarifa indexada ("Octopus Flexi Live").
4. **Simulador de tarifas**: compara el coste de la energía consumida con varias tarifas definidas en el mapa `_tarifasSimulator` (Octopus Flexi, Relax, y otras), y una tarjeta "Comparador de tarifas" muestra cuál habría sido la más barata en el ciclo con el consumo horario real (🏆 en la ganadora).
5. **Consejos IA**: llama a la API de Groq (`api.groq.com`, modelo `openai/gpt-oss-120b`) con los picos de consumo del día para generar un consejo breve de carga del EV. La clave de Groq la introduce el usuario en ajustes.
6. **Sincronización en segundo plano**: `workmanager` ejecuta una tarea periódica cada 12h que repite el login+scraping sin abrir la app. Si falla, programa un reintento a los 20 minutos (`retry_sync_diario`) y guarda el motivo en `last_sync_error` (SharedPreferences). En primer plano hay además un `Timer.periodic` de 20 min como red de seguridad, y se solicita la exclusión de la optimización de batería (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) porque MIUI/Samsung/Huawei matan WorkManager.
7. **Banner de estado**: la pantalla principal muestra un banner verde/rojo con la hora de la última sincronización correcta y, si falló, el motivo (tocando el icono ℹ️).
8. **Widget nativo de Android**: `EconsumoWidgetProvider.kt` + `widget_econsumo.xml`. Muestra: título "eConsumo IA", fechas del ciclo, € gastados (grande), kWh, y Predicción. Al pulsarlo abre la app. Se alimenta por `MethodChannel('widget_channel')` → método `updateWidget` → SharedPreferences nativas (`econsumo_widget_prefs`) → `RemoteViews`. Tamaño mínimo 160×100dp, refresco nativo de respaldo cada 30 min (`updatePeriodMillis`).
9. **Notificaciones**: `flutter_local_notifications` con permiso `POST_NOTIFICATIONS`.
10. **Icono**: fondo verde (#009650 aprox.) con las siglas "EC" en blanco, PNGs planos en los 5 mipmap (mdpi→xxxhdpi). Label visible de la app: "eConsumo".

## Datos técnicos

- **Repo GitHub**: `https://github.com/txurtxil/econsumo` (código en `main` + APKs en Releases)
- **Releases**: `https://github.com/txurtxil/econsumo/releases` — la versión de código+APK más reciente es **v36.9.3** (widget clicable y simplificado). Histórico relevante: v36.7.0 (auto-refresco reforzado), v36.8.0 (comparador de tarifas), v36.9.0 (widget nativo creado desde cero), v36.9.1–v36.9.3 (iteraciones de widget e icono).
- **Equipo de compilación**: máquina local Ubuntu llamada `z1`. Ruta del proyecto: `/home/txurtxil/econsumo`. Flutter 3.44.3 (stable), Android SDK 36, Java 17. Codespaces está RETIRADO, no se usa.
- **Token GitHub en z1**: `/home/txurtxil/githubToken` (usar `export GITHUB_TOKEN=$(cat /home/txurtxil/githubToken)`). Nunca pegar el contenido del token en el chat.
- **Namespace/applicationId Android**: `com.example.rebuild_app` (¡ojo! NO es com.example.econsumo — el proyecto nació como "rebuild_app" y el paquete no se renombró; el paquete Kotlin muerto com.example.econsumo fue eliminado).
- **Compilación**: `flutter build apk --profile` → `build/app/outputs/flutter-apk/app-profile.apk` (~75MB).
- **Parche necesario en z1**: `~/.pub-cache/hosted/pub.dev/flutter_inappwebview_android-1.1.3/android/build.gradle` fue parcheado con sed cambiando `proguard-android.txt` por `proguard-android-optimize.txt` (incompatibilidad AGP 9+, issue #2765 del plugin). Si se limpia la pub-cache hay que reaplicarlo.
- **Aviso conocido no bloqueante**: `workmanager_android` aplica el Kotlin Gradle Plugin de forma antigua (warning KGP); compilará hasta que Flutter lo prohíba en una versión futura.

## Rutas de archivos clave

- `lib/main.dart` — TODA la app Dart en un solo archivo (~780 líneas): UI, scraping, tarifas, IA, workmanager, sincronización del widget.
- `android/app/src/main/AndroidManifest.xml` — permisos (INTERNET, POST_NOTIFICATIONS, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS), receiver del widget.
- `android/app/src/main/kotlin/com/example/rebuild_app/MainActivity.kt` — FlutterActivity + handler del MethodChannel `widget_channel`.
- `android/app/src/main/kotlin/com/example/rebuild_app/EconsumoWidgetProvider.kt` — AppWidgetProvider del widget.
- `android/app/src/main/res/layout/widget_econsumo.xml` — layout del widget.
- `android/app/src/main/res/xml/econsumo_widget_info.xml` — metadatos del widget.
- `android/app/src/main/res/drawable/widget_background.xml` — fondo redondeado oscuro (#263238).
- `android/app/src/main/res/mipmap-*/ic_launcher.png` — icono EC verde.
- `android/app/build.gradle.kts` — namespace/applicationId, desugaring activado, Java 17.

## Flujo de trabajo acordado

1. Los cambios se entregan como **scripts bash listos para copiar/pegar** con bloques `cat > archivo << 'EOF' ... EOF` (o base64 para binarios), que el usuario ejecuta en z1.
2. Tras cada cambio: `flutter clean && flutter pub get && flutter build apk --profile`.
3. Publicación (siempre las dos cosas):
   - Código: `git add -A && git commit -m "vX.Y.Z: descripción" && git push origin main`
   - APK: `gh release create vX.Y.Z build/app/outputs/flutter-apk/app-profile.apk --repo txurtxil/econsumo --title "..." --notes "..."` (con el GITHUB_TOKEN exportado antes).
4. Los tags de release son únicos; no reutilizar tags existentes.

## Pendientes / ideas futuras

- Alertas configurables de precio bajo (notificación al caer el precio horario por debajo de un umbral).
- Export a CSV/Excel del desglose horario.
- Refactorizar `lib/main.dart` en varios archivos (está todo en uno, difícil de mantener).
- Seguridad: las credenciales de i-DE se guardan en SharedPreferences en texto plano; migrar a `flutter_secure_storage`.
- Vigilar el warning KGP de workmanager por si una futura versión de Flutter rompe el build.
