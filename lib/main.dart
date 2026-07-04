import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:workmanager/workmanager.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'dart:convert';
import 'dart:async';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// RESTAURAMOS EL DÍA DE CORTE AL 24 TRAS EL CAMBIO DE POTENCIA DEFINITIVO
const int DIA_CORTE_OCTOPUS = 24;

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
    final String groqKey = prefs.getString('groq_key') ?? '';
    
    const AndroidInitializationSettings initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initAndroid));

    if (task == "econsumo_charge_advisor") {
        try {
            DateTime target = DateTime.now();
            if (target.hour > 20) target = target.add(const Duration(days: 1));
            String sDate = "${target.year}-${target.month.toString().padLeft(2,'0')}-${target.day.toString().padLeft(2,'0')}";
            final res = await http.get(Uri.parse("https://api.esios.ree.es/archives/70/download?date=$sDate"));
            if (res.statusCode == 200) {
                final j = jsonDecode(res.body);
                List<dynamic> precios = j['PVPC'];
                if (precios != null && precios.length >= 24) {
                    List<double> pEU = precios.map((p) => double.parse(p['PCB'].toString().replaceAll(',', '.')) / 1000.0).toList();
                    double minPrice = 999.0; int bestHour = 0;
                    for(int i=0; i<8; i++) { if (pEU[i] < minPrice) { minPrice = pEU[i]; bestHour = i; } }
                    String horaTexto = "${bestHour.toString().padLeft(2,'0')}:00"; String precioTexto = minPrice.toStringAsFixed(3);
                    String mensajeAsistente = "Enchufa el Leapmotor a las $horaTexto. El precio caerá a $precioTexto €/kWh.";
                    if (groqKey.isNotEmpty) {
                        final r = await http.post(Uri.parse('https://api.groq.com/openai/v1/chat/completions'), headers: { 'Authorization': 'Bearer $groqKey', 'Content-Type': 'application/json' }, body: jsonEncode({ "model": "openai/gpt-oss-120b", "messages": [ {"role": "system", "content": "Eres la IA del Leapmotor B10. Hablas con el conductor. Tienes 15 palabras máximo."}, {"role": "user", "content": "Informa al usuario que la mejor hora para cargar es a las $horaTexto a $precioTexto euros."} ], "temperature": 0.8, "max_completion_tokens": 50 }));
                        if (r.statusCode == 200) mensajeAsistente = jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content'].toString().replaceAll('"', '').trim();
                    }
                    await flutterLocalNotificationsPlugin.show(100, "🔌 IA de Carga Leapmotor", mensajeAsistente, const NotificationDetails(android: AndroidNotificationDetails('ev_charge', 'Carga Vehículo', importance: Importance.max, priority: Priority.high, color: Color(0xFF00E5FF))));
                }
            }
        } catch(e) {}
        return Future.value(true);
    }

    if (task == "fetchConsumoTask" || task == "econsumo_sync_diario" || task == "retry_sync_diario") {
        final String email = prefs.getString('email') ?? ''; final String pass = prefs.getString('pass') ?? '';
        if (email.isEmpty || pass.isEmpty) return Future.value(true);
        HeadlessInAppWebView? headlessWebView; bool success = false; String errorMsg = '';
        headlessWebView = HeadlessInAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
          initialSettings: InAppWebViewSettings(userAgent: 'Mozilla/5.0 (Linux; Android 13)', javaScriptEnabled: true, domStorageEnabled: true),
          onLoadStop: (controller, url) async {
            if ((url?.path ?? '').contains('login')) await controller.evaluateJavascript(source: "async function autoLogin(e,p,a){ let btn=Array.from(document.querySelectorAll('button')).find(b=>b.innerText&&b.innerText.toLowerCase().includes('entrar')); let em=document.querySelector('input[type=\"email\"]')||document.querySelector('input[name=\"email\"]'); let pw=document.querySelector('input[type=\"password\"]'); if(em&&pw&&btn){ const ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,\"value\").set; em.focus();ns.call(em,e);em.dispatchEvent(new Event('input',{bubbles:true})); await new Promise(r=>setTimeout(r,400)); pw.focus();ns.call(pw,p);pw.dispatchEvent(new Event('input',{bubbles:true})); await new Promise(r=>setTimeout(r,600)); btn.click(); } else if(a>0) setTimeout(()=>autoLogin(e,p,a-1),1500); } autoLogin('$email','$pass',6);");
          },
          onUpdateVisitedHistory: (controller, url, androidIsReload) async {
            if (url != null && !url.path.contains('login') && !url.path.contains('logout') && url.path.length > 5) {
              DateTime now = DateTime.now(); DateTime startC;
              if (now.day >= DIA_CORTE_OCTOPUS) startC = DateTime(now.year, now.month, DIA_CORTE_OCTOPUS); else startC = DateTime(now.year, now.month - 1, DIA_CORTE_OCTOPUS);
              DateTime endC = DateTime.now().subtract(const Duration(days: 1)); if(endC.isBefore(startC)) endC = startC;
              String sStart = "${startC.day.toString().padLeft(2,'0')}-${startC.month.toString().padLeft(2,'0')}-${startC.year}"; String sEnd = "${endC.day.toString().padLeft(2,'0')}-${endC.month.toString().padLeft(2,'0')}-${endC.year}";
              var res = await controller.callAsyncJavaScript(functionBody: "let r = await fetch('https://www.i-de.es/consumidores/rest/consumoNew/obtenerDatosConsumoDH/$sStart/$sEnd/dias/USU/'); return await r.text();");
              if (res?.value != null && !res!.value.toString().contains("WU1")) {
                try {
                    final List data = jsonDecode(res!.value.toString());
                    if(data.isNotEmpty && data[0]['totalesPeriodosTarifarios'] != null) {
                      double p = (double.tryParse(data[0]['totalesPeriodosTarifarios'][0].toString())??0)/1000; double l = (double.tryParse(data[0]['totalesPeriodosTarifarios'][1].toString())??0)/1000; double v = (double.tryParse(data[0]['totalesPeriodosTarifarios'][2].toString())??0)/1000;
                      double coste = (p * 0.145) + (l * 0.098) + (v * 0.055); int diasRegistrados = endC.difference(startC).inDays + 1;
                      
                      double costeFijoPotencia = ((4.4 * 0.076) + (5.7 * 0.002)) * diasRegistrados;
                      double costeFijoExtra = (0.123 + 0.019 + 0.027) * diasRegistrados;
                      
                      double total = (coste + costeFijoPotencia + costeFijoExtra) * 1.05113 * 1.10;
                      DateTime finCicloTotal = DateTime(startC.year, startC.month + 1, DIA_CORTE_OCTOPUS - 1); int diasTotalesCiclo = finCicloTotal.difference(startC).inDays + 1;
                      double pred = diasRegistrados > 0 ? (total / diasRegistrados) * diasTotalesCiclo : 0.0; 
                      await flutterLocalNotificationsPlugin.show(0, "Ciclo: ${total.toStringAsFixed(2)} €", "🔌 Modo EV Activado", const NotificationDetails(android: AndroidNotificationDetails('econsumo', 'eConsumo Alertas', importance: Importance.low, priority: Priority.low)));
                      try { const MethodChannel channel = MethodChannel('widget_channel'); await channel.invokeMethod('updateWidget', { 'fechas': '$sStart al $sEnd', 'euros': '${total.toStringAsFixed(2)} €', 'kwh': '${(p+l+v).toStringAsFixed(1)} kWh', 'prediccion': 'Predicción: ${pred.toStringAsFixed(2)} €', 'consejo': '🔌 EV Mode' }); } catch(e) {}
                      success = true; headlessWebView?.dispose();
                    } else {
                      errorMsg = 'Respuesta sin totalesPeriodosTarifarios';
                    }
                } catch(e) { errorMsg = 'Error parseando JSON: $e'; }
              } else {
                errorMsg = 'Sesión inválida (WU1) o respuesta vacía';
              }
            }
          }
        );
        await headlessWebView.run(); await Future.delayed(const Duration(seconds: 60)); headlessWebView.dispose();

        if (success) {
          await prefs.setString('last_sync_ts', DateTime.now().toIso8601String());
          await prefs.remove('last_sync_error');
        } else {
          if (errorMsg.isEmpty) errorMsg = 'Timeout: no se salió del login en 60s (posible fallo de autologin o sesión)';
          await prefs.setString('last_sync_error', '${DateTime.now().toIso8601String()}|$errorMsg');
          // No esperamos al próximo ciclo de 12h: reintentamos en 20 min.
          Workmanager().registerOneOffTask("retry_${DateTime.now().millisecondsSinceEpoch}", "retry_sync_diario", initialDelay: const Duration(minutes: 20), constraints: Constraints(networkType: NetworkType.connected));
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
  Workmanager().registerPeriodicTask("sync_diario", "fetchConsumoTask", frequency: const Duration(hours: 12), constraints: Constraints(networkType: NetworkType.connected));
  Workmanager().registerPeriodicTask("oraculo_carga", "econsumo_charge_advisor", frequency: const Duration(hours: 6), constraints: Constraints(networkType: NetworkType.connected));
  final prefs = await SharedPreferences.getInstance();
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF00E5FF)), home: MainOrchestrator(savedEmail: prefs.getString('email') ?? '', savedPass: prefs.getString('pass') ?? '', savedGroq: prefs.getString('groq_key') ?? '')));
}

