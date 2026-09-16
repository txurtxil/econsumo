import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:workmanager/workmanager.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

const String kAppVersion = '38.7.0';

// Credenciales de Datadis en almacenamiento seguro (Keystore de Android).
// Antes iban en SharedPreferences en texto plano (pendiente de seguridad nº1).
const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// RESTAURAMOS EL DÍA DE CORTE AL 24 TRAS EL CAMBIO DE POTENCIA DEFINITIVO
int DIA_CORTE_OCTOPUS = 24; // Configurable desde la app (guardado en prefs como 'dia_corte')

bool _esFestivoNacional(DateTime d) {
  final festivos = {
    "2024-01-01", "2024-01-06", "2024-03-29", "2024-05-01", "2024-08-15",
    "2024-10-12", "2024-11-01", "2024-12-06", "2024-12-08", "2024-12-25",
    "2025-01-01", "2025-01-06", "2025-04-18", "2025-05-01", "2025-08-15",
    "2025-10-12", "2025-11-01", "2025-12-06", "2025-12-08", "2025-12-25",
  };
  String k = "${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}";
  return festivos.contains(k);
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final prefs = await SharedPreferences.getInstance();
    
    const AndroidInitializationSettings initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initAndroid));


    if (task == "fetchConsumoTask" || task == "econsumo_sync_diario" || task == "retry_sync_diario") {
        // Sincronización en 2º plano vía API oficial de Datadis (sin scraping).
        final String nif = await _secureStorage.read(key: 'email') ?? ''; final String pass = await _secureStorage.read(key: 'pass') ?? '';
        if (nif.isEmpty || pass.isEmpty) return Future.value(true);
        DIA_CORTE_OCTOPUS = prefs.getInt('dia_corte') ?? 24;
        bool success = false; String errorMsg = '';
        try {
          final rTok = await http.post(Uri.parse('https://datadis.es/nikola-auth/tokens/login'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: {'username': nif, 'password': pass}).timeout(const Duration(seconds: 30));
          if (rTok.statusCode != 200 || rTok.body.trim().isEmpty) {
            errorMsg = 'Login Datadis HTTP ${rTok.statusCode}';
          } else {
            final token = rTok.body.trim();
            final rSup = await http.get(Uri.parse('https://datadis.es/api-private/api/get-supplies'),
                headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'}).timeout(const Duration(seconds: 60));
            if (rSup.statusCode != 200) {
              errorMsg = 'get-supplies HTTP ${rSup.statusCode}';
            } else {
              final List sup = jsonDecode(utf8.decode(rSup.bodyBytes));
              if (sup.isEmpty) {
                errorMsg = 'Sin suministros';
              } else {
                final String cups = sup.first['cups'].toString();
                final String dist = sup.first['distributorCode'].toString();
                final String pt = (sup.first['pointType'] ?? 5).toString();
                DateTime now = DateTime.now(); DateTime startC;
                if (now.day >= DIA_CORTE_OCTOPUS) { startC = DateTime(now.year, now.month, DIA_CORTE_OCTOPUS); } else { startC = DateTime(now.year, now.month - 1, DIA_CORTE_OCTOPUS); }
                DateTime endC = now.subtract(const Duration(days: 1)); if (endC.isBefore(startC)) endC = startC;
                final Set<String> meses = {};
                for (DateTime c = startC; !c.isAfter(endC); c = c.add(const Duration(days: 1))) { meses.add("${c.year}/${c.month.toString().padLeft(2, '0')}"); }
                double kwh = 0.0; Map<String, double> kwhDia = {}; DateTime? ultimo;
                for (final m in meses) {
                  final url = 'https://datadis.es/api-private/api/get-consumption-data?cups=$cups&distributorCode=$dist&startDate=$m&endDate=$m&measurementType=0&pointType=$pt';
                  final rc = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'}).timeout(const Duration(seconds: 90));
                  if (rc.statusCode != 200) { errorMsg = 'consumo $m HTTP ${rc.statusCode}'; continue; }
                  for (final e in (jsonDecode(utf8.decode(rc.bodyBytes)) as List)) {
                    try {
                      final f = e['date'].toString().replaceAll('-', '/'); final pz = f.split('/');
                      final dt = DateTime(int.parse(pz[0]), int.parse(pz[1]), int.parse(pz[2]));
                      if (dt.isBefore(startC) || dt.isAfter(endC)) continue;
                      final c = double.tryParse(e['consumptionKWh'].toString()) ?? 0.0;
                      kwh += c; kwhDia[f] = (kwhDia[f] ?? 0) + c;
                      if (c > 0 && (ultimo == null || dt.isAfter(ultimo))) ultimo = dt;
                    } catch (_) {}
                  }
                }
                if (kwh > 0) {
                  if (ultimo != null) endC = ultimo;
                  int dias = endC.difference(startC).inDays + 1; if (dias <= 0) dias = 1;
                  // Tarifa Octopus Relax: precio único 24h
                  double coste = kwh * 0.103;
                  double costeFijoPotencia = (4.4 + 5.7) * 0.093 * dias;
                  double costeFijoExtra = (0.01274 + 0.04452) * dias;
                  double total = (coste + costeFijoPotencia + costeFijoExtra) * 1.05113 * 1.21;
                  DateTime finCiclo = DateTime(startC.year, startC.month + 1, DIA_CORTE_OCTOPUS).subtract(const Duration(days: 1));
                  int diasTotales = finCiclo.difference(startC).inDays + 1;
                  double pred = (total / dias) * diasTotales;
                  final claves = kwhDia.keys.toList()..sort();
                  final ult7 = claves.length > 7 ? claves.sublist(claves.length - 7) : claves;
                  final grafica = ult7.map((k) { final pz = k.split('/'); return "${pz[2]}/${pz[1]}|${kwhDia[k]!.toStringAsFixed(2)}"; }).join(";");
                  await flutterLocalNotificationsPlugin.show(0, "Ciclo: ${total.toStringAsFixed(2)} €", "${kwh.toStringAsFixed(1)} kWh · Predicción ${pred.toStringAsFixed(2)} €",
                      const NotificationDetails(android: AndroidNotificationDetails('econsumo_ch', 'eConsumo', importance: Importance.low, priority: Priority.low)));
                  try {
                    const MethodChannel channel = MethodChannel('widget_channel');
                    await channel.invokeMethod('updateWidget', {
                      'fechas': "${startC.day.toString().padLeft(2, '0')}/${startC.month.toString().padLeft(2, '0')} al ${endC.day.toString().padLeft(2, '0')}/${endC.month.toString().padLeft(2, '0')}",
                      'euros': "${total.toStringAsFixed(2)} €",
                      'kwh': "${kwh.toStringAsFixed(1)} kWh",
                      'prediccion': "Predicción: ${pred.toStringAsFixed(2)} €",
                      'consejo': '', 'grafica': grafica,
                    });
                  } catch (_) {}
                  success = true;
                } else if (errorMsg.isEmpty) {
                  errorMsg = 'Datadis devolvió 0 kWh para el ciclo';
                }
              }
            }
          }
        } catch (e) { errorMsg = 'Excepción: $e'; }

        if (success) {
          await prefs.setString('last_sync_ts', DateTime.now().toIso8601String());
          await prefs.remove('last_sync_error');
        } else {
          if (errorMsg.isEmpty) errorMsg = 'Fallo desconocido en sync Datadis';
          await prefs.setString('last_sync_error', '${DateTime.now().toIso8601String()}|$errorMsg');
          // Sin reintento automático: el usuario reconecta a mano cuando quiera.
        }
        return Future.value(success);
    }
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const AndroidInitializationSettings initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initAndroid));
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  // Sin sincronización automática: el usuario decide cuándo conectar (evita
  // saturar la API de Datadis y cualquier riesgo de bloqueo por accesos automáticos).
  Workmanager().cancelAll();
  final prefs = await SharedPreferences.getInstance();
  // Migración única: si el NIF/contraseña siguen en SharedPreferences (texto
  // plano), se mueven al almacenamiento seguro y se borran de ahí.
  final migEmail = prefs.getString('email');
  final migPass = prefs.getString('pass');
  if (migEmail != null || migPass != null) {
    if (migEmail != null) await _secureStorage.write(key: 'email', value: migEmail);
    if (migPass != null) await _secureStorage.write(key: 'pass', value: migPass);
    await prefs.remove('email');
    await prefs.remove('pass');
  }
  final savedEmail = await _secureStorage.read(key: 'email') ?? '';
  final savedPass = await _secureStorage.read(key: 'pass') ?? '';
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF00E5FF)), home: MainOrchestrator(savedEmail: savedEmail, savedPass: savedPass)));
}

class MainOrchestrator extends StatefulWidget {
  final String savedEmail; final String savedPass;
  const MainOrchestrator({super.key, required this.savedEmail, required this.savedPass});
  @override
  State<MainOrchestrator> createState() => _MainOrchestratorState();
}

class _MainOrchestratorState extends State<MainOrchestrator> {
  late String _email; late String _pass;
  bool _isLoggedIn = false;
  String _status = "Calculando Ciclo..."; 
  
  double _kwhTotal = 0.0; double _kwhValle = 0.0; double _kwhLlano = 0.0; double _kwhPunta = 0.0;
  double _costeEnergia = 0.0; double _costePotencia = 0.0;
  double _cuotaOctopus = 0.0; 
  final double _impuestoElectrico = 1.05113; final double _iva = 1.21;

  // --- TARIFA OCTOPUS RELAX (precio único 24h, sin impuestos) ---
  static const double kPrecioUnicoKwh = 0.103;       // €/kWh, igual a todas horas
  static const double kPrecioPotenciaDia = 0.093;    // €/kW/día, P1 y P2 iguales
  static const double kPotenciaP1 = 4.4; static const double kPotenciaP2 = 5.7; // kW contratados
  static const double kBonoSocialDia = 0.01274; static const double kAlquilerContadorDia = 0.04452;
  
  List<Map<String, dynamic>> _topHoras = []; List<Map<String, dynamic>> _desgloseDiario = []; 
  Map<String, List<double>> _horasPorDia = {}; List<double> _promedioPorHora = []; 
  
  List<Map<String, DateTime>> _ciclosDisponibles = [];
  int _cicloSeleccionadoIndex = 0;
  
  late DateTime _cycleStart; late DateTime _cycleEnd; late DateTime _fetchEnd;
  Map<String, List<double>> _preciosHistoricos = {}; double _costeExactoFlexi = 0.0;
  
  String _tarifaSeleccionada = 'Octopus Relax';
  int _diasCalculo = 0;
  final Map<String, Map<String, double>> _tarifasSimulator = { 
    // Energía todo incluido (peaje + cargos + margen), SIN impuestos.
    // Flexi: precios publicados por Octopus a 15/07/2026 (0,272/0,191/0,172
    // con impuestos ÷ 1,2719). OJO: Flexi es INDEXADA y cambia cada mes;
    // en la factura de junio eran 0,181/0,104/0,089 (mercado más barato).
    'Octopus Flexi': {'p': 0.214, 'l': 0.150, 'v': 0.135},
    'Octopus Relax': {'p': kPrecioUnicoKwh, 'l': kPrecioUnicoKwh, 'v': kPrecioUnicoKwh}, 
    'Oct. 3 Periodos': {'p': 0.162, 'l': 0.114, 'v': 0.076}, 
    'Iberdrola Noche': {'p': 0.205, 'l': 0.205, 'v': 0.108},
    'PVPC (e-SIOS real)': {'p': 0.0, 'l': 0.0, 'v': 0.0},
  };

