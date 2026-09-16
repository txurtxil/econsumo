# eConsumo

App Android (Flutter) para controlar el consumo eléctrico doméstico en España con
datos oficiales. Proyecto personal y de código abierto.

## Qué hace

- **Consumo horario real** desde la API oficial de [Datadis](https://datadis.es)
  (plataforma de las distribuidoras españolas). Conexión 100% manual: solo descarga
  cuando el usuario pulsa "CONECTAR Y ACTUALIZAR".
- **Factura estimada del ciclo** (energía + potencia + bono social + alquiler +
  impuestos), verificada al céntimo contra facturas reales de Octopus Energy.
- **Comparador de tarifas de factura completa** con el consumo horario real del ciclo
  (PVPC vía E-SIOS/REE, Octopus Relax/Flexi/3 Periodos, Iberdrola Noche).
- **Exportación CSV** en formato i-DE para el comparador oficial de la CNMC.
- **Widget de escritorio** nativo: fechas del ciclo, € gastados, kWh, predicción de
  fin de ciclo, gráfica de los últimos 7 días y periodo tarifario actual
  (valle/llano/punta).
- **Caché local por mes**: funciona sin conexión y aunque Datadis esté caído.

## Privacidad

Las credenciales de Datadis se guardan cifradas en el Keystore de Android
(`flutter_secure_storage`). Los datos de consumo viven solo en el dispositivo.
La app habla únicamente con `datadis.es` y `api.esios.ree.es`.
Ver [PRIVACY.md](PRIVACY.md).

## Compilación

```bash
flutter clean && flutter pub get && flutter build apk --profile
# APK: build/app/outputs/flutter-apk/app-profile.apk
```

Toolchain: Flutter 3.44.3 (stable), Android SDK 36, Java 17.

## Releases

Los APK firmados se publican en
[Releases](https://github.com/txurtxil/econsumo/releases). La versión visible de la
app es la constante `kAppVersion` de `lib/main.dart`, sincronizada con
`version:` de `pubspec.yaml` (versionCode = mayor·10000 + menor·100 + parche).