class MainOrchestrator extends StatefulWidget {
  final String savedEmail; final String savedPass; final String savedGroq;
  const MainOrchestrator({super.key, required this.savedEmail, required this.savedPass, required this.savedGroq});
  @override
  State<MainOrchestrator> createState() => _MainOrchestratorState();
}

class _MainOrchestratorState extends State<MainOrchestrator> {
  late String _email; late String _pass; late String _groqKey;
  InAppWebViewController? _webController;
  bool _isLoggedIn = false; bool _showWebFallback = false;
  String _status = "Calculando Ciclo..."; 
  String _consejoIA = "";
  String _prediccionMeteo = "Sincronizando radares meteo-eléctricos...";
  String _detallesMeteo = "...";
  
  double _kwhTotal = 0.0; double _kwhValle = 0.0; double _kwhLlano = 0.0; double _kwhPunta = 0.0;
  double _costeEnergia = 0.0; double _costePotencia = 0.0;
  double _cuotaOctopus = 0.0; 
  final double _impuestoElectrico = 1.05113; final double _iva = 1.10;
  
  List<Map<String, dynamic>> _topHoras = []; List<Map<String, dynamic>> _desgloseDiario = []; 
  Map<String, List<double>> _horasPorDia = {}; List<double> _promedioPorHora = []; 
  
  List<Map<String, DateTime>> _ciclosDisponibles = [];
  int _cicloSeleccionadoIndex = 0;
  
  late DateTime _cycleStart; late DateTime _cycleEnd; late DateTime _fetchEnd;
  Map<String, List<double>> _preciosHistoricos = {}; double _costeExactoFlexi = 0.0;
  
  String _tarifaSeleccionada = 'Octopus Flexi Live';
  final Map<String, Map<String, double>> _tarifasSimulator = { 
    'Octopus Flexi Live': {'p': 0.0, 'l': 0.0, 'v': 0.0},
    'Octopus Relax': {'p': 0.113, 'l': 0.113, 'v': 0.113}, 
    'Oct. 3 Periodos': {'p': 0.162, 'l': 0.114, 'v': 0.076}, 
    'Iberdrola Noche': {'p': 0.205, 'l': 0.205, 'v': 0.108} 
  };

  final TextEditingController _deviceCtrl = TextEditingController();
  List<Map<String, dynamic>> _logsDispositivos = [];
  double _baseWatts = 0.0; String _instantWatts = ""; bool _loadingPLC = false;

  final List<String> _logs = []; final ScrollController _logScrollController = ScrollController(); Timer? _rescueTimer;
  List<Map<String, String>> _chatMessages = [];

  DateTime? _lastSyncTime; String? _lastSyncError; Timer? _autoRefreshTimer;
  Map<String, double> _comparadorTarifas = {};