  // Potencia (€/kW/día) y otros fijos (€/día). AQUÍ está la trampa del €/kWh:
  // Relax cobra 0,093 en P1 y P2; Flexi 0,076 y 0,002 (mucho más barato).
  final Map<String, Map<String, double>> _terminosFijos = {
    'Octopus Flexi':      {'potP1': 0.076, 'potP2': 0.002, 'extraDia': 0.169},
    'Octopus Relax':      {'potP1': 0.093, 'potP2': 0.093, 'extraDia': 0.05726},
    'Oct. 3 Periodos':    {'potP1': 0.093, 'potP2': 0.093, 'extraDia': 0.05726},
    'Iberdrola Noche':    {'potP1': 0.104, 'potP2': 0.011, 'extraDia': 0.05726},
    'PVPC (e-SIOS real)': {'potP1': 0.076, 'potP2': 0.002, 'extraDia': 0.05726},
  };

  final TextEditingController _deviceCtrl = TextEditingController();
  List<Map<String, dynamic>> _logsDispositivos = [];


  final List<String> _logs = []; final ScrollController _logScrollController = ScrollController();

  DateTime? _lastSyncTime; String? _lastSyncError; Timer? _autoRefreshTimer;
  DateTime? _proximaDescargaMes; // hora a la que el mes en curso volverá a poder descargarse (últ. descarga + 24h)
  bool _conectando = false; String _cups = '';
  String _datadisCups = ''; String _datadisDistCode = ''; String _datadisPointType = '5';
  Map<String, double> _comparadorTarifas = {};

  @override
  void initState() {
    super.initState();
    _email = widget.savedEmail; _pass = widget.savedPass;
    _solicitarPermisosNativos(); _loadDeviceLogs(); _calcularFechasCiclo(); _cargarEstadoSincronizacion(); _cargarTarifaGuardada();
    
    _addLog("eConsumo v$kAppVersion. Credenciales en almacenamiento seguro.");
    // Sin sincronización automática: el usuario decide cuándo conectar
    // (botón o tirar para refrescar). WorkManager está cancelado al arrancar.
  }

  // ============================================================
  //   DATADIS — API OFICIAL DE LAS DISTRIBUIDORAS (sustituye al
  //   scraping de i-DE, que provocaba bloqueos de cuenta).
  //   Doc: https://datadis.es  ·  Auth: NIF + contraseña Datadis
  // ============================================================
  static const String _kDatadisHost = 'https://datadis.es';

  // IMPORTANTE: el paquete http de Dart NO envía cabecera Accept por defecto
  // (curl sí manda Accept: */*). Sin ella, Datadis responde 400 "Parámetro en
  // cabecera requerido en estado vacío". No quitar.
  Map<String, String> _cabecerasDatadis(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  // Periodos 2.0TD: 1=punta, 2=llano, 3=valle. (Festivos nacionales
  // no contemplados: cuentan como laborable. Con Relax el precio es
  // plano, así que esto es solo estadística.)
  int _periodoTarifario(DateTime d, int h) {
    if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) return 3;
    if ((h >= 10 && h < 14) || (h >= 18 && h < 22)) return 1;
    if ((h >= 8 && h < 10) || (h >= 14 && h < 18) || h >= 22) return 2;
    return 3;
  }

  // Un mes cacheado MIENTRAS estaba en curso queda incompleto (le faltan los
  // últimos días). Al cerrarse el mes no basta con darlo por bueno: hay que
  // comprobar que contiene todos sus días, o esos huecos serían permanentes.
  bool _mesCompleto(String mes, List<dynamic> registros) {
    final int y = int.parse(mes.split('/')[0]), m = int.parse(mes.split('/')[1]);
    final int diasDelMes = DateTime(y, m + 1, 0).day;
    final Set<String> dias = {};
    for (final e in registros) {
      try { dias.add(e['date'].toString()); } catch (_) {}
    }
    return dias.length >= diasDelMes;
  }

  List<String> _mesesDelRango(String mesIni, String mesFin) {
    final List<String> meses = [];
    int y = int.parse(mesIni.split('/')[0]), m = int.parse(mesIni.split('/')[1]);
    final int yF = int.parse(mesFin.split('/')[0]), mF = int.parse(mesFin.split('/')[1]);
    while (y < yF || (y == yF && m <= mF)) {
      meses.add("$y/${m.toString().padLeft(2, '0')}");
      m++; if (m > 12) { m = 1; y++; }
      if (meses.length > 24) break;
    }
    return meses;
  }

  // Lee de caché los meses pedidos. Devuelve null si falta alguno "fresco".
  // Clave del diseño: esto NO toca la red, así que funciona con Datadis caído.
  Future<List<dynamic>?> _leerCacheMeses(List<String> meses) async {
    final prefs = await SharedPreferences.getInstance();
    final ahora = DateTime.now();
    final String mesActual = "${ahora.year}/${ahora.month.toString().padLeft(2, '0')}";
    final List<dynamic> out = [];
    for (final mes in meses) {
      final cached = prefs.getString('cache_mes_$mes');
      if (cached == null) return null;
      final ts = prefs.getInt('cache_mes_ts_$mes') ?? 0;
      final edadH = (ahora.millisecondsSinceEpoch - ts) / 3600000.0;
      final bool cerrado = mes != mesActual;
      if (!cerrado && edadH >= 12) return null; // el mes en curso conviene refrescarlo
      try {
        final regs = jsonDecode(cached) as List<dynamic>;
        if (cerrado && !_mesCompleto(mes, regs)) return null; // caché incompleta: hay que ir a la red
        out.addAll(regs);
      } catch (_) { return null; }
    }
    return out;
  }

  // Último recurso: todo lo que haya en caché, sin importar la antigüedad.
  Future<List<dynamic>> _leerCacheMesesForzado(List<String> meses) async {
    final prefs = await SharedPreferences.getInstance();
    final List<dynamic> out = [];
    for (final mes in meses) {
      final cached = prefs.getString('cache_mes_$mes');
      if (cached == null) continue;
      try { out.addAll(jsonDecode(cached) as List<dynamic>); } catch (_) {}
    }
    return out;
  }

