import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EConsumoApp());
}

class EConsumoApp extends StatelessWidget {
  const EConsumoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eConsumo V2',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007A53)), 
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey.shade100,
      ),
      home: const DashboardScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  InAppWebViewController? _webViewController;
  bool _isLogged = false;
  
  // Estado del Tiempo Real
  bool _isFetchingInstant = false;
  double _currentKw = 0.0;
  String _lastUpdate = "--:--:--";
  String _statusInstant = "Pulsa para despertar al contador.";

  // Estado del Acumulado Mensual
  bool _isFetchingMonth = false;
  double _monthKwh = 0.0;
  String _statusMonth = "Esperando sincronizacion...";

  String _formatDate(DateTime d) => "${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLogged ? 'Centro de Mando' : 'Login i-DE', style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF007A53),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isLogged)
            IconButton(
              icon: const Icon(Icons.logout), 
              onPressed: () {
                _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/logout')));
                setState(() { _isLogged = false; _currentKw = 0.0; _monthKwh = 0.0; });
              }
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => _isLogged = true),
              icon: const Icon(Icons.check_circle, color: Colors.white),
              label: const Text('Forzar Inicio', style: TextStyle(color: Colors.white)),
            )
        ]
      ),
      body: Stack(
        children: [
          // 1. EL NAVEGADOR FANTASMA
          Offstage(
            offstage: _isLogged,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
              initialSettings: InAppWebViewSettings(
                userAgent: 'Mozilla/5.0 (Linux; Android 13; SM-S901B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
                javaScriptEnabled: true,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onLoadStop: (controller, url) {
                if (url != null && (url.path.contains('inicio') || url.path.contains('dashboard'))) {
                  _onLoginSuccess();
                }
              },
              onUpdateVisitedHistory: (controller, url, androidIsReload) {
                 if (url != null && (url.path.contains('inicio') || url.path.contains('dashboard') || url.path.contains('consumo'))) {
                  _onLoginSuccess();
                }
              }
            ),
          ),
          
          // 2. DASHBOARD NATIVO
          if (_isLogged)
            RefreshIndicator(
              onRefresh: _fetchMonthlyData,
              color: const Color(0xFF007A53),
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  const SizedBox(height: 8),
                  const Text("VISION GLOBAL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 12),
                  
                  // TARJETA 1: CONSUMO MENSUAL
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.calendar_month, color: Color(0xFF007A53)),
                                  SizedBox(width: 8),
                                  Text("Mes Actual", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              if (_isFetchingMonth) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text('${_monthKwh.toStringAsFixed(1)} kWh', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.black87)),
                          const SizedBox(height: 8),
                          Text(_statusMonth, style: TextStyle(color: _statusMonth.contains('Error') ? Colors.red : Colors.grey.shade600, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  const Text("MEDICION DIRECTA", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 12),

                  // TARJETA 2: TIEMPO REAL
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.bolt, color: Colors.amber, size: 28),
                              SizedBox(width: 8),
                              Text("Tiempo Real", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: Text('${_currentKw.toStringAsFixed(2)} kW', style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: Colors.black87)),
                          ),
                          const SizedBox(height: 4),
                          Center(child: Text('Ultima lectura: $_lastUpdate', style: const TextStyle(color: Colors.grey))),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
                            child: Text(_statusInstant, style: TextStyle(color: Colors.green.shade800, fontSize: 12), textAlign: TextAlign.center),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _isFetchingInstant ? null : _fetchInstantData,
                              icon: _isFetchingInstant ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.speed),
                              label: Text(_isFetchingInstant ? 'Leyendo PLC...' : 'Solicitar Lectura Ahora'),
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _onLoginSuccess() {
    if (!mounted || _isLogged) return;
    setState(() => _isLogged = true);
    // Disparamos la carga del historico mensual automaticamente al entrar
    _fetchMonthlyData();
  }

  // --- OBTENCION DEL MES ACTUAL ---
  Future<void> _fetchMonthlyData() async {
    setState(() { _isFetchingMonth = true; _statusMonth = "Sincronizando mes..."; });
    try {
      DateTime now = DateTime.now();
      String startOfMonth = "01-${now.month.toString().padLeft(2, '0')}-${now.year}";
      String today = _formatDate(now);

      var result = await _webViewController?.callAsyncJavaScript(functionBody: """
        try {
          let url = 'https://www.i-de.es/consumidores/rest/consumoNew/obtenerDatosConsumoDH/$startOfMonth/$today/dias/USU/';
          let resp = await fetch(url);
          if (!resp.ok) return "ERROR_HTTP_" + resp.status;
          return await resp.text();
        } catch(e) {
          return "ERROR_JS_" + e.toString();
        }
      """);

      String jsonStr = result?.value?.toString() ?? "";
      if (jsonStr.startsWith("ERROR_") || jsonStr.isEmpty) {
         setState(() => _statusMonth = "Fallo de conexion: $jsonStr");
      } else {
         final List<dynamic> data = jsonDecode(jsonStr);
         if (data.isNotEmpty && data[0]['total'] != null) {
            setState(() {
              _monthKwh = double.parse(data[0]['total'].toString()) / 1000.0;
              _statusMonth = "Actualizado: $today";
            });
         } else {
            setState(() => _statusMonth = "No hay datos de consumo en i-DE todavia.");
         }
      }
    } catch (e) {
       setState(() => _statusMonth = "Error: $e");
    } finally {
       if (mounted) setState(() => _isFetchingMonth = false);
    }
  }

  // --- OBTENCION DEL TIEMPO REAL ---
  Future<void> _fetchInstantData() async {
    setState(() { _isFetchingInstant = true; _statusInstant = "Despertando al contador inteligente..."; });
    try {
      var result = await _webViewController?.callAsyncJavaScript(functionBody: """
        try {
          await fetch('https://www.i-de.es/consumidores/rest/escenarioNew/validarComunicacionContador/');
          await fetch('https://www.i-de.es/consumidores/rest/escenarioNew/nuevoEscenario/');
          await new Promise(r => setTimeout(r, 3000));
          let resp = await fetch('https://www.i-de.es/consumidores/rest/escenarioNew/obtenerMedicionOnline/24');
          if (!resp.ok) return "ERROR_HTTP_" + resp.status;
          return await resp.text();
        } catch(e) {
          return "ERROR_JS_" + e.toString();
        }
      """);

      String jsonStr = result?.value?.toString() ?? "";
      if (jsonStr.startsWith("ERROR_") || jsonStr.isEmpty) {
         setState(() => _statusInstant = "Fallo de conexion: $jsonStr");
      } else {
         final data = jsonDecode(jsonStr);
         if (data['valMagnitud'] != null) {
            setState(() {
              _currentKw = double.parse(data['valMagnitud'].toString()) / 1000.0;
              final now = DateTime.now();
              _lastUpdate = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
              _statusInstant = "Lectura del contador extraida correctamente.";
            });
         } else {
            setState(() => _statusInstant = "Respuesta sin datos. Reintenta.");
         }
      }
    } catch (e) {
       setState(() => _statusInstant = "Error: $e");
    } finally {
       if (mounted) setState(() => _isFetchingInstant = false);
    }
  }
}