  @override
  void initState() {
    super.initState();
    _email = widget.savedEmail; _pass = widget.savedPass; _groqKey = widget.savedGroq;
    _solicitarPermisosNativos(); _loadDeviceLogs(); _calcularFechasCiclo(); _cargarEstadoSincronizacion();
    
    WidgetsBinding.instance.addPostFrameCallback((_) { _analizarMeteoElectrica(); });
    _addLog("eConsumo v36.8.0. Comparador de tarifas añadido.");

    // Red de seguridad: mientras la app esté abierta, refrescamos cada 20 min
    // sin depender de que el WorkManager en 2º plano haya podido ejecutarse.
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      if (_isLoggedIn && mounted) { _addLog("Auto-refresco periódico (app abierta)."); _actualizarDatos(); }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _rescueTimer?.cancel();
    _logScrollController.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarEstadoSincronizacion() async {
    final prefs = await SharedPreferences.getInstance();
    final String? ts = prefs.getString('last_sync_ts');
    final String? err = prefs.getString('last_sync_error');
    if (!mounted) return;
    setState(() { _lastSyncTime = ts != null ? DateTime.tryParse(ts) : null; _lastSyncError = err; });
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
  void _cerrarSesion() async { final prefs = await SharedPreferences.getInstance(); await prefs.clear(); Workmanager().cancelAll(); setState(() { _email = ''; _pass = ''; _groqKey = ''; _isLoggedIn = false; }); _webController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/logout'))); }
  String _formatDate(DateTime d) => "${d.day.toString().padLeft(2,'0')}-${d.month.toString().padLeft(2,'0')}-${d.year}";
  String _formatDateShort(DateTime d) => "${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}";

  void _loadDeviceLogs() async { final prefs = await SharedPreferences.getInstance(); final String? data = prefs.getString('device_logs'); if (data != null) setState(() { _logsDispositivos = List<Map<String, dynamic>>.from(jsonDecode(data)); }); }
  void _saveDeviceLogs() async { final prefs = await SharedPreferences.getInstance(); await prefs.setString('device_logs', jsonEncode(_logsDispositivos)); }
  void _guardarRegistroAparato() { if (_deviceCtrl.text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pon nombre al aparato'), backgroundColor: Colors.orange)); return; } setState(() { _logsDispositivos.insert(0, { 'name': _deviceCtrl.text, 'start': DateTime.now().toIso8601String() }); _saveDeviceLogs(); _addLog("Registro: ${_deviceCtrl.text}"); _deviceCtrl.clear(); }); }
  void _exportarDatos() { Clipboard.setData(ClipboardData(text: jsonEncode(_logsDispositivos))); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copiado en JSON'), backgroundColor: Colors.green)); }
  void _importarDatos() { TextEditingController importCtrl = TextEditingController(); showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Importar JSON"), content: TextField(controller: importCtrl, maxLines: 5, decoration: const InputDecoration(border: OutlineInputBorder())), actions: [ TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")), ElevatedButton(onPressed: () { try { List<dynamic> p = jsonDecode(importCtrl.text); setState(() { _logsDispositivos.addAll(p.cast<Map<String, dynamic>>()); _logsDispositivos.sort((a, b) => DateTime.parse(b['start']).compareTo(DateTime.parse(a['start']))); }); _saveDeviceLogs(); Navigator.pop(ctx); } catch(e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error JSON'), backgroundColor: Colors.red)); } }, child: const Text("IMPORTAR")) ])); }

  Future<void> _analizarMeteoElectrica() async {
    try {
      _addLog("Consultando Radares Meteo...");
      final resViento = await http.get(Uri.parse("https://api.open-meteo.com/v1/forecast?latitude=41.65&longitude=-0.88&daily=wind_speed_10m_max&timezone=Europe%2FMadrid&forecast_days=2")).timeout(const Duration(seconds: 10));
      final resSol = await http.get(Uri.parse("https://api.open-meteo.com/v1/forecast?latitude=37.38&longitude=-5.98&daily=cloud_cover_mean&timezone=Europe%2FMadrid&forecast_days=2")).timeout(const Duration(seconds: 10));
      
      if (resViento.statusCode == 200 && resSol.statusCode == 200) {
        final jViento = jsonDecode(resViento.body); final jSol = jsonDecode(resSol.body);
        num vientoManana = jViento['daily']['wind_speed_10m_max'][1] ?? 0; int nubesManana = jSol['daily']['cloud_cover_mean'][1] ?? 0;
        _addLog("Meteo obtenida: $vientoManana km/h, $nubesManana% nubes.");
        
        setState(() { _detallesMeteo = "🌬️ Valle del Ebro (Zaragoza): $vientoManana km/h\n☀️ Valle del Guadalquivir (Sevilla): $nubesManana% Nubes"; });

        String textoNativo = "";
        if (vientoManana >= 20 && nubesManana <= 40) { textoNativo = "Día excelente: viento nocturno para carga barata y sol radiante para horas diurnas hundidas."; } 
        else if (vientoManana >= 20) { textoNativo = "Vientos moderados/fuertes previstos. Eólica activa: madrugada propicia para cargar el Leapmotor a buen precio."; } 
        else if (nubesManana <= 40) { textoNativo = "Poco viento, pero cielos despejados. Inyección solar masiva: carga a mediodía (14h-17h) para aprovechar horas valle."; } 
        else { textoNativo = "Previsión de poca energía renovable en el mix eléctrico. Ojo, los precios indexados tenderán al alza."; }

        if (!mounted) return;
        setState(() { _prediccionMeteo = textoNativo; });
        _sincronizarWidgetNativo();
      } else {
        if (!mounted) return; setState(() => _prediccionMeteo = "Radares no disponibles temporalmente.");
      }
    } catch(e) {
      if (!mounted) return; setState(() => _prediccionMeteo = "Información meteorológica no disponible.");
    }
  }

  Future<void> _forzarRefrescoCompleto() async {
    _addLog("Iniciando purga de sesión fantasma...");
    setState(() { _isLoggedIn = false; _status = "Cerrando sesión fantasma..."; _desgloseDiario.clear(); _costeEnergia = 0.0; _kwhTotal = 0.0; });
    await _webController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/logout')));
    await Future.delayed(const Duration(seconds: 2));
    setState(() => _prediccionMeteo = "Recalculando radares..."); 
    _analizarMeteoElectrica();
    setState(() => _status = "Iniciando sesión desde cero...");
    await _webController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')));
    await Future.delayed(const Duration(seconds: 3));
  }

  Future<void> _leerPLC({bool isBaseMeasurement = false}) async { setState(() { _loadingPLC = true; _instantWatts = "..."; }); _addLog("Negociando PLC..."); try { var res = await _webController?.callAsyncJavaScript(functionBody: "async function runHandshake() { try { await fetch('/consumidores/rest/loginNew/mantenerSesion/'); await fetch('/consumidores/rest/escenarioNew/validarComunicacionContador/'); await fetch('/consumidores/rest/escenarioNew/nuevoEscenario/'); await new Promise(r => setTimeout(r, 6000)); let r = await fetch('/consumidores/rest/escenarioNew/obtenerMedicionOnline/24'); let data = await r.json(); return data.valMagnitud || 'ERROR'; } catch(e) { return 'REINTENTAR'; } } let val = await runHandshake(); if(val === 'REINTENTAR') { await new Promise(r => setTimeout(r, 3000)); return await runHandshake(); } return val;").timeout(const Duration(seconds: 25)); if (res?.value != null && res!.value.toString() != "ERROR") { double w = double.parse(res!.value.toString()); setState(() { _instantWatts = "${w.toStringAsFixed(0)} W"; if (isBaseMeasurement) _baseWatts = w; }); if (!isBaseMeasurement && _baseWatts > 0) { _consultarGroqEficiencia(w - _baseWatts); } } else { setState(() { _instantWatts = "Fallo PLC"; }); } } catch(e) { setState(() => _instantWatts = "Timeout"); } finally { setState(() => _loadingPLC = false); } }
  Future<void> _consultarGroqEficiencia(double watios) async { if (_groqKey.isEmpty) return; String disp = _deviceCtrl.text.isEmpty ? "Este electrodoméstico" : _deviceCtrl.text; try { final r = await http.post(Uri.parse('https://api.groq.com/openai/v1/chat/completions'), headers: { 'Authorization': 'Bearer $_groqKey', 'Content-Type': 'application/json' }, body: jsonEncode({ "model": "openai/gpt-oss-120b", "messages": [ {"role": "user", "content": "Analiza: $disp consume $watios W. ¿Es normal? Responde corto."} ], "temperature": 1, "max_completion_tokens": 1024, "top_p": 1, "reasoning_effort": "medium" })); if (r.statusCode == 200) { String t = jsonDecode(utf8.decoder.convert(r.bodyBytes))['choices'][0]['message']['content']; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("🤖 IA: $t"), backgroundColor: Colors.purple, duration: const Duration(seconds: 8))); } } catch(e) {} }

  void _recalcularCosteEnergia() { 
    if (_tarifaSeleccionada == 'Octopus Flexi Live') { 
        setState(() { _costeEnergia = _costeExactoFlexi; }); 
    } else { 
        final precios = _tarifasSimulator[_tarifaSeleccionada]!; 
        setState(() { _costeEnergia = (_kwhPunta * precios['p']!) + (_kwhLlano * precios['l']!) + (_kwhValle * precios['v']!); }); 
    }
    _sincronizarWidgetNativo(); 
  }
  
  Future<void> _sincronizarWidgetNativo() async { 
      double totalEuros = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; 
      int diasRegistrados = _fetchEnd.difference(_cycleStart).inDays + 1; 
      int diasTotales = _cycleEnd.difference(_cycleStart).inDays + 1; 
      double pred = diasRegistrados > 0 ? (totalEuros / diasRegistrados) * diasTotales : 0.0; 
      
      String textoWidget = "Carga nocturna con tarifa indexada, ahorras y cuidas tu planeta.";
      if (_consejoIA.isNotEmpty && !_consejoIA.contains("Analizando")) { textoWidget = "🔌 $_consejoIA"; }
      
      try { await const MethodChannel('widget_channel').invokeMethod('updateWidget', { 'fechas': '${_formatDateShort(_cycleStart)} al ${_formatDateShort(_fetchEnd)}', 'euros': '${totalEuros.toStringAsFixed(2)} €', 'kwh': '${_kwhTotal.toStringAsFixed(1)} kWh', 'prediccion': 'Predicción: ${pred.toStringAsFixed(2)} €', 'consejo': textoWidget }); } catch (e) {} 
  }

  void _comprobarAccesoExitoso(String path) { 
    if (!path.contains('login') && !path.contains('logout') && path.length > 5) { 
        _rescueTimer?.cancel(); 
        if (!_isLoggedIn) { 
            setState(() { 
                _isLoggedIn = true; 
                _status = "Calculando..."; 
                _showWebFallback = false; 
                _prediccionMeteo = _prediccionMeteo; 
                _detallesMeteo = _detallesMeteo;
            }); 
            _actualizarDatos(); 
        } 
    } 
  }

  Future<void> _consultarGroqIA() async { if (_groqKey.isEmpty || _topHoras.isEmpty) return; setState(() => _consejoIA = "Analizando consumo..."); try { String picos = _topHoras.map((h) => "${h['hora']}:00 (${h['kwh'].toStringAsFixed(1)}kWh)").join(", "); final r = await http.post(Uri.parse('https://api.groq.com/openai/v1/chat/completions'), headers: { 'Authorization': 'Bearer $_groqKey', 'Content-Type': 'application/json' }, body: jsonEncode({ "model": "openai/gpt-oss-120b", "messages": [ {"role": "user", "content": "Usuario va a tener coche Leapmotor eléctrico. Sus picos hoy son: $picos. Dale 1 consejo breve (10 palabras) animándole sobre la tarifa indexada y la carga."} ], "temperature": 0.8, "max_completion_tokens": 1024 })); if (r.statusCode == 200) { setState(() { _consejoIA = jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content'].toString().replaceAll('"', '').trim(); }); _sincronizarWidgetNativo(); } } catch(e) {} }

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
    _recalcularCosteEnergia(); _consultarGroqIA(); _calcularComparadorTarifas();
  }

  // Comparador: con el consumo horario REAL ya descargado, calcula cuánto
  // habría costado la energía (sin potencia/impuestos) con cada tarifa.
  void _calcularComparadorTarifas() {
    Map<String, double> resultado = {};
    for (var nombreTarifa in _tarifasSimulator.keys) {
      double total = 0.0;
      _horasPorDia.forEach((fecha, horas) {
        for (int h = 0; h < horas.length; h++) {
          double precio;
          if (nombreTarifa == 'Octopus Flexi Live') {
            if (_preciosHistoricos.containsKey(fecha) && h < _preciosHistoricos[fecha]!.length) {
              precio = _preciosHistoricos[fecha]![h];
            } else {
              if (h >= 10 && h < 14 || h >= 18 && h < 22) precio = 0.18; else if (h >= 8 && h < 10 || h >= 14 && h < 18 || h >= 22 && h <= 23) precio = 0.13; else precio = 0.08;
            }
          } else {
            final precios = _tarifasSimulator[nombreTarifa]!;
            if (h >= 10 && h < 14 || h >= 18 && h < 22) precio = precios['p']!; else if (h >= 8 && h < 10 || h >= 14 && h < 18 || h >= 22 && h <= 23) precio = precios['l']!; else precio = precios['v']!;
          }
          total += horas[h] * precio;
        }
      });
      resultado[nombreTarifa] = total;
    }
    if (mounted) setState(() { _comparadorTarifas = resultado; });
  }

  Future<void> _descargarPrecioDia(DateTime date) async {
      String sDate = "${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}"; String fechaKey = "${date.day.toString().padLeft(2,'0')}/${date.month.toString().padLeft(2,'0')}";
      try { final res = await http.get(Uri.parse("https://api.esios.ree.es/archives/70/download?date=$sDate")); if (res.statusCode == 200) { final j = jsonDecode(res.body); List<dynamic> precios = j['PVPC']; if (precios != null && precios.length >= 24) { _preciosHistoricos[fechaKey] = precios.map((p) { return double.parse(p['PCB'].toString().replaceAll(',', '.')) / 1000.0; }).toList().sublist(0, 24); return; } } } catch(e) {}
  }

  Future<void> _actualizarDatos() async { 
    String start = _formatDate(_cycleStart); String end = _formatDate(_fetchEnd); 
    _addLog("Descargando E-SIOS ($start al $end)..."); List<Future<void>> tareas = []; DateTime dCursor = _cycleStart; DateTime today = DateTime.now();
    DateTime fetchLimit = _fetchEnd; if (fetchLimit.isAfter(today)) fetchLimit = today;
    while (dCursor.isBefore(fetchLimit) || _formatDate(dCursor) == _formatDate(fetchLimit)) { tareas.add(_descargarPrecioDia(dCursor)); dCursor = dCursor.add(const Duration(days: 1)); }
    await Future.wait(tareas); _addLog("Histórico E-SIOS OK.");
    try { 
      var resLogin = await _webController?.callAsyncJavaScript(functionBody: "let r = await fetch('https://www.i-de.es/consumidores/rest/login/'); return await r.text();"); 
      if (resLogin?.value != null && !resLogin!.value.toString().contains("WU1")) { 
        var resDias = await _webController?.callAsyncJavaScript(functionBody: "let r = await fetch('https://www.i-de.es/consumidores/rest/consumoNew/obtenerDatosConsumoDH/$start/$end/dias/USU/'); return await r.text();");
        if (resDias?.value != null && resDias!.value.toString().length > 10) {
            try {
                final List data = jsonDecode(resDias!.value.toString()); 
                if(data.isNotEmpty && data[0]['totalesPeriodosTarifarios'] != null) { 
                  double p = (double.tryParse(data[0]['totalesPeriodosTarifarios'][0].toString())??0)/1000; double l = (double.tryParse(data[0]['totalesPeriodosTarifarios'][1].toString())??0)/1000; double v = (double.tryParse(data[0]['totalesPeriodosTarifarios'][2].toString())??0)/1000; 
                  int diasCalculo = _fetchEnd.difference(_cycleStart).inDays + 1; 
                  setState(() { 
                      _kwhTotal = p+l+v; _kwhPunta = p; _kwhLlano = l; _kwhValle = v; 
                      _costePotencia = ((4.4 * 0.076) + (5.7 * 0.002)) * diasCalculo; 
                      _cuotaOctopus = (0.123 + 0.019 + 0.027) * diasCalculo;
                      if (_costeExactoFlexi == 0.0) { _costeExactoFlexi = (p * 0.145) + (l * 0.098) + (v * 0.055); }
                      _lastSyncTime = DateTime.now(); _lastSyncError = null;
                  });
                  final prefsSync = await SharedPreferences.getInstance();
                  await prefsSync.setString('last_sync_ts', _lastSyncTime!.toIso8601String());
                  await prefsSync.remove('last_sync_error');
                }
            } catch (err) { _addLog("Error JSON Días: $err"); }
        }
        await _webController?.evaluateJavascript(source: "(async function() { try { let rH = await fetch('https://www.i-de.es/consumidores/rest/consumoNew/obtenerDatosConsumoDH/$start/$end/horas/USU/'); let dH = await rH.json(); if(dH && dH.length > 0 && dH[0].valores) { window.flutter_inappwebview.callHandler('consumosIberdrola', dH[0].valores); } else { window.flutter_inappwebview.callHandler('consumosIberdrola', []); } } catch(e) { window.flutter_inappwebview.callHandler('consumosIberdrola', []); } })();"); 
      } 
    } catch(e) { _addLog("Error API Global: $e"); } 
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

      String t = "        OCTOPUS FLEXI v36   \n------------------------------\nCiclo: ${_formatDate(_cycleStart)} a ${_formatDate(_cycleEnd)}\nDatos hasta: ${_formatDateShort(_fetchEnd)}\n------------------------------\n\n";
      
      double totalEurosCiclo = 0;
      double totalKwhCiclo = 0;

      for (var dia in _desgloseDiario) {
          if(dia['isFuture'] == false) {
              DateTime d = _cycleStart.add(Duration(days: dia['diaIndex']));
              bool v = d.weekday == DateTime.saturday || d.weekday == DateTime.sunday || _esFestivoNacional(d);
              String tramo = v ? "V" : "P"; 

              double costeDia = 0.0;
              List<double> horasDia = _horasPorDia[dia['fecha']] ?? List.filled(24, 0.0);
              
              if (_tarifaSeleccionada == 'Octopus Flexi Live') {
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
    List<double> horas = _horasPorDia[fecha] ?? []; String t = "        OCTOPUS FLEXI v36   \n------------------------------\nDesglose $fecha\nFranja: $startH:00 a $endH:00\n------------------------------\n\n"; double totalKwh = 0; double totalEurosFranja = 0; double maxKwh = 0; for(var h in horas) if(h > maxKwh) maxKwh = h;
    for(int i = startH; i < endH; i++) {
       if (i < horas.length) {
         double costeHora = 0.0; String tramo = "V";
         if (_tarifaSeleccionada == 'Octopus Flexi Live') { double p = 0.10; if (_preciosHistoricos.containsKey(fecha) && i < _preciosHistoricos[fecha]!.length) { p = _preciosHistoricos[fecha]![i]; } else { if (i >= 10 && i < 14 || i >= 18 && i < 22) p = 0.18; else if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) p = 0.13; else p = 0.08; } costeHora = horas[i] * p; if (i >= 8 && i < 10 || i >= 14 && i < 18 || i >= 22 && i <= 23) { tramo = "L"; } else if (i >= 10 && i < 14 || i >= 18 && i < 22) { tramo = "P"; }
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

  void _abrirChatIA() { showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (context) => StatefulBuilder(builder: (BuildContext context, StateSetter setModalState) { TextEditingController txtCtrl = TextEditingController(); Future<void> enviarMensaje() async { if (txtCtrl.text.isEmpty) return; String userTxt = txtCtrl.text; txtCtrl.clear(); setModalState(() { _chatMessages.add({"role": "user", "msg": userTxt}); _chatMessages.add({"role": "ai", "msg": "Calculando con IA..."}); }); try { double totalEuros = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; List msgs = [{"role": "system", "content": "Eres el Oráculo del Leapmotor B10. Ayudas al usuario a optimizar su consumo eléctrico en casa y en el coche con tarifa indexada Octopus Flexi."}, {"role": "user", "content": "Usuario gastó ${totalEuros.toStringAsFixed(2)}€ hasta hoy en el ciclo."}]; for(var m in _chatMessages) { if(m['msg'] != "Calculando con IA...") msgs.add({"role": m['role'] == "user" ? "user" : "assistant", "content": m['msg']}); } final r = await http.post(Uri.parse('https://api.groq.com/openai/v1/chat/completions'), headers: { 'Authorization': 'Bearer $_groqKey', 'Content-Type': 'application/json' }, body: jsonEncode({ "model": "openai/gpt-oss-120b", "messages": msgs, "temperature": 0.8, "max_completion_tokens": 1024 })); if (r.statusCode == 200) { setModalState(() { _chatMessages.last = {"role": "ai", "msg": jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content'].toString()}; }); } } catch(e) {} } return Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom), child: Container(height: MediaQuery.of(context).size.height * 0.7, padding: const EdgeInsets.all(16), child: Column(children: [const Text("Oráculo del Leapmotor", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))), const Divider(), Expanded(child: ListView.builder(itemCount: _chatMessages.length, itemBuilder: (c, i) { bool isUser = _chatMessages[i]['role'] == 'user'; return Align(alignment: isUser ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: isUser ? const Color(0xFF00E5FF) : Colors.cyan.shade50, borderRadius: BorderRadius.circular(16)), child: Text(_chatMessages[i]['msg']!, style: TextStyle(color: isUser ? Colors.black87 : Colors.black87, fontWeight: isUser ? FontWeight.normal : FontWeight.w500)))); })), Row(children: [ Expanded(child: TextField(controller: txtCtrl, decoration: InputDecoration(hintText: "Pregunta...", border: OutlineInputBorder(borderRadius: BorderRadius.circular(20))))), IconButton(icon: const Icon(Icons.send, color: Color(0xFF00E5FF)), onPressed: enviarMensaje) ]) ]))); })); }

  Widget _tarjetaDinero() { 
    double total = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; 
    return Container(
      padding: const EdgeInsets.all(20), 
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF00B4DB), Color(0xFF0083B0)]), borderRadius: BorderRadius.circular(20)), 
      child: Column(children: [
        
        // LA BÓVEDA HISTORIAL (Desplegable mágico)
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
            onChanged: (String? n) { if(n != null) { setState(() => _tarifaSeleccionada = n); _recalcularCosteEnergia(); } }
          )
        )
      ])
    ); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF00E5FF), title: const Text("eConsumo EV Edition", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)), centerTitle: true, actions: [ if (_email.isNotEmpty) IconButton(icon: const Icon(Icons.logout, color: Colors.black87), onPressed: _cerrarSesion) ]),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Offstage(offstage: !_showWebFallback, child: InAppWebView(initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')), initialSettings: InAppWebViewSettings(userAgent: 'Mozilla/5.0 (Linux; Android 13)', javaScriptEnabled: true, domStorageEnabled: true), onWebViewCreated: (c) { _webController = c; c.addJavaScriptHandler(handlerName: 'appLog', callback: (a) => _addLog(a[0].toString())); c.addJavaScriptHandler(handlerName: 'spaNav', callback: (a) => _comprobarAccesoExitoso(a[0].toString())); c.addJavaScriptHandler(handlerName: 'consumosIberdrola', callback: (a) => _procesarCurvasHorarias(a[0])); }, onUpdateVisitedHistory: (c, url, r) => _comprobarAccesoExitoso(url?.path ?? ''), onLoadStop: (c, url) async { if ((url?.path ?? '').contains('login') && _email.isNotEmpty && !_isLoggedIn) { setState(() => _status = "Autenticando..."); _rescueTimer = Timer(const Duration(seconds: 15), () { if (!_isLoggedIn && mounted) setState(() => _showWebFallback = true); }); await c.evaluateJavascript(source: "setInterval(() => { let cp = window.location.pathname; if (window._lp !== cp) { window._lp = cp; window.flutter_inappwebview.callHandler('spaNav', cp); } }, 1000); async function autoLogin(e,p,a){ let btn=Array.from(document.querySelectorAll('button')).find(b=>b.innerText&&b.innerText.toLowerCase().includes('entrar')); let em=document.querySelector('input[type=\"email\"]')||document.querySelector('input[name=\"email\"]'); let pw=document.querySelector('input[type=\"password\"]'); if(em&&pw&&btn){ const ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,\"value\").set; em.focus();ns.call(em,e);em.dispatchEvent(new Event('input',{bubbles:true})); await new Promise(r=>setTimeout(r,400)); pw.focus();ns.call(pw,p);pw.dispatchEvent(new Event('input',{bubbles:true})); await new Promise(r=>setTimeout(r,600)); btn.click(); } else if(a>0) setTimeout(()=>autoLogin(e,p,a-1),1500); } autoLogin('$_email','$_pass',6);"); } })),
                if (!_showWebFallback) ...[
                  if (_email.isEmpty) _pantallaLoginNatva() else if (!_isLoggedIn) Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const CircularProgressIndicator(color: Color(0xFF00E5FF)), const SizedBox(height: 24), Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))])) else RefreshIndicator(onRefresh: _forzarRefrescoCompleto, color: const Color(0xFF00E5FF), child: ListView(padding: const EdgeInsets.all(16), children: [ 
                    
                    _bannerEstadoSync(), const SizedBox(height: 12),
                    _tarjetaDinero(), const SizedBox(height: 16),
                    _tarjetaDesglose(), const SizedBox(height: 16),
                    _tarjetaComparadorTarifas(), const SizedBox(height: 16),

                    _tarjetaMeteoElectrica(), const SizedBox(height: 16),
                    
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
                    
                    // BOTONES DE TICKETS
                    if (_desgloseDiario.isNotEmpty) Row(children: [
                        Expanded(child: ElevatedButton.icon(onPressed: _mostrarTicketGenerado, icon: const Icon(Icons.calendar_today, color: Colors.white, size: 14), label: const Text("T. DÍAS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))), 
                        const SizedBox(width: 8), 
                        Expanded(child: ElevatedButton.icon(onPressed: _seleccionarDiaParaTicket24h, icon: const Icon(Icons.access_time, color: Colors.black87, size: 14), label: const Text("T. HORAS", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
                        const SizedBox(width: 8), 
                        Expanded(child: ElevatedButton.icon(onPressed: _generarTicketPreciosHoy, icon: const Icon(Icons.euro, color: Colors.white, size: 14), label: const Text("PRECIOS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade600, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))))
                    ]) ,
                    const SizedBox(height: 24),

                    _tarjetaPrediccionCompactaConChat(), const SizedBox(height: 16),
                    if(_consejoIA.isNotEmpty) ...[_tarjetaGroqIA(), const SizedBox(height: 16)], 
                    
                    _tarjetaInfoFlexi(), const SizedBox(height: 24),

                    if (_desgloseDiario.isNotEmpty) ...[_tarjetaGraficoVisual(), const SizedBox(height: 16)],
                    if (_promedioPorHora.isNotEmpty) ...[_tarjetaGraficoHorario(), const SizedBox(height: 16)],
                    if (_topHoras.isNotEmpty) ...[ _tarjetaPerfilHorario(), const SizedBox(height: 24), ],

                    const Text("  HERRAMIENTAS DE ANÁLISIS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12, letterSpacing: 1.2)), const SizedBox(height: 8),
                    _seccionEficiencia(), const SizedBox(height: 16), 
                    _tarjetaLogsAparatos(), const SizedBox(height: 16),
                  ]))
                ]
              ],
            ),
          ),
          Container(height: 120, width: double.infinity, color: Colors.black, padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("> TERMINAL SNIFFER", style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)), Row(children: [IconButton(icon: const Icon(Icons.copy, color: Colors.white, size: 20), onPressed: _copiarLog), if (_email.isNotEmpty) ElevatedButton(onPressed: () => setState(() => _showWebFallback = !_showWebFallback), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(60, 25)), child: Text(_showWebFallback ? "OCULTAR WEB" : "VER WEB", style: const TextStyle(fontSize: 9, color: Colors.white)))])]), Expanded(child: ListView.builder(controller: _logScrollController, itemCount: _logs.length, itemBuilder: (c, i) => Text(_logs[i], style: TextStyle(color: _logs[i].contains("Error") || _logs[i].contains("Fallo") || _logs[i].contains("WU1") ? Colors.redAccent : Colors.white70, fontSize: 10, fontFamily: 'monospace'))))]))
        ],
      ),
    );
  }

  Widget _bannerEstadoSync() {
    if (_lastSyncTime == null && _lastSyncError == null) return const SizedBox.shrink();
    Duration? diff = _lastSyncTime != null ? DateTime.now().difference(_lastSyncTime!) : null;
    bool stale = diff == null || diff.inHours >= 13;
    String texto;
    if (_lastSyncTime == null) {
      texto = "Sin sincronización automática registrada todavía.";
    } else if (diff!.inMinutes < 60) {
      texto = "Última actualización automática: hace ${diff.inMinutes} min.";
    } else {
      texto = "Última actualización automática: hace ${diff.inHours} h.";
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: stale ? Colors.red.shade50 : Colors.green.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: stale ? Colors.red.shade200 : Colors.green.shade200)),
      child: Row(children: [
        Icon(stale ? Icons.warning_amber_rounded : Icons.check_circle, color: stale ? Colors.red : Colors.green, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(texto, style: TextStyle(fontSize: 11, color: stale ? Colors.red.shade900 : Colors.green.shade900, fontWeight: FontWeight.bold))),
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
        const Text("Solo energía (sin potencia fija ni impuestos), calculado con tu consumo horario real.", style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
      ]),
    );
  }

  // --- WIDGETS RESTANTES DE LA INTERFAZ ---
  Widget _tarjetaMeteoElectrica() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF263238), borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Container(padding: const EdgeInsets.all(12), decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle), child: const Icon(Icons.thunderstorm, color: Colors.amberAccent, size: 28)), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("🌤️ RADAR METEO-ELÉCTRICO (MAÑANA)", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1.2)), const SizedBox(height: 6), Text(_prediccionMeteo, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4))]))]), const SizedBox(height: 12), const Divider(color: Colors.white12), const SizedBox(height: 8), Text(_detallesMeteo, style: const TextStyle(color: Colors.white38, fontSize: 10, fontStyle: FontStyle.italic))]));
  Widget _pantallaLoginNatva() { final eCtrl = TextEditingController(text: _email); final pCtrl = TextEditingController(text: _pass); final gCtrl = TextEditingController(text: _groqKey); String labelGroq = _groqKey.length >= 4 ? "Groq Key (Actual: ${_groqKey.substring(0, 4)}...)" : "Groq API Key (Opcional)"; return Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24.0), child: Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), child: Padding(padding: const EdgeInsets.all(24.0), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.electric_car, size: 60, color: Color(0xFF00E5FF)), const SizedBox(height: 16), const Text("eConsumo EV Connect", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(height: 24), TextField(controller: eCtrl, decoration: const InputDecoration(labelText: "Email Iberdrola", border: OutlineInputBorder(), prefixIcon: Icon(Icons.email))), const SizedBox(height: 16), TextField(controller: pCtrl, obscureText: true, decoration: const InputDecoration(labelText: "Contraseña", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock))), const SizedBox(height: 16), TextField(controller: gCtrl, obscureText: true, decoration: InputDecoration(labelText: labelGroq, border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.smart_toy, color: Colors.indigo))), const SizedBox(height: 24), SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () async { final prefs = await SharedPreferences.getInstance(); await prefs.setString('email', eCtrl.text.trim()); await prefs.setString('pass', pCtrl.text); await prefs.setString('groq_key', gCtrl.text.trim()); setState(() { _email = eCtrl.text.trim(); _pass = pCtrl.text; _groqKey = gCtrl.text.trim(); _status = "Conectando..."; _showWebFallback = false; }); _webController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login'))); }, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black87, padding: const EdgeInsets.symmetric(vertical: 16)), child: const Text("CONECTAR", style: TextStyle(fontWeight: FontWeight.bold))))])))))); }
  Widget _seccionEficiencia() => Card(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.grey.shade300)), color: Colors.white, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [ const Icon(Icons.check_circle_outline, color: Colors.blueGrey, size: 18), const SizedBox(width: 8), const Text("REGISTRO DE USO", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), ]), const SizedBox(height: 12), TextField(controller: _deviceCtrl, decoration: const InputDecoration(hintText: "Ej: Carga Leapmotor, Horno...", border: OutlineInputBorder(), prefixIcon: Icon(Icons.ev_station))), const SizedBox(height: 10), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _guardarRegistroAparato, icon: const Icon(Icons.save, color: Colors.black87), label: const Text("GUARDAR REGISTRO", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), padding: const EdgeInsets.symmetric(vertical: 12)), ))])));
  Widget _tarjetaLogsAparatos() => Card(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.grey.shade300)), color: Colors.white, child: Column(children: [Padding(padding: const EdgeInsets.all(12), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ const Text("HISTORIAL APARATOS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), Row(children: [ IconButton(icon: const Icon(Icons.download, size: 18, color: Colors.blueGrey), onPressed: _importarDatos, tooltip: "Importar JSON"), IconButton(icon: const Icon(Icons.upload, size: 18, color: Colors.blueGrey), onPressed: _exportarDatos, tooltip: "Exportar JSON"), ],) ])), const Divider(height: 1), Container(height: 150, child: _logsDispositivos.isEmpty ? const Center(child: Text("No hay registros.", style: TextStyle(color: Colors.grey))) : ListView.separated(itemCount: _logsDispositivos.length, separatorBuilder: (c, i) => const Divider(height: 1), itemBuilder: (c, i) { final log = _logsDispositivos[i]; final start = DateTime.parse(log['start']); return ListTile(leading: const Icon(Icons.history, color: Colors.blueGrey), title: Text(log['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), subtitle: Text("${start.day}/${start.month} - ${start.hour.toString().padLeft(2,'0')}:${start.minute.toString().padLeft(2,'0')}"), trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18), onPressed: () { setState(() { _logsDispositivos.removeAt(i); }); _saveDeviceLogs(); }),); },),),]));
  Widget _tarjetaGraficoVisual() { double maxKwh = 0; for(var d in _desgloseDiario){ if(d['kwh']>maxKwh) maxKwh = d['kwh']; } return Container(padding: const EdgeInsets.all(16), height: 250, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text("CONSUMO DEL MES (kWh)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const SizedBox(height: 16), Expanded(child: BarChart(BarChartData(alignment: BarChartAlignment.spaceAround, maxY: maxKwh > 0 ? maxKwh * 1.2 : 5, barTouchData: BarTouchData(enabled: true, touchTooltipData: BarTouchTooltipData(getTooltipColor: (group) => Colors.black87, tooltipPadding: const EdgeInsets.all(8), tooltipMargin: 8, getTooltipItem: (group, groupIndex, rod, rodIndex) { return BarTooltipItem("${rod.toY.toStringAsFixed(2)} kWh", const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 14)); })), titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22, interval: 5, getTitlesWidget: (v, m) { if (v.toInt() % 5 != 0) return const SizedBox(); return Text(_desgloseDiario[v.toInt()]['fecha'].split('/')[0], style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)); })), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), gridData: FlGridData(show: false), barGroups: _desgloseDiario.asMap().entries.map((e) => BarChartGroupData(x: e.key, barRods: [BarChartRodData(toY: e.value['isFuture'] ? 0.05 : e.value['kwh'], color: e.value['isFuture'] ? Colors.grey.shade300 : const Color(0xFF00E5FF), width: 6, borderRadius: BorderRadius.circular(2), backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxKwh > 0 ? maxKwh * 1.2 : 5, color: Colors.grey.shade100))])).toList() ))) ])); }
  Widget _tarjetaGraficoHorario() { double maxKwh = 0; for(var d in _promedioPorHora){ if(d>maxKwh) maxKwh = d; } return Container(padding: const EdgeInsets.all(16), height: 250, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text("PERFIL HORARIO MEDIO (kWh)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const SizedBox(height: 16), Expanded(child: LineChart(LineChartData(lineBarsData: [LineChartBarData(spots: _promedioPorHora.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(), isCurved: true, color: Colors.indigoAccent, barWidth: 3, isStrokeCapRound: true, belowBarData: BarAreaData(show: true, color: Colors.indigoAccent.withOpacity(0.2)))], titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 6, reservedSize: 22, getTitlesWidget: (v, m) { if (v.toInt() % 6 != 0) return const SizedBox(); return Text("${v.toInt()}h", style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)); })), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), gridData: FlGridData(show: false), lineTouchData: LineTouchData(enabled: true, touchTooltipData: LineTouchTooltipData(getTooltipColor: (group) => Colors.black87, getTooltipItems: (spots) => spots.map((s) => LineTooltipItem("${s.x.toInt()}h: ${s.y.toStringAsFixed(3)} kWh", const TextStyle(color: Colors.indigoAccent, fontWeight: FontWeight.bold))).toList())) ))) ])); }
  Widget _tarjetaGroqIA() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF00C6FF), Color(0xFF0072FF)]), borderRadius: BorderRadius.circular(20)), child: Row(children: [const Icon(Icons.psychology, color: Colors.white, size: 40), const SizedBox(width: 16), Expanded(child: Text(_consejoIA, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, fontStyle: FontStyle.italic)))]));
  Widget _tarjetaDesglose() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("TICKET DE COMPRA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12)), const Divider(), _filaDesglose("Energía Consumida", _costeEnergia, true), Padding(padding: const EdgeInsets.only(left: 16, bottom: 8), child: Row(children: [Text("${_kwhTotal.toStringAsFixed(1)} kWh procesados", style: const TextStyle(color: Colors.grey, fontSize: 11))])), _filaDesglose("Potencia Fija", _costePotencia, false), _filaDesglose("Gestión y Extras", _cuotaOctopus, false), const Divider(), _filaDesglose("Impuestos (IVA + IE)", ((_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva) - (_costeEnergia + _costePotencia + _cuotaOctopus), false)]));
  Widget _tarjetaPerfilHorario() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: const [Icon(Icons.insights, size: 16, color: Colors.blueGrey), SizedBox(width: 8), Text("TUS PICOS DE CONSUMO (HORAS)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12))]), const Divider(), for (int i = 0; i < _topHoras.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("${i+1}. Hora: ${_topHoras[i]['hora'].toString().padLeft(2,'0')}:00 - ${_topHoras[i]['hora']+1}:00", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)), Text("${_topHoras[i]['kwh'].toStringAsFixed(1)} kWh", style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))]))]));
  Widget _filaDesglose(String t, double c, bool b) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(t, style: TextStyle(fontWeight: b ? FontWeight.bold : FontWeight.normal)), Text("${c.toStringAsFixed(2)} €", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))]));
  Widget _tarjetaPrediccionCompactaConChat() { double totalEuros = (_costeEnergia + _costePotencia + _cuotaOctopus) * _impuestoElectrico * _iva; int diasRegistrados = _fetchEnd.difference(_cycleStart).inDays + 1; int diasTotales = _cycleEnd.difference(_cycleStart).inDays + 1; double pred = diasRegistrados > 0 ? (totalEuros / diasRegistrados) * diasTotales : 0.0; return Card(color: Colors.white, elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.indigo.shade200)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Row(children: [const Icon(Icons.trending_up, color: Colors.indigo, size: 24), const SizedBox(width: 12), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [const Text("PREDICCIÓN FIN DE CICLO", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)), Text("${pred.toStringAsFixed(2)} €", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.indigo)),],),],), if (_groqKey.isNotEmpty) GestureDetector(onTap: _abrirChatIA, child: Container(padding: const EdgeInsets.all(10), decoration: const BoxDecoration(color: Color(0xFF00E5FF), shape: BoxShape.circle), child: const Icon(Icons.electric_car, color: Colors.black87, size: 20),),)],),),); }
  Widget _tarjetaInfoFlexi() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFE0F7FA), border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)), borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: const [Icon(Icons.ev_station, color: Colors.indigo, size: 20), SizedBox(width: 8), Text("Estrategia Leapmotor + Flexi", style: TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold, fontSize: 14))]), const SizedBox(height: 12), const Text("El sistema ahora evalúa tu histórico al milímetro. Recuerda: para llenar los 67.2kWh de tu Leapmotor al precio más barato, carga de 00:00 a 08:00 o los fines de semana.", style: TextStyle(fontSize: 12, color: Colors.black87)), const SizedBox(height: 8), const Text("ℹ️ El mercado OMIE subasta la luz a las 12:00h y los precios definitivos para el día siguiente se publican en E-SIOS a partir de las 20:30h.", style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.blueGrey)), const SizedBox(height: 16), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _imprimirMasterPlanEV, icon: const Icon(Icons.print, color: Colors.white), label: const Text("IMPRIMIR MASTERPLAN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, padding: const EdgeInsets.symmetric(vertical: 12))))]));
}