  Future<String?> _datadisLogin() async {
    try {
      final r = await http.post(
        Uri.parse('$_kDatadisHost/nikola-auth/tokens/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'username': _email, 'password': _pass},
      ).timeout(const Duration(seconds: 30));
      final cuerpo = r.body.trim();
      if (r.statusCode == 200 && cuerpo.startsWith('eyJ')) { _addLog("Datadis: token JWT válido (${cuerpo.length} chars)."); return cuerpo; }
      if (r.statusCode == 200) { _addLog("Datadis: HTTP 200 pero el cuerpo NO es un JWT → ${cuerpo.substring(0, cuerpo.length > 120 ? 120 : cuerpo.length)}"); return null; }
      _addLog("Datadis: login HTTP ${r.statusCode} → ${cuerpo.substring(0, cuerpo.length > 160 ? 160 : cuerpo.length)}");
    } catch (e) { _addLog("Datadis: error de red en login → $e"); }
    return null;
  }

  Future<bool> _datadisSupplies(String token) async {
    try {
      final r = await http.get(Uri.parse('$_kDatadisHost/api-private/api/get-supplies'),
          headers: _cabecerasDatadis(token)).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) { final b = r.body.trim(); _addLog("Datadis: get-supplies HTTP ${r.statusCode} → ${b.substring(0, b.length > 200 ? 200 : b.length)}"); return false; }
      final List d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d.isEmpty) { _addLog("Datadis: no hay suministros asociados a tu NIF."); return false; }
      Map s = d.first;
      if (_cups.isNotEmpty) {
        for (final e in d) {
          if (e['cups'].toString().toUpperCase().startsWith(_cups.toUpperCase().substring(0, _cups.length > 20 ? 20 : _cups.length))) { s = e; break; }
        }
      }
      _datadisCups = s['cups'].toString();
      _datadisDistCode = s['distributorCode'].toString();
      _datadisPointType = (s['pointType'] ?? 5).toString();
      if (_cups.isEmpty) {
        _cups = _datadisCups;
        (await SharedPreferences.getInstance()).setString('cups', _cups);
      }
      final pf = await SharedPreferences.getInstance();
      await pf.setString('sup_cups', _datadisCups);
      await pf.setString('sup_dist', _datadisDistCode);
      await pf.setString('sup_pt', _datadisPointType);
      _addLog("Datadis: suministro OK (dist. $_datadisDistCode, tipo $_datadisPointType).");
      return true;
    } catch (e) { _addLog("Datadis: error en get-supplies → $e"); return false; }
  }

  // Caché POR MES (no por rango): así los datos de un mes sirven para cualquier
  // ciclo que lo incluya. Datadis limita a 1 consulta idéntica cada 24h (429),
  // de modo que sin esto un cambio de día de corte deja la app sin datos.
  // Los meses cerrados no cambian nunca -> caché permanente.
  Future<List<dynamic>> _datadisConsumo(String token, String mesIni, String mesFin) async {
    final prefs = await SharedPreferences.getInstance();
    final ahora = DateTime.now();
    final String mesActual = "${ahora.year}/${ahora.month.toString().padLeft(2, '0')}";

    // Lista de meses del rango
    final List<String> meses = [];
    int y = int.parse(mesIni.split('/')[0]), m = int.parse(mesIni.split('/')[1]);
    final int yF = int.parse(mesFin.split('/')[0]), mF = int.parse(mesFin.split('/')[1]);
    while (y < yF || (y == yF && m <= mF)) {
      meses.add("$y/${m.toString().padLeft(2, '0')}");
      m++; if (m > 12) { m = 1; y++; }
      if (meses.length > 24) break;
    }

    final List<dynamic> resultado = [];
    final List<String> faltantes = [];
    for (final mes in meses) {
      final cached = prefs.getString('cache_mes_$mes');
      final ts = prefs.getInt('cache_mes_ts_$mes') ?? 0;
      final edadH = (ahora.millisecondsSinceEpoch - ts) / 3600000.0;
      final bool cerrado = mes != mesActual;
      if (cached != null && (cerrado || edadH < 12)) {
        try {
          final regs = jsonDecode(cached) as List<dynamic>;
          if (cerrado && !_mesCompleto(mes, regs)) {
            _addLog("Datadis: caché de $mes incompleta (se guardó con el mes en curso). Se vuelve a pedir.");
          } else {
            resultado.addAll(regs);
            _addLog("Datadis: $mes desde caché${cerrado ? ' (mes cerrado)' : ' (${edadH.toStringAsFixed(1)}h)'}.");
            continue;
          }
        } catch (_) {}
      }
      faltantes.add(mes);
    }

    if (faltantes.isEmpty) return resultado;

    final DateTime ahoraDt = DateTime.now();
    final String mesEnCurso = "${ahoraDt.year}/${ahoraDt.month.toString().padLeft(2, '0')}";

    String pedIni, pedFin;
    if (faltantes.length == 1 && faltantes.first == mesEnCurso) {
      // Caso habitual del día a día: solo falta refrescar el mes actual.
      // Pedimos SOLO ese mes: la consulta cambia de contenido según avanza el
      // mes y no depende de la ventana grande (que solo sirve 1 vez/24h).
      pedIni = pedFin = mesEnCurso;
      _addLog("Datadis: refrescando mes en curso $mesEnCurso...");
    } else {
      // Falta histórico: ventana de 12 meses que termina en el último que falta.
      // (1) esquiva el 429 de consultas estrechas ya gastadas, (2) cachea todo
      // el histórico de un viaje, (3) da los 12 meses que pide la CNMC.
      pedFin = faltantes.last;
      final int yF2 = int.parse(pedFin.split('/')[0]), mF2 = int.parse(pedFin.split('/')[1]);
      final DateTime ini12 = DateTime(yF2, mF2 - 11, 1);
      pedIni = "${ini12.year}/${ini12.month.toString().padLeft(2, '0')}";
      _addLog("Datadis: descargando $pedIni → $pedFin (ventana de 12 meses)...");
    }
    final url = '$_kDatadisHost/api-private/api/get-consumption-data'
        '?cups=$_datadisCups&distributorCode=$_datadisDistCode'
        '&startDate=$pedIni&endDate=$pedFin&measurementType=0&pointType=$_datadisPointType';
    try {
      final r = await http.get(Uri.parse(url), headers: _cabecerasDatadis(token)).timeout(const Duration(seconds: 120));
      if (r.statusCode == 200) {
        final datos = jsonDecode(utf8.decode(r.bodyBytes)) as List<dynamic>;
        // Repartimos por mes y cacheamos cada uno por separado
        final Map<String, List<dynamic>> porMes = {};
        for (final e in datos) {
          try {
            final p = e['date'].toString().replaceAll('-', '/').split('/');
            porMes.putIfAbsent("${p[0]}/${p[1]}", () => []).add(e);
          } catch (_) {}
        }
        for (final entry in porMes.entries) {
          await prefs.setString('cache_mes_${entry.key}', jsonEncode(entry.value));
          await prefs.setInt('cache_mes_ts_${entry.key}', ahora.millisecondsSinceEpoch);
        }
        _addLog("Datadis: ${datos.length} registros nuevos, cacheados ${porMes.keys.length} mes(es).");
        resultado.addAll(datos);
        return resultado;
      }
      if (r.statusCode == 429) {
        _addLog("Datadis: límite 24h (429) para $pedIni-$pedFin.");
      } else {
        final b = r.body.trim();
        _addLog("Datadis: consumo HTTP ${r.statusCode} → ${b.substring(0, b.length > 160 ? 160 : b.length)}");
      }
    } catch (e) { _addLog("Datadis: error de red → $e"); }

    // Falló: rescatamos de caché lo que haya, aunque esté vieja
    for (final mes in faltantes) {
      final cached = prefs.getString('cache_mes_$mes');
      if (cached != null) {
        try {
          resultado.addAll(jsonDecode(cached) as List<dynamic>);
          _addLog("Datadis: $mes recuperado de caché antigua.");
        } catch (_) {}
      }
    }
    return resultado;
  }

  Future<void> _conectarAhora() async {
    if (_conectando) return;
    if (_email.isEmpty || _pass.isEmpty) { _addLog("Faltan credenciales de Datadis."); return; }
    setState(() { _conectando = true; _status = "Preparando datos..."; });
    _addLog("Datadis: actualización solicitada.");

    final int diasCiclo = _cycleEnd.difference(_cycleStart).inDays + 1;
    // Datadis rechaza meses futuros: el mes final nunca puede pasar del actual.
    final DateTime hoy = DateTime.now();
    DateTime finReal = _cycleEnd.isAfter(hoy) ? hoy : _cycleEnd;
    if (finReal.isBefore(_cycleStart)) finReal = _cycleStart;
    final String mesIni = "${_cycleStart.year}/${_cycleStart.month.toString().padLeft(2, '0')}";
    final String mesFin = "${finReal.year}/${finReal.month.toString().padLeft(2, '0')}";
    final List<String> mesesNecesarios = _mesesDelRango(mesIni, mesFin);

    // ---- PASO 1: ¿lo tenemos ya en caché? Entonces NI TOCAMOS LA RED. ----
    // Esto es esencial: la API de Datadis se cae a menudo (502/timeouts) y no
    // tiene sentido dejar al usuario sin datos que ya están en el móvil.
    List<dynamic> datos = await _leerCacheMeses(mesesNecesarios) ?? [];
    if (datos.isNotEmpty) {
      _addLog("Datadis: ${datos.length} registros desde caché (sin conexión).");
    } else {
      // ---- PASO 2: hace falta red ----
      setState(() => _status = "Autenticando en Datadis...");
      final token = await _datadisLogin();
      if (token != null) {
        _addLog("Datadis: token obtenido.");
        if (!mounted) return;
        setState(() => _status = "Leyendo suministro...");
        bool sup = _datadisCups.isNotEmpty && _datadisDistCode.isNotEmpty;
        if (sup) { _addLog("Datadis: suministro desde caché (dist. $_datadisDistCode)."); }
        else { sup = await _datadisSupplies(token); }
        if (sup) {
          if (mounted) setState(() => _status = "Descargando $mesIni a $mesFin...");
          _addLog("Datadis: pidiendo consumo $mesIni → $mesFin...");
          datos = await _datadisConsumo(token, mesIni, mesFin);
          _addLog("Datadis: ${datos.length} registros horarios recibidos.");
        }
      }
      // ---- PASO 3: si la red falló, rescatamos caché aunque esté vieja ----
      if (datos.isEmpty) {
        datos = await _leerCacheMesesForzado(mesesNecesarios);
        if (datos.isNotEmpty) _addLog("Datadis: sin red, usando ${datos.length} registros de caché antigua.");
      }
    }

    final Map<String, List<double>> porDia = {};
    DateTime? ultimoDato;
    for (final e in datos) {
      try {
        final f = e['date'].toString().replaceAll('-', '/');
        final partes = f.split('/');
        if (partes.length != 3) continue;
        final dt = DateTime(int.parse(partes[0]), int.parse(partes[1]), int.parse(partes[2]));
        final hh = int.tryParse(e['time'].toString().split(':')[0]) ?? 0;
        final idx = hh >= 1 ? hh - 1 : 0; // Datadis marca la hora FINAL del tramo
        final kwh = double.tryParse(e['consumptionKWh'].toString()) ?? 0.0;
        porDia.putIfAbsent(f, () => List.filled(24, 0.0));
        if (idx >= 0 && idx < 24) porDia[f]![idx] = kwh;
        if (kwh > 0 && (ultimoDato == null || dt.isAfter(ultimoDato))) ultimoDato = dt;
      } catch (_) {}
    }

    if (porDia.isEmpty) {
      _addLog("Datadis: sin datos para este ciclo.");
      if (mounted) setState(() { _conectando = false; _status = "Sin datos"; });
      return;
    }

    // El último día con datos manda (Datadis publica con D-1 / D-2 de retraso)
    if (ultimoDato != null && _cicloSeleccionadoIndex == 0 && ultimoDato.isBefore(_fetchEnd)) {
      _fetchEnd = ultimoDato;
      _addLog("Datadis: datos disponibles hasta ${_fetchEnd.day}/${_fetchEnd.month}.");
    }

    // Aplanamos a la estructura que ya usa la app (Wh, índice d*24+h)
    final List<dynamic> plano = [];
    double p = 0, l = 0, v = 0;
    for (int d = 0; d < diasCiclo; d++) {
      final dt = _cycleStart.add(Duration(days: d));
      final key = "${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}";
      final horas = porDia[key] ?? List.filled(24, 0.0);
      for (int h = 0; h < 24; h++) {
        plano.add(horas[h] * 1000.0);
        final per = _periodoTarifario(dt, h);
        if (per == 1) p += horas[h]; else if (per == 2) l += horas[h]; else v += horas[h];
      }
    }

    _diasCalculo = _fetchEnd.difference(_cycleStart).inDays + 1;
    if (!mounted) return;
    setState(() {
      _kwhPunta = p; _kwhLlano = l; _kwhValle = v; _kwhTotal = p + l + v;
      _isLoggedIn = true; _conectando = false; _status = "Datos actualizados";
      _lastSyncTime = DateTime.now(); _lastSyncError = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync_ts', _lastSyncTime!.toIso8601String());
    await prefs.remove('last_sync_error');
    final String mesAct = "${DateTime.now().year}/${DateTime.now().month.toString().padLeft(2, '0')}";
    final int tsM = prefs.getInt('cache_mes_ts_$mesAct') ?? 0;
    if (tsM > 0 && mounted) setState(() { _proximaDescargaMes = DateTime.fromMillisecondsSinceEpoch(tsM).add(const Duration(hours: 24)); });
    _addLog("Datadis: ${_kwhTotal.toStringAsFixed(1)} kWh (P:${p.toStringAsFixed(1)} L:${l.toStringAsFixed(1)} V:${v.toStringAsFixed(1)}).");

    _aplicarCostesFijos();
    await _descargarHistoricoPrecios();
    _procesarCurvasHorarias(plano);
  }

  Widget _pantallaConectar() {
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.power_settings_new, size: 64, color: Color(0xFF00E5FF)),
      const SizedBox(height: 16),
      const Text("Sin conexión activa", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(_lastSyncTime != null ? "Última sincronización: ${_lastSyncTime!.day}/${_lastSyncTime!.month} a las ${_lastSyncTime!.hour.toString().padLeft(2,'0')}:${_lastSyncTime!.minute.toString().padLeft(2,'0')}" : "Todavía sin datos sincronizados", style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: _conectarAhora,
        icon: const Icon(Icons.sync),
        label: const Text("CONECTAR Y ACTUALIZAR"),
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black87, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14), textStyle: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      const SizedBox(height: 12),
      // Botón de día de corte también AQUÍ: si el ciclo está mal configurado la
      // conexión falla, y sin este botón no habría forma de arreglarlo.
      OutlinedButton.icon(
        onPressed: _cambiarDiaCorte,
        icon: const Icon(Icons.edit_calendar, size: 18),
        label: Text("Ciclo: día $DIA_CORTE_OCTOPUS de cada mes", style: const TextStyle(fontSize: 12)),
      ),
      const SizedBox(height: 12),
      const Text("Los datos se descargan de Datadis solo cuando tú lo pides. No hay conexión automática.", style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.center),
    ])));
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _logScrollController.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarTarifaGuardada() async {
    final prefs = await SharedPreferences.getInstance();
    // Limpieza de las cachés antiguas por rango (v37.2.0-v38.0.0)
    for (final k in prefs.getKeys().where((k) => k.startsWith('cache_consumo_') || k.startsWith('cache_ts_')).toList()) {
      await prefs.remove(k);
    }
    final String? t = prefs.getString('tarifa_activa');
    final int? dc = prefs.getInt('dia_corte');
    final String cups = prefs.getString('cups') ?? '';
    _datadisCups = prefs.getString('sup_cups') ?? '';
    _datadisDistCode = prefs.getString('sup_dist') ?? '';
    _datadisPointType = prefs.getString('sup_pt') ?? '5';
    if (!mounted) return;
    setState(() {
      _cups = cups;
      if (t != null && _tarifasSimulator.containsKey(t)) _tarifaSeleccionada = t;
      if (dc != null && dc >= 1 && dc <= 28) { DIA_CORTE_OCTOPUS = dc; _calcularFechasCiclo(); }
    });
  }

  Future<void> _cambiarDiaCorte() async {
    int seleccionado = DIA_CORTE_OCTOPUS;
    final int? nuevo = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Día de inicio del ciclo"),
        content: StatefulBuilder(builder: (ctx2, setD) => Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("Día del mes en que empieza tu ciclo de facturación (p.ej. 13 si tu contrato Relax empezó el 13).", style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          DropdownButton<int>(value: seleccionado, isExpanded: true, items: List.generate(28, (i) => DropdownMenuItem(value: i + 1, child: Text("Día ${i + 1}"))), onChanged: (v) { if (v != null) setD(() => seleccionado = v); }),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, seleccionado), child: const Text("Guardar")),
        ],
      ),
    );
    if (nuevo == null || nuevo == DIA_CORTE_OCTOPUS) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('dia_corte', nuevo);
    if (!mounted) return;
    setState(() {
      DIA_CORTE_OCTOPUS = nuevo; _cicloSeleccionadoIndex = 0; _calcularFechasCiclo();
      _desgloseDiario.clear(); _horasPorDia.clear(); _topHoras.clear(); _promedioPorHora.clear();
      _kwhTotal = 0.0; _costeEnergia = 0.0; _costeExactoFlexi = 0.0; _diasCalculo = 0;
    });
    _addLog("Día de corte cambiado al $nuevo. Ciclos recalculados.");
    if (_isLoggedIn) _actualizarDatos();
  }

  Future<void> _cargarEstadoSincronizacion() async {
    final prefs = await SharedPreferences.getInstance();
    final String? ts = prefs.getString('last_sync_ts');
    final String? err = prefs.getString('last_sync_error');
    final ahora = DateTime.now();
    final String mesActual = "${ahora.year}/${ahora.month.toString().padLeft(2, '0')}";
    final int tsMes = prefs.getInt('cache_mes_ts_$mesActual') ?? 0;
    if (!mounted) return;
    setState(() {
      _lastSyncTime = ts != null ? DateTime.tryParse(ts) : null;
      _lastSyncError = err;
      _proximaDescargaMes = tsMes > 0 ? DateTime.fromMillisecondsSinceEpoch(tsMes).add(const Duration(hours: 24)) : null;
    });
  }
  
  void _calcularFechasCiclo() {
    DateTime now = DateTime.now();
    _ciclosDisponibles.clear();
    
    for (int i = 0; i < 6; i++) {
      DateTime start, end;
      if (now.day >= DIA_CORTE_OCTOPUS) {
        start = DateTime(now.year, now.month - i, DIA_CORTE_OCTOPUS);
        end = DateTime(now.year, now.month - i + 1, DIA_CORTE_OCTOPUS - 1);
      } else {
        start = DateTime(now.year, now.month - 1 - i, DIA_CORTE_OCTOPUS);
        end = DateTime(now.year, now.month - i, DIA_CORTE_OCTOPUS - 1);
      }
      _ciclosDisponibles.add({'start': start, 'end': end});
    }
    
    _cycleStart = _ciclosDisponibles[_cicloSeleccionadoIndex]['start']!;
    _cycleEnd = _ciclosDisponibles[_cicloSeleccionadoIndex]['end']!;
    
    if (_cicloSeleccionadoIndex == 0) {
      _fetchEnd = DateTime(now.year, now.month, now.day - 1);
      if (_fetchEnd.isBefore(_cycleStart)) _fetchEnd = _cycleStart;
    } else {
      _fetchEnd = _cycleEnd; 
    }
  }

  Future<void> _solicitarPermisosNativos() async {
    PermissionStatus status = await Permission.notification.status;
    if (!status.isGranted) await Permission.notification.request();
    // Clave: sin esto, MIUI/Samsung/Huawei matan el WorkManager en 2º plano
    // y el consumo deja de actualizarse solo. Requiere el permiso
    // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS en AndroidManifest.xml.
    PermissionStatus battery = await Permission.ignoreBatteryOptimizations.status;
    if (!battery.isGranted) await Permission.ignoreBatteryOptimizations.request();
  }
  void _addLog(String msg) { if (!mounted) return; setState(() { _logs.add("[${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}] $msg"); if (_logs.length > 50) _logs.removeAt(0); }); Future.delayed(const Duration(milliseconds: 100), () { if (_logScrollController.hasClients) _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent); }); }
  void _copiarLog() { Clipboard.setData(ClipboardData(text: _logs.join('\n'))); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Terminal copiada'))); }
  void _mostrarAcercaDe() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: const [
        Icon(Icons.bolt, color: Color(0xFF00E5FF)), SizedBox(width: 8),
        Text("eConsumo", style: TextStyle(fontWeight: FontWeight.bold)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Versión $kAppVersion", style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 12),
        const Text("Control del consumo eléctrico doméstico con datos oficiales de Datadis. Proyecto personal y de código abierto.", style: TextStyle(fontSize: 13)),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => launchUrl(Uri.parse('https://github.com/txurtxil/econsumo'), mode: LaunchMode.externalApplication),
          child: Row(children: const [
            Icon(Icons.code, size: 18, color: Colors.indigo), SizedBox(width: 8),
            Expanded(child: Text("github.com/txurtxil/econsumo", style: TextStyle(color: Colors.indigo, decoration: TextDecoration.underline, fontSize: 13))),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://ko-fi.com/txurtxil'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.local_cafe, size: 18),
          label: const Text("Invítame a un café (Ko-fi)"),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF5E5B), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
        )),
      ]),
      actions: [ TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cerrar")) ],
    ));
  }

  void _cerrarSesion() async { final prefs = await SharedPreferences.getInstance(); await _secureStorage.delete(key: 'email'); await _secureStorage.delete(key: 'pass'); await prefs.remove('last_sync_ts'); await prefs.remove('last_sync_error'); Workmanager().cancelAll(); setState(() { _email = ''; _pass = ''; _isLoggedIn = false; _conectando = false; _datadisCups = ''; _datadisDistCode = ''; _kwhTotal = 0.0; _costeEnergia = 0.0; _desgloseDiario.clear(); _horasPorDia.clear(); }); _addLog("Sesión cerrada. Credenciales borradas (la caché de consumos se conserva)."); }
  String _formatDate(DateTime d) => "${d.day.toString().padLeft(2,'0')}-${d.month.toString().padLeft(2,'0')}-${d.year}";
  String _formatDateShort(DateTime d) => "${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}";

  void _loadDeviceLogs() async { final prefs = await SharedPreferences.getInstance(); final String? data = prefs.getString('device_logs'); if (data != null) setState(() { _logsDispositivos = List<Map<String, dynamic>>.from(jsonDecode(data)); }); }
  void _saveDeviceLogs() async { final prefs = await SharedPreferences.getInstance(); await prefs.setString('device_logs', jsonEncode(_logsDispositivos)); }
  void _guardarRegistroAparato() { if (_deviceCtrl.text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pon nombre al aparato'), backgroundColor: Colors.orange)); return; } setState(() { _logsDispositivos.insert(0, { 'name': _deviceCtrl.text, 'start': DateTime.now().toIso8601String() }); _saveDeviceLogs(); _addLog("Registro: ${_deviceCtrl.text}"); _deviceCtrl.clear(); }); }
  void _exportarDatos() { Clipboard.setData(ClipboardData(text: jsonEncode(_logsDispositivos))); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copiado en JSON'), backgroundColor: Colors.green)); }
  void _importarDatos() { TextEditingController importCtrl = TextEditingController(); showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Importar JSON"), content: TextField(controller: importCtrl, maxLines: 5, decoration: const InputDecoration(border: OutlineInputBorder())), actions: [ TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")), ElevatedButton(onPressed: () { try { List<dynamic> p = jsonDecode(importCtrl.text); setState(() { _logsDispositivos.addAll(p.cast<Map<String, dynamic>>()); _logsDispositivos.sort((a, b) => DateTime.parse(b['start']).compareTo(DateTime.parse(a['start']))); }); _saveDeviceLogs(); Navigator.pop(ctx); } catch(e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error JSON'), backgroundColor: Colors.red)); } }, child: const Text("IMPORTAR")) ])); }


  Future<void> _forzarRefrescoCompleto() async {
    _addLog("Refresco manual solicitado.");
    setState(() { _isLoggedIn = false; _status = "Refrescando..."; _desgloseDiario.clear(); _horasPorDia.clear(); _costeEnergia = 0.0; _kwhTotal = 0.0; _costeExactoFlexi = 0.0; });
    await _conectarAhora();
  }


  void _recalcularCosteEnergia() { 
    if (_tarifaSeleccionada == 'PVPC (e-SIOS real)') { 
        setState(() { _costeEnergia = _costeExactoFlexi; }); 
    } else if (_tarifaSeleccionada == 'Octopus Relax') {
        // Precio único 24h: el desglose P/L/V se mantiene solo como estadística.
        setState(() { _costeEnergia = _kwhTotal * kPrecioUnicoKwh; });
    } else { 
        final precios = _tarifasSimulator[_tarifaSeleccionada]!; 
        setState(() { _costeEnergia = (_kwhPunta * precios['p']!) + (_kwhLlano * precios['l']!) + (_kwhValle * precios['v']!); }); 
    }
    _aplicarCostesFijos();
    _sincronizarWidgetNativo(); 
  }

  // Potencia + costes regulados según la tarifa activa.
  void _aplicarCostesFijos() {
    if (_diasCalculo <= 0) return;
    final fijos = _terminosFijos[_tarifaSeleccionada] ?? _terminosFijos['Octopus Relax']!;
    setState(() {
      _costePotencia = ((kPotenciaP1 * fijos['potP1']!) + (kPotenciaP2 * fijos['potP2']!)) * _diasCalculo;
      _cuotaOctopus = fijos['extraDia']! * _diasCalculo;
    });
  }
  
  Future<void> _sincronizarWidgetNativo() async { 
      double totalEuros = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; 
      int diasRegistrados = _fetchEnd.difference(_cycleStart).inDays + 1; 
      int diasTotales = _cycleEnd.difference(_cycleStart).inDays + 1; 
      double pred = diasRegistrados > 0 ? (totalEuros / diasRegistrados) * diasTotales : 0.0; 
      
      const String textoWidget = "";

      // Últimos 7 días reales (no futuros) para la gráfica del widget: "dd/MM|kwh;dd/MM|kwh;..."
      String grafica = '';
      try {
        final reales = _desgloseDiario.where((d) => d['isFuture'] == false).toList();
        final ultimos = reales.length > 7 ? reales.sublist(reales.length - 7) : reales;
        grafica = ultimos.map((d) => "${d['fecha']}|${(d['kwh'] as double).toStringAsFixed(2)}").join(";");
      } catch (e) { grafica = ''; }

      try { await const MethodChannel('widget_channel').invokeMethod('updateWidget', { 'fechas': '${_formatDateShort(_cycleStart)} al ${_formatDateShort(_fetchEnd)}', 'euros': '${totalEuros.toStringAsFixed(2)} €', 'kwh': '${_kwhTotal.toStringAsFixed(1)} kWh', 'prediccion': 'Predicción: ${pred.toStringAsFixed(2)} €', 'consejo': textoWidget, 'grafica': grafica }); } catch (e) {} 
  }


  void _procesarCurvasHorarias(List<dynamic> horas) {
    if (horas.isEmpty) {
        _addLog("I-DE: Sin datos horarios.");
        if (mounted) setState(() => _status = "Sin datos aún");
        return;
    }
    List<Map<String, dynamic>> tempDiario = []; Map<String, List<double>> tempHorasPorDia = {}; List<double> sumByHour = List.filled(24, 0.0);
    int diasRegistrados = _fetchEnd.difference(_cycleStart).inDays + 1; if (diasRegistrados <= 0) diasRegistrados = 1;
    double costeFlexiTemp = 0.0; int diasTotalesCiclo = _cycleEnd.difference(_cycleStart).inDays + 1;
    for (int d = 0; d < diasTotalesCiclo; d++) { 
        DateTime diaActual = _cycleStart.add(Duration(days: d)); String fechaStr = "${diaActual.day.toString().padLeft(2,'0')}/${diaActual.month.toString().padLeft(2,'0')}"; 
        List<double> horasDeEsteDia = []; double kwhDia = 0; 
        bool isFuture = diaActual.isAfter(_fetchEnd) || diaActual.isAfter(DateTime.now().subtract(const Duration(days: 1)));
        for (int h = 0; h < 24; h++) { 
            int idx = (d * 24) + h; double consumoH = 0.0; 
            if (!isFuture && idx < horas.length) { 
                consumoH = (double.tryParse(horas[idx].toString()) ?? 0.0) / 1000.0; sumByHour[h] += consumoH; 
                double precioAplicar = 0.10;
                if (_preciosHistoricos.containsKey(fechaStr) && h < _preciosHistoricos[fechaStr]!.length) { 
                    precioAplicar = _preciosHistoricos[fechaStr]![h]; 
                } else { 
                    if (h >= 10 && h < 14 || h >= 18 && h < 22) precioAplicar = 0.18; else if (h >= 8 && h < 10 || h >= 14 && h < 18 || h >= 22 && h <= 23) precioAplicar = 0.13; else precioAplicar = 0.08; 
                }
                costeFlexiTemp += (consumoH * precioAplicar);
            } 
            kwhDia += consumoH; horasDeEsteDia.add(consumoH); 
        } 
        tempDiario.add({'fecha': fechaStr, 'kwh': kwhDia, 'isFuture': isFuture, 'diaIndex': d}); tempHorasPorDia[fechaStr] = horasDeEsteDia; 
    }
    List<Map<String,dynamic>> horasIndexed = []; for(int h = 0; h < 24; h++){ horasIndexed.add({'hora': h, 'kwh': sumByHour[h]}); } horasIndexed.sort((a,b) => b['kwh'].compareTo(a['kwh']));
    List<double> avgByHour = sumByHour.map((val) => val / diasRegistrados).toList();
    setState(() { _desgloseDiario = tempDiario; _horasPorDia = tempHorasPorDia; _topHoras = horasIndexed.take(3).toList(); _promedioPorHora = avgByHour; _costeExactoFlexi = costeFlexiTemp; });
    _recalcularCosteEnergia(); _calcularComparadorTarifas();
  }

  // Comparador: con el consumo horario REAL ya descargado, calcula cuánto
  // habría costado la energía (sin potencia/impuestos) con cada tarifa.
  // Comparador de FACTURA COMPLETA: energía + potencia + fijos + impuestos.
  // Comparar solo €/kWh engaña: el término de potencia puede invertir el resultado.
  void _calcularComparadorTarifas() {
    if (_horasPorDia.isEmpty || _diasCalculo <= 0) return;
    Map<String, double> resultado = {};
    for (var nombreTarifa in _tarifasSimulator.keys) {
      double energia = 0.0;
      _horasPorDia.forEach((fecha, horas) {
        DateTime? dia;
        try {
          final p = fecha.split('/');
          int y = _cycleStart.year;
          if (int.parse(p[1]) < _cycleStart.month) y = _cycleStart.year + 1;
          dia = DateTime(y, int.parse(p[1]), int.parse(p[0]));
        } catch (_) {}
        for (int h = 0; h < horas.length; h++) {
          final per = dia != null ? _periodoTarifario(dia, h) : 2;
          double precio;
          if (nombreTarifa == 'PVPC (e-SIOS real)') {
            if (_preciosHistoricos.containsKey(fecha) && h < _preciosHistoricos[fecha]!.length) {
              precio = _preciosHistoricos[fecha]![h];
            } else {
              precio = per == 1 ? 0.18 : (per == 2 ? 0.13 : 0.08);
            }
          } else {
            final pr = _tarifasSimulator[nombreTarifa]!;
            precio = per == 1 ? pr['p']! : (per == 2 ? pr['l']! : pr['v']!);
          }
          energia += horas[h] * precio;
        }
      });
      final fijos = _terminosFijos[nombreTarifa]!;
      final potencia = ((kPotenciaP1 * fijos['potP1']!) + (kPotenciaP2 * fijos['potP2']!)) * _diasCalculo;
      final extras = fijos['extraDia']! * _diasCalculo;
      resultado[nombreTarifa] = (energia + potencia + extras) * _impuestoElectrico * _iva;
    }
    if (mounted) setState(() { _comparadorTarifas = resultado; });
  }

  Future<void> _descargarPrecioDia(DateTime date) async {
      String sDate = "${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}"; String fechaKey = "${date.day.toString().padLeft(2,'0')}/${date.month.toString().padLeft(2,'0')}";
      try { final res = await http.get(Uri.parse("https://api.esios.ree.es/archives/70/download?date=$sDate")); if (res.statusCode == 200) { final j = jsonDecode(res.body); List<dynamic> precios = j['PVPC']; if (precios != null && precios.length >= 24) { _preciosHistoricos[fechaKey] = precios.map((p) { return double.parse(p['PCB'].toString().replaceAll(',', '.')) / 1000.0; }).toList().sublist(0, 24); return; } } } catch(e) {}
  }

  // Descarga los precios PVPC de e-SIOS del ciclo (para la tarifa indexada).
  Future<void> _descargarHistoricoPrecios() async {
    String start = _formatDate(_cycleStart); String end = _formatDate(_fetchEnd);
    _addLog("Descargando E-SIOS ($start al $end)...");
    List<Future<void>> tareas = []; DateTime dCursor = _cycleStart; DateTime today = DateTime.now();
    DateTime fetchLimit = _fetchEnd; if (fetchLimit.isAfter(today)) fetchLimit = today;
    while (dCursor.isBefore(fetchLimit) || _formatDate(dCursor) == _formatDate(fetchLimit)) { tareas.add(_descargarPrecioDia(dCursor)); dCursor = dCursor.add(const Duration(days: 1)); }
    await Future.wait(tareas); _addLog("Histórico E-SIOS OK.");
  }

  // Punto de entrada único: ahora todo viene de Datadis.
  Future<void> _actualizarDatos() async {
    _isLoggedIn = false;
    await _conectarAhora();
  }

  Future<void> _enviarARawBT(String ticketText) async { final Uri url = Uri.parse("rawbt:base64,${base64Encode(utf8.encode(ticketText))}"); try { await launchUrl(url); _addLog("Ticket enviado."); } catch (e) { _addLog("ERROR RawBT."); } }
  void _lanzarDialogoImpresion(String ticketContent, String titulo) { showDialog(context: context, builder: (c) => AlertDialog(backgroundColor: const Color(0xFFFFFFF0), title: Row(children: [const Icon(Icons.receipt_long), const SizedBox(width: 10), Text(titulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))]), content: SingleChildScrollView(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400)), child: Text(ticketContent, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.black)))), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("CERRAR")), ElevatedButton.icon(onPressed: () { Navigator.pop(c); _enviarARawBT(ticketContent); }, icon: const Icon(Icons.print), label: const Text("IMPRIMIR RawBT"), style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white))])); }

  void _imprimirMasterPlanEV() {
      String t = "        MASTERPLAN EV       \n"
                 "------------------------------\n"
                 "1. EL VEHICULO\n"
                 "- Modelo: Leapmotor B10\n"
                 "- Bateria: 67.2 kWh\n"
                 "- Cargador: Raedian Neo 4G\n\n"
                 "2. LA INSTALACION (I-DE)\n"
                 "- P. Dia (P1/P2): 4.4 kW\n"
                 "- P. Noche (P3): 5.7 kW\n"
                 "- Max. Boletin: 5.75 kW (25A)\n"
                 "- Inversion Subida: 105.00 EUR\n\n"
                 "3. CONTRATO DE LUZ\n"
                 "- Tarifa: Octopus Flexi\n"
                 "- Tipo: Indexada (OMIE)\n\n"
                 "4. ESTRATEGIA DE CARGA\n"
                 "- Horario: 00:00h a 08:00h\n"
                 "- Potencia: Max. 5.5 kW\n"
                 "- Recarga/noche: ~45 kWh\n"
                 "- Autonomia sumada: ~260 km\n\n"
                 "5. IMPACTO ECONOMICO MENSUAL\n"
                 "- Gasto Audi Q5:   ~182.00 EUR\n"
                 "- Gasto Leapmotor: ~ 21.00 EUR\n"
                 "  (Ahorro Limpio:  ~161.00 EUR)\n\n"
                 "------------------------------\n"
                 "ATENCION INSTALADOR (26 Mayo):\n"
                 "La instalacion tiene un lImite\n"
                 "fisico y contractual de 25A \n"
                 "(5.7kW). Es OBLIGATORIO \n"
                 "configurar el Raedian Neo 4G\n"
                 "con Balanceo Dinamico activo\n"
                 "y un hard-limit de 24A para\n"
                 "evitar cortes de ICP.\n"
                 "------------------------------\n\n";
      _lanzarDialogoImpresion(t, "MasterPlan EV");
  }

  void _mostrarTicketGenerado() {
      double maxKwh = 0.001;
      for (var dia in _desgloseDiario) { if(dia['isFuture'] == false && dia['kwh'] > maxKwh) maxKwh = dia['kwh']; }

      String cabecera = _tarifaSeleccionada == 'Octopus Relax' ? "OCTOPUS RELAX v36 (precio fijo 24h)" : "OCTOPUS FLEXI v36";
      String t = "        $cabecera   \n------------------------------\nCiclo: ${_formatDate(_cycleStart)} a ${_formatDate(_cycleEnd)}\nDatos hasta: ${_formatDateShort(_fetchEnd)}\n------------------------------\n\n";
      
      double totalEurosCiclo = 0;
      double totalKwhCiclo = 0;

      for (var dia in _desgloseDiario) {
          if(dia['isFuture'] == false) {
              DateTime d = _cycleStart.add(Duration(days: dia['diaIndex']));
              bool v = d.weekday == DateTime.saturday || d.weekday == DateTime.sunday || _esFestivoNacional(d);
              String tramo = v ? "V" : "P"; 

              double costeDia = 0.0;
              List<double> horasDia = _horasPorDia[dia['fecha']] ?? List.filled(24, 0.0);
              
              if (_tarifaSeleccionada == 'PVPC (e-SIOS real)') {
                for (int h = 0; h < 24; h++) {
                    double precioAplicar = 0.10;
                    if (_preciosHistoricos.containsKey(dia['fecha']) && h < _preciosHistoricos[dia['fecha']]!.length) {
                        precioAplicar = _preciosHistoricos[dia['fecha']]![h];
                    } else {
                        if (h >= 10 && h < 14 || h >= 18 && h < 22) precioAplicar = 0.18;
                        else if (h >= 8 && h < 10 || h >= 14 && h < 18 || h >= 22 && h <= 23) precioAplicar = 0.13;
                        else precioAplicar = 0.08;
                    }
                    costeDia += (horasDia[h] * precioAplicar);
                }
              } else {
                  final precios = _tarifasSimulator[_tarifaSeleccionada]!;
                  for (int h = 0; h < 24; h++) {
                      double precioAplicar = precios['v']!;
                      if (h >= 8 && h < 10 || h >= 14 && h < 18 || h >= 22 && h <= 23) precioAplicar = precios['l']!;
                      else if (h >= 10 && h < 14 || h >= 18 && h < 22) precioAplicar = precios['p']!;
                      costeDia += (horasDia[h] * precioAplicar);
                  }
              }

              totalEurosCiclo += costeDia;
              totalKwhCiclo += dia['kwh'];

              int barLength = maxKwh > 0 ? ((dia['kwh'] / maxKwh) * 8).round() : 0;
              String bar = List.filled(barLength, '█').join('').padRight(8, ' ');

              t += "${dia['fecha']} [$tramo] $bar- ${dia['kwh'].toStringAsFixed(1).padLeft(5,' ')}kWh|${costeDia.toStringAsFixed(2)}€\n";
          }
      }

      double totalConImpuestos = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva;
      double costeImpuestos = totalConImpuestos - (_costeEnergia + _costePotencia + _cuotaOctopus);

      t += "\n------------------------------\n";
      t += "Energia Activa:       ${_costeEnergia.toStringAsFixed(2)} EUR\n";
      t += "Potencia Fija:        ${_costePotencia.toStringAsFixed(2)} EUR\n";
      t += "Gestion y Extras:     ${_cuotaOctopus.toStringAsFixed(2)} EUR\n";
      t += "Impuestos (IVA+IE):   ${costeImpuestos.toStringAsFixed(2)} EUR\n";
      t += "------------------------------\n";
      t += "TOTAL A PAGAR:        ${totalConImpuestos.toStringAsFixed(2)} EUR\n";
      t += "------------------------------\n\n";
      
      _lanzarDialogoImpresion(t, "Resumen Días PRO");
  }

  void _seleccionarDiaParaTicket24h() { showDialog(context: context, builder: (c) => AlertDialog(backgroundColor: Colors.white, title: const Text("Selecciona un día", style: TextStyle(fontWeight: FontWeight.bold)), content: SizedBox(width: double.maxFinite, child: ListView.separated(shrinkWrap: true, itemCount: _desgloseDiario.where((d)=>!d['isFuture']).length, separatorBuilder: (ctx, i) => const Divider(height: 1), itemBuilder: (ctx, i) { var diasValidos = _desgloseDiario.where((d)=>!d['isFuture']).toList(); String f = diasValidos[i]['fecha']; int dIdx = diasValidos[i]['diaIndex']; return ListTile(title: Text("Día $f", style: const TextStyle(fontWeight: FontWeight.bold)), trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Color(0xFF00E5FF)), onTap: () { Navigator.pop(ctx); _configurarFranjaHoraria(f, dIdx); }); })),)); }
  void _configurarFranjaHoraria(String fecha, int diaIndex) { double minH = 0; double maxH = 24; showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (context, setStateSB) => AlertDialog(backgroundColor: Colors.white, title: Text("Filtrar horas: $fecha", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), content: Column(mainAxisSize: MainAxisSize.min, children: [Text("Desde las ${minH.toInt()}:00 hasta las ${maxH.toInt()}:00", style: const TextStyle(color: Colors.blueGrey, fontWeight: FontWeight.bold)), const SizedBox(height: 10), RangeSlider(values: RangeValues(minH, maxH), min: 0, max: 24, divisions: 24, activeColor: const Color(0xFF00E5FF), labels: RangeLabels("${minH.toInt()}:00", "${maxH.toInt()}:00"), onChanged: (v) { setStateSB((){ minH = v.start; maxH = v.end; }); })]), actions: [TextButton(onPressed: ()=>Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.grey))), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black87), onPressed: (){ Navigator.pop(ctx); _mostrarTicket24hGenerado(fecha, diaIndex, minH.toInt(), maxH.toInt()); }, child: const Text("PREPARAR TICKET", style: TextStyle(fontWeight: FontWeight.bold)))]))); }

  void _mostrarTicket24hGenerado(String fecha, int diaIndex, int startH, int endH) {
    List<double> horas = _horasPorDia[fecha] ?? []; String cabeceraH = _tarifaSeleccionada == 'Octopus Relax' ? "OCTOPUS RELAX v36" : "OCTOPUS FLEXI v36"; String t = "        $cabeceraH   \n------------------------------\nDesglose $fecha\nFranja: $startH:00 a $endH:00\n------------------------------\n\n"; double totalKwh = 0; double totalEurosFranja = 0; double maxKwh = 0; for(var h in horas) if(h > maxKwh) maxKwh = h;
    for(int i = startH; i < endH; i++) {
       if (i < horas.length) {
         double costeHora = 0.0; String tramo = "V";
         if (_tarifaSeleccionada == 'PVPC (e-SIOS real)') { double p = 0.10; if (_preciosHistoricos.containsKey(fecha) && i < _preciosHistoricos[fecha]!.length) { p = _preciosHistoricos[fecha]![i]; } else { if (i >= 10 && i < 14 || i >= 18 && i < 22) p = 0.18; else if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) p = 0.13; else p = 0.08; } costeHora = horas[i] * p; if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) { tramo = "L"; } else if (i >= 10 && i < 14 || i >= 18 && i < 22) { tramo = "P"; }
         } else { final precios = _tarifasSimulator[_tarifaSeleccionada]!; double precioAplicar = precios['v']!; if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) { precioAplicar = precios['l']!; tramo = "L"; } else if (i >= 10 && i < 14 || i >= 18 && i < 22) { precioAplicar = precios['p']!; tramo = "P"; } costeHora = horas[i] * precioAplicar; }
         int barLength = maxKwh > 0 ? ((horas[i] / maxKwh) * 8).round() : 0; String bar = List.filled(barLength, '█').join('').padRight(8, ' '); t += "${i.toString().padLeft(2,'0')}h-[$tramo]-$bar-${horas[i].toStringAsFixed(2)}kWh|${costeHora.toStringAsFixed(3)}€\n"; totalKwh += horas[i]; totalEurosFranja += costeHora;
       }
    }
    t += "\n------------------------------\nTOTAL FRANJA: ${totalKwh.toStringAsFixed(2)} kWh\nCOSTE ENERGIA: ${totalEurosFranja.toStringAsFixed(2)} EUR\n------------------------------\n\n"; _lanzarDialogoImpresion(t, "Franja Horaria");
  }

  Future<void> _generarTicketPreciosHoy() async {
    DateTime targetDate = DateTime.now(); bool isTomorrow = false;
    if (targetDate.hour > 20 || (targetDate.hour == 20 && targetDate.minute >= 30)) { targetDate = targetDate.add(const Duration(days: 1)); isTomorrow = true; }
    String fechaKey = "${targetDate.day.toString().padLeft(2,'0')}/${targetDate.month.toString().padLeft(2,'0')}"; _addLog("Generando Ticket Precios...");
    try {
      List<double> preciosHoy = _preciosHistoricos[fechaKey] ?? [];
      if (preciosHoy.isEmpty) { await _descargarPrecioDia(targetDate); preciosHoy = _preciosHistoricos[fechaKey] ?? []; }
      if (preciosHoy.isEmpty) throw Exception("No hay datos disponibles para esa fecha.");
      String title = isTomorrow ? "      PRECIOS LUZ MAÑANA      \n" : "       PRECIOS LUZ HOY      \n"; String t = "$title------------------------------\nFecha: ${_formatDateShort(targetDate)}\nTarifa: Indexada (PVPC/Flexi)\n------------------------------\n\n";
      double minPrecio = 999.0; double maxPrecio = 0.0; for (var p in preciosHoy) { if (p < minPrecio) minPrecio = p; if (p > maxPrecio) maxPrecio = p; }
      for (int i=0; i<preciosHoy.length; i++) { double p = preciosHoy[i]; String tramo = "V"; if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) { tramo = "L"; } else if (i >= 10 && i < 14 || i >= 18 && i < 22) { tramo = "P"; } String indicator = ""; if (p == minPrecio) indicator = " [MIN]"; if (p == maxPrecio) indicator = " [MAX]"; t += "${i.toString().padLeft(2,'0')}h-[$tramo]........${p.toStringAsFixed(4)} €$indicator\n"; }
      t += "\n------------------------------\nMás barato: ${minPrecio.toStringAsFixed(4)} €\nMás caro:   ${maxPrecio.toStringAsFixed(4)} €\n------------------------------\n💡 INFO MERCADO (OMIE):\nLa subasta de energía se realiza\na las 12:00h todos los días.\nA las 20:30h, E-SIOS suma los\npeajes de acceso y publica los\nprecios definitivos para mañana.\n------------------------------\n\n";
      _lanzarDialogoImpresion(t, isTomorrow ? "Precios de Mañana" : "Precios de Hoy");
    } catch(e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error obteniendo precios.'))); _addLog("Error Tickets: $e"); }
  }


  Widget _tarjetaDinero() { 
    double total = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; 
    return Container(
      padding: const EdgeInsets.all(20), 
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF00B4DB), Color(0xFF0083B0)]), borderRadius: BorderRadius.circular(20)), 
      child: Column(children: [
        
        // LA BÓVEDA HISTORIAL (Desplegable mágico) + ajuste de día de corte
        Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16), 
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white54)), 
          child: DropdownButton<int>(
            value: _cicloSeleccionadoIndex, 
            dropdownColor: Colors.blue.shade900, 
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), 
            underline: Container(), 
            icon: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.history, color: Colors.white)), 
            items: List.generate(_ciclosDisponibles.length, (index) { 
              String prefix = index == 0 ? "CICLO ACTUAL" : "HISTÓRICO $index"; 
              return DropdownMenuItem(value: index, child: Text("$prefix (${_formatDateShort(_ciclosDisponibles[index]['start']!)} - ${_formatDateShort(_ciclosDisponibles[index]['end']!)})")); 
            }), 
            onChanged: (int? n) { 
              if(n != null) { 
                setState(() { _cicloSeleccionadoIndex = n; _calcularFechasCiclo(); _desgloseDiario.clear(); _horasPorDia.clear(); _topHoras.clear(); _promedioPorHora.clear(); _kwhTotal = 0.0; _costeEnergia = 0.0; _costeExactoFlexi = 0.0; _status = "Buscando en bóveda..."; }); _actualizarDatos(); 
              } 
            }
          )
        ),
        IconButton(icon: const Icon(Icons.edit_calendar, color: Colors.white), tooltip: "Cambiar día de inicio del ciclo", onPressed: _cambiarDiaCorte),
        ]),

        const SizedBox(height: 16), 
        Text("${total.toStringAsFixed(2)} €", style: const TextStyle(color: Colors.white, fontSize: 50, fontWeight: FontWeight.w900)), 
        const SizedBox(height: 16), 
        
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12), 
          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)), 
          child: DropdownButton<String>(
            value: _tarifaSeleccionada, 
            dropdownColor: Colors.black87, 
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), 
            underline: Container(), 
            icon: const Icon(Icons.arrow_drop_down, color: Colors.white), 
            items: _tarifasSimulator.keys.map((String val) => DropdownMenuItem(value: val, child: Text(val))).toList(), 
            onChanged: (String? n) { if(n != null) { setState(() => _tarifaSeleccionada = n); SharedPreferences.getInstance().then((p) => p.setString('tarifa_activa', n)); _recalcularCosteEnergia(); } }
          )
        )
      ])
    ); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF00E5FF), title: const Text("eConsumo EV Edition", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)), centerTitle: true, actions: [ IconButton(icon: const Icon(Icons.info_outline, color: Colors.black87), tooltip: "Acerca de", onPressed: _mostrarAcercaDe), if (_email.isNotEmpty) IconButton(icon: const Icon(Icons.logout, color: Colors.black87), onPressed: _cerrarSesion) ]),
      body: Column(
        children: [
          Expanded(
            child: _email.isEmpty ? _pantallaLoginNatva()
                : (!_isLoggedIn && !_conectando) ? _pantallaConectar()
                : (!_isLoggedIn) ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const CircularProgressIndicator(color: Color(0xFF00E5FF)), const SizedBox(height: 24), Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))]))
                : RefreshIndicator(onRefresh: _forzarRefrescoCompleto, color: const Color(0xFF00E5FF), child: ListView(padding: const EdgeInsets.all(16), children: [ 
                    
                    _bannerEstadoSync(), const SizedBox(height: 12),
                    _tarjetaDinero(), const SizedBox(height: 16),
                    // BOTONES DE TICKETS
                    if (_desgloseDiario.isNotEmpty) Row(children: [
                        Expanded(child: ElevatedButton.icon(onPressed: _mostrarTicketGenerado, icon: const Icon(Icons.calendar_today, color: Colors.white, size: 14), label: const Text("T. DÍAS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))), 
                        const SizedBox(width: 8), 
                        Expanded(child: ElevatedButton.icon(onPressed: _seleccionarDiaParaTicket24h, icon: const Icon(Icons.access_time, color: Colors.black87, size: 14), label: const Text("T. HORAS", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
                        const SizedBox(width: 8), 
                        Expanded(child: ElevatedButton.icon(onPressed: _generarTicketPreciosHoy, icon: const Icon(Icons.euro, color: Colors.white, size: 14), label: const Text("PRECIOS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade600, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))))
                    ]) ,
                    const SizedBox(height: 24),
                    _tarjetaDesglose(), const SizedBox(height: 16),
                    _tarjetaComparadorTarifas(), const SizedBox(height: 16),
                    _tarjetaCNMC(), const SizedBox(height: 16),

                    
                    // AVISO INTELIGENTE SI I-DE ESTÁ RETRASADO
                    if (_desgloseDiario.isEmpty && !_status.contains("Calculando") && !_status.contains("bóveda")) 
                      Container(
                          margin: const EdgeInsets.symmetric(vertical: 10),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.orange.shade200)),
                          child: Column(
                              children: const [
                                  Icon(Icons.pending_actions, color: Colors.orange, size: 40),
                                  SizedBox(height: 8),
                                  Text("Iberdrola no ha procesado datos para estos días.", textAlign: TextAlign.center, style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                                  SizedBox(height: 4),
                                  Text("Despliega el menú superior 'CICLO ACTUAL' para acceder a la Bóveda Histórica y consultar tus meses pasados.", textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),
                              ]
                          )
                      ),
                    

                    _tarjetaPrediccion(), const SizedBox(height: 16),
                    
                    _tarjetaInfoFlexi(), const SizedBox(height: 24),

                    if (_desgloseDiario.isNotEmpty) ...[_tarjetaGraficoVisual(), const SizedBox(height: 16)],
                    if (_promedioPorHora.isNotEmpty) ...[_tarjetaGraficoHorario(), const SizedBox(height: 16)],
                    if (_topHoras.isNotEmpty) ...[ _tarjetaPerfilHorario(), const SizedBox(height: 24), ],

                    const Text("  HERRAMIENTAS DE ANÁLISIS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12, letterSpacing: 1.2)), const SizedBox(height: 8),
                    _tarjetaLogsAparatos(), const SizedBox(height: 16),
                  ])),
          ),
          Container(height: 120, width: double.infinity, color: Colors.black, padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("> TERMINAL SNIFFER", style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)), IconButton(icon: const Icon(Icons.copy, color: Colors.white, size: 20), onPressed: _copiarLog)]), Expanded(child: ListView.builder(controller: _logScrollController, itemCount: _logs.length, itemBuilder: (c, i) => Text(_logs[i], style: TextStyle(color: _logs[i].contains("Error") || _logs[i].contains("Fallo") || _logs[i].contains("WU1") ? Colors.redAccent : Colors.white70, fontSize: 10, fontFamily: 'monospace'))))]))
        ],
      ),
    );
  }

  Widget _bannerEstadoSync() {
    if (_lastSyncTime == null && _lastSyncError == null) return const SizedBox.shrink();
    Duration? diff = _lastSyncTime != null ? DateTime.now().difference(_lastSyncTime!) : null;
    bool stale = diff == null || diff.inHours >= 36;
    String texto;
    if (_lastSyncTime == null) {
      texto = "Sin datos descargados todavía.";
    } else if (diff!.inMinutes < 60) {
      texto = "Datos descargados hace ${diff.inMinutes} min.";
    } else if (diff.inHours < 48) {
      texto = "Datos descargados hace ${diff.inHours} h.";
    } else {
      texto = "Datos descargados hace ${diff.inDays} días.";
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: stale ? Colors.red.shade50 : Colors.green.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: stale ? Colors.red.shade200 : Colors.green.shade200)),
      child: Row(children: [
        Icon(stale ? Icons.warning_amber_rounded : Icons.check_circle, color: stale ? Colors.red : Colors.green, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(texto, style: TextStyle(fontSize: 11, color: stale ? Colors.red.shade900 : Colors.green.shade900, fontWeight: FontWeight.bold)),
          if (_proximaDescargaMes != null) Builder(builder: (_) {
            final falta = _proximaDescargaMes!.difference(DateTime.now());
            final hh = "${_proximaDescargaMes!.hour.toString().padLeft(2, '0')}:${_proximaDescargaMes!.minute.toString().padLeft(2, '0')}";
            final txt = falta.isNegative
                ? "Ya puedes descargar datos nuevos del mes en curso."
                : "Próxima descarga posible: hoy/mañana a las $hh (Datadis limita a 1 vez/24h).";
            return Padding(padding: const EdgeInsets.only(top: 2), child: Text(txt, style: TextStyle(fontSize: 10, color: falta.isNegative ? Colors.green.shade700 : Colors.blueGrey)));
          }),
        ])),
        if (_lastSyncError != null) IconButton(
          icon: const Icon(Icons.info_outline, size: 18, color: Colors.redAccent),
          tooltip: "Ver motivo del último fallo",
          onPressed: () {
            final parts = _lastSyncError!.split('|');
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(parts.length > 1 ? parts[1] : _lastSyncError!), duration: const Duration(seconds: 6)));
          },
        )
      ]),
    );
  }

  Widget _tarjetaComparadorTarifas() {
    if (_comparadorTarifas.isEmpty) return const SizedBox.shrink();
    var entradas = _comparadorTarifas.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    double masBarata = entradas.first.value;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: const [Icon(Icons.compare_arrows, size: 16, color: Colors.blueGrey), SizedBox(width: 8), Text("COMPARADOR DE TARIFAS (ESTE CICLO)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12))]),
        const Divider(),
        for (var e in entradas) Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              if (e.value == masBarata) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.emoji_events, size: 16, color: Colors.amber)),
              Text(e.key, style: TextStyle(fontWeight: e.key == _tarifaSeleccionada ? FontWeight.bold : FontWeight.normal, color: e.key == _tarifaSeleccionada ? Colors.indigo : Colors.black87)),
              if (e.key == _tarifaSeleccionada) const Padding(padding: EdgeInsets.only(left: 6), child: Text("(actual)", style: TextStyle(fontSize: 10, color: Colors.grey))),
            ]),
            Text("${e.value.toStringAsFixed(2)} €", style: TextStyle(fontWeight: FontWeight.bold, color: e.value == masBarata ? Colors.green.shade700 : Colors.black87)),
          ]),
        ),
        const SizedBox(height: 4),
        const Text("Factura completa: energía + potencia + fijos + impuestos, con tu consumo horario real.", style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
      ]),
    );
  }

  // --- COMPARADOR OFICIAL CNMC ---
  // Genera un CSV de consumos horarios en formato i-DE, aceptado por
  // comparador.cnmc.gob.es (subir fichero de consumos). Se guarda en Descargas.
  Future<void> _exportarCsvCNMC() async {
    _addLog("CSV CNMC: iniciando exportación...");
    if (_horasPorDia.isEmpty) {
      _addLog("CSV CNMC: sin datos horarios. Conecta primero.");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay datos horarios cargados. Conecta y actualiza primero.'), backgroundColor: Colors.orange));
      return;
    }
    if (_cups.isEmpty) {
      _addLog("CSV CNMC: falta CUPS, solicitando...");
      await _pedirCups();
      if (_cups.isEmpty) { _addLog("CSV CNMC: cancelado (sin CUPS)."); return; }
    }
    try {
      // Las claves de _horasPorDia son "dd/MM" (sin año): reconstruimos la fecha
      // completa usando el año del ciclo (cuidando ciclos que cruzan de diciembre a enero).
      DateTime fechaCompleta(String ddMM) {
        final p = ddMM.split('/');
        final d = int.parse(p[0]); final m = int.parse(p[1]);
        int y = _cycleStart.year;
        if (m < _cycleStart.month) y = _cycleStart.year + 1; // ciclo cruza de año
        return DateTime(y, m, d);
      }
      final fechas = _horasPorDia.keys.toList()..sort((a, b) => fechaCompleta(a).compareTo(fechaCompleta(b)));
      final buffer = StringBuffer("CUPS;Fecha;Hora;Consumo;Metodo_obtencion\n");
      int filas = 0;
      for (final fecha in fechas) {
        final fc = fechaCompleta(fecha);
        final fechaCsv = "${fc.day.toString().padLeft(2, '0')}/${fc.month.toString().padLeft(2, '0')}/${fc.year}";
        final horas = _horasPorDia[fecha]!;
        for (int h = 0; h < horas.length; h++) {
          buffer.writeln("$_cups;$fechaCsv;${h + 1};${horas[h].toStringAsFixed(3).replaceAll('.', ',')};R");
          filas++;
        }
      }
      _addLog("CSV CNMC: ${fechas.length} días, $filas filas generadas.");
      final nombre = "consumos_econsumo_${DateTime.now().millisecondsSinceEpoch}.csv";
      final res = await const MethodChannel('widget_channel').invokeMethod('saveCsv', {'filename': nombre, 'content': buffer.toString()});
      _addLog("CSV CNMC: guardado en Descargas → $nombre");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV guardado en Descargas: $nombre'), backgroundColor: Colors.green, duration: const Duration(seconds: 5)));
    } catch (e) {
      _addLog("CSV CNMC: ERROR → $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _pedirCups() async {
    final ctrl = TextEditingController(text: _cups);
    final String? nuevo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Tu CUPS"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("Código del punto de suministro (empieza por ES, aparece en tu factura). Se incluye en el CSV para el comparador CNMC.", style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(controller: ctrl, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: "CUPS", hintText: "ES00XXXXXXXXXXXXXXXX", border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()), child: const Text("Guardar")),
        ],
      ),
    );
    if (nuevo == null || nuevo.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cups', nuevo);
    if (mounted) setState(() { _cups = nuevo; });
  }

  Future<void> _abrirComparadorCNMC() async {
    try { await launchUrl(Uri.parse('https://comparador.cnmc.gob.es/'), mode: LaunchMode.externalApplication); } catch (e) { _addLog("Error abriendo comparador CNMC: $e"); }
  }

  Widget _tarjetaCNMC() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [ const Icon(Icons.account_balance, size: 16, color: Colors.blueGrey), const SizedBox(width: 8), const Text("COMPARADOR OFICIAL CNMC", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const Spacer(), IconButton(icon: const Icon(Icons.badge_outlined, size: 18, color: Colors.blueGrey), tooltip: _cups.isEmpty ? "Configurar CUPS" : "CUPS: ${_cups.length > 8 ? _cups.substring(0, 8) : _cups}...", onPressed: _pedirCups) ]),
        const Divider(),
        const Text("Exporta tus consumos horarios reales y súbelos al comparador oficial (≈800 ofertas verificadas por la CNMC).", style: TextStyle(fontSize: 12, color: Colors.black87)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: _exportarCsvCNMC, icon: const Icon(Icons.file_download, size: 18), label: const Text("EXPORTAR CSV", style: TextStyle(fontSize: 12)))),
          const SizedBox(width: 8),
          Expanded(child: ElevatedButton.icon(onPressed: _abrirComparadorCNMC, icon: const Icon(Icons.open_in_new, size: 18), label: const Text("ABRIR CNMC", style: TextStyle(fontSize: 12)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black87))),
        ]),
      ]),
    );
  }

  Widget _pantallaLoginNatva() { final eCtrl = TextEditingController(text: _email); final pCtrl = TextEditingController(text: _pass);  return Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24.0), child: Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), child: Padding(padding: const EdgeInsets.all(24.0), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.electric_car, size: 60, color: Color(0xFF00E5FF)), const SizedBox(height: 16), const Text("eConsumo EV Connect", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(height: 8), const Text("Datos vía Datadis (API oficial de las distribuidoras)", style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.center), const SizedBox(height: 24), TextField(controller: eCtrl, decoration: const InputDecoration(labelText: "NIF (usuario Datadis)", border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge))), const SizedBox(height: 16), TextField(controller: pCtrl, obscureText: true, decoration: const InputDecoration(labelText: "Contraseña de Datadis", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock))), const SizedBox(height: 24), SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () async { await _secureStorage.write(key: 'email', value: eCtrl.text.trim().toUpperCase()); await _secureStorage.write(key: 'pass', value: pCtrl.text); setState(() { _email = eCtrl.text.trim().toUpperCase(); _pass = pCtrl.text; _status = "Conectando..."; }); _conectarAhora(); }, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black87, padding: const EdgeInsets.symmetric(vertical: 16)), child: const Text("CONECTAR", style: TextStyle(fontWeight: FontWeight.bold))))])))))); }
  Widget _tarjetaDesglose() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("TICKET DE COMPRA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const Divider(), _filaDesglose("Energía Consumida", _costeEnergia, true), Padding(padding: const EdgeInsets.only(left: 16, bottom: 8), child: Row(children: [Text("${_kwhTotal.toStringAsFixed(1)} kWh procesados", style: const TextStyle(color: Colors.grey, fontSize: 11))])), _filaDesglose("Potencia Fija", _costePotencia, false), _filaDesglose("Gestión y Extras", _cuotaOctopus, false), const Divider(), _filaDesglose("Impuestos (IVA + IE)", ((_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva) - (_costeEnergia + _costePotencia + _cuotaOctopus), false)]));
  // --- WIDGETS RESTANTES DE LA INTERFAZ ---
  Widget _tarjetaLogsAparatos() => Card(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.grey.shade300)), color: Colors.white, child: Column(children: [Padding(padding: const EdgeInsets.all(12), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ const Text("HISTORIAL APARATOS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), Row(children: [ IconButton(icon: const Icon(Icons.download, size: 18, color: Colors.blueGrey), onPressed: _importarDatos, tooltip: "Importar JSON"), IconButton(icon: const Icon(Icons.upload, size: 18, color: Colors.blueGrey), onPressed: _exportarDatos, tooltip: "Exportar JSON"), ],) ])), const Divider(height: 1), Container(height: 150, child: _logsDispositivos.isEmpty ? const Center(child: Text("No hay registros.", style: TextStyle(color: Colors.grey))) : ListView.separated(itemCount: _logsDispositivos.length, separatorBuilder: (c, i) => const Divider(height: 1), itemBuilder: (c, i) { final log = _logsDispositivos[i]; final start = DateTime.parse(log['start']); return ListTile(leading: const Icon(Icons.history, color: Colors.blueGrey), title: Text(log['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), subtitle: Text("${start.day}/${start.month} - ${start.hour.toString().padLeft(2,'0')}:${start.minute.toString().padLeft(2,'0')}"), trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18), onPressed: () { setState(() { _logsDispositivos.removeAt(i); }); _saveDeviceLogs(); }),); },),),]));
  Widget _tarjetaGraficoVisual() { double maxKwh = 0; for(var d in _desgloseDiario){ if(d['kwh']>maxKwh) maxKwh = d['kwh']; } return Container(padding: const EdgeInsets.all(16), height: 250, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text("CONSUMO DEL MES (kWh)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const SizedBox(height: 16), Expanded(child: BarChart(BarChartData(alignment: BarChartAlignment.spaceAround, maxY: maxKwh > 0 ? maxKwh * 1.2 : 5, barTouchData: BarTouchData(enabled: true, touchTooltipData: BarTouchTooltipData(getTooltipColor: (group) => Colors.black87, tooltipPadding: const EdgeInsets.all(8), tooltipMargin: 8, getTooltipItem: (group, groupIndex, rod, rodIndex) { return BarTooltipItem("${rod.toY.toStringAsFixed(2)} kWh", const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 14)); })), titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22, interval: 5, getTitlesWidget: (v, m) { if (v.toInt() % 5 != 0) return const SizedBox(); return Text(_desgloseDiario[v.toInt()]['fecha'].split('/')[0], style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)); })), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), gridData: FlGridData(show: false), barGroups: _desgloseDiario.asMap().entries.map((e) => BarChartGroupData(x: e.key, barRods: [BarChartRodData(toY: e.value['isFuture'] ? 0.05 : e.value['kwh'], color: e.value['isFuture'] ? Colors.grey.shade300 : const Color(0xFF00E5FF), width: 6, borderRadius: BorderRadius.circular(2), backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxKwh > 0 ? maxKwh * 1.2 : 5, color: Colors.grey.shade100))])).toList() ))) ])); }
  Widget _tarjetaGraficoHorario() { double maxKwh = 0; for(var d in _promedioPorHora){ if(d>maxKwh) maxKwh = d; } return Container(padding: const EdgeInsets.all(16), height: 250, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text("PERFIL HORARIO MEDIO (kWh)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const SizedBox(height: 16), Expanded(child: LineChart(LineChartData(lineBarsData: [LineChartBarData(spots: _promedioPorHora.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(), isCurved: true, color: Colors.indigoAccent, barWidth: 3, isStrokeCapRound: true, belowBarData: BarAreaData(show: true, color: Colors.indigoAccent.withOpacity(0.2)))], titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 6, reservedSize: 22, getTitlesWidget: (v, m) { if (v.toInt() % 6 != 0) return const SizedBox(); return Text("${v.toInt()}h", style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)); })), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), gridData: FlGridData(show: false), lineTouchData: LineTouchData(enabled: true, touchTooltipData: LineTouchTooltipData(getTooltipColor: (group) => Colors.black87, getTooltipItems: (spots) => spots.map((s) => LineTooltipItem("${s.x.toInt()}h: ${s.y.toStringAsFixed(3)} kWh", const TextStyle(color: Colors.indigoAccent, fontWeight: FontWeight.bold))).toList())) ))) ])); }
  Widget _tarjetaPerfilHorario() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: const [Icon(Icons.insights, size: 16, color: Colors.blueGrey), SizedBox(width: 8), Text("TUS PICOS DE CONSUMO (HORAS)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12))]), const Divider(), for (int i = 0; i < _topHoras.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("${i+1}. Hora: ${_topHoras[i]['hora'].toString().padLeft(2,'0')}:00 - ${_topHoras[i]['hora']+1}:00", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)), Text("${_topHoras[i]['kwh'].toStringAsFixed(1)} kWh", style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))]))]));
  Widget _filaDesglose(String t, double c, bool b) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(t, style: TextStyle(fontWeight: b ? FontWeight.bold : FontWeight.normal)), Text("${c.toStringAsFixed(2)} €", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))]));
  Widget _tarjetaPrediccion() { double totalEuros = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; int diasRegistrados = _fetchEnd.difference(_cycleStart).inDays + 1; int diasTotales = _cycleEnd.difference(_cycleStart).inDays + 1; double pred = diasRegistrados > 0 ? (totalEuros / diasRegistrados) * diasTotales : 0.0; return Card(color: Colors.white, elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.indigo.shade200)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Row(children: [const Icon(Icons.trending_up, color: Colors.indigo, size: 24), const SizedBox(width: 12), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [const Text("PREDICCIÓN FIN DE CICLO", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)), Text("${pred.toStringAsFixed(2)} €", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.indigo)),],),],)],),),); }
  Widget _tarjetaInfoFlexi() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFE0F7FA), border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)), borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: const [Icon(Icons.ev_station, color: Colors.indigo, size: 20), SizedBox(width: 8), Text("Estrategia Leapmotor + Flexi", style: TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold, fontSize: 14))]), const SizedBox(height: 12), const Text("El sistema ahora evalúa tu histórico al milímetro. Recuerda: para llenar los 67.2kWh de tu Leapmotor al precio más barato, carga de 00:00 a 08:00 o los fines de semana.", style: TextStyle(fontSize: 12, color: Colors.black87)), const SizedBox(height: 8), const Text("ℹ️ El mercado OMIE subasta la luz a las 12:00h y los precios definitivos para el día siguiente se publican en E-SIOS a partir de las 20:30h.", style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.blueGrey)), const SizedBox(height: 16), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _imprimirMasterPlanEV, icon: const Icon(Icons.print, color: Colors.white), label: const Text("IMPRIMIR MASTERPLAN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, padding: const EdgeInsets.symmetric(vertical: 12))))]));
}
