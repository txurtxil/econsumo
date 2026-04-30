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
      title: 'eConsumo',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007A53)), useMaterial3: true),
      home: const MainEngineScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainEngineScreen extends StatefulWidget {
  const MainEngineScreen({super.key});
  @override
  State<MainEngineScreen> createState() => _MainEngineScreenState();
}

class _MainEngineScreenState extends State<MainEngineScreen> {
  InAppWebViewController? _webViewController;
  bool _isLogged = false;
  bool _isFetching = false;
  double _currentKw = 0.0;
  String _lastUpdate = "--:--:--";
  String _statusMessage = "Listo para leer el contador.";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLogged ? 'Monitor Tiempo Real' : 'Login i-DE'),
        backgroundColor: const Color(0xFF007A53),
        foregroundColor: Colors.white,
        actions: [
          if (_isLogged)
            IconButton(
              icon: const Icon(Icons.logout), 
              onPressed: () {
                _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/logout')));
                setState(() { _isLogged = false; _currentKw = 0.0; });
              }
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => _isLogged = true),
              icon: const Icon(Icons.login, color: Colors.white),
              label: const Text('Forzar Monitor', style: TextStyle(color: Colors.white)),
            )
        ]
      ),
      body: Stack(
        children: [
          // 1. EL NAVEGADOR FANTASMA: Se oculta cuando estamos logueados pero nunca muere
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
                // Auto-detección: si la URL incluye 'inicio' o 'dashboard', pasamos al monitor
                if (url != null && (url.path.contains('inicio') || url.path.contains('dashboard'))) {
                  if (mounted) setState(() => _isLogged = true);
                }
              },
              onUpdateVisitedHistory: (controller, url, androidIsReload) {
                 if (url != null && (url.path.contains('inicio') || url.path.contains('dashboard'))) {
                  if (mounted) setState(() => _isLogged = true);
                }
              }
            ),
          ),
          
          // 2. DASHBOARD DE LECTURA NATIVA
          if (_isLogged)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Potencia Demandada', style: TextStyle(fontSize: 18, color: Colors.grey)),
                    Text('${_currentKw.toStringAsFixed(2)} kW', style: const TextStyle(fontSize: 60, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Text('Ultima actualizacion: $_lastUpdate', style: const TextStyle(color: Colors.grey)),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: _statusMessage.contains('Error') ? Colors.red.shade50 : Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
                      child: Text(_statusMessage, style: TextStyle(color: _statusMessage.contains('Error') ? Colors.red : Colors.green.shade800, fontSize: 13), textAlign: TextAlign.center),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isFetching ? null : _fetchDataThroughWebView,
                        icon: _isFetching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.speed),
                        label: Text(_isFetching ? 'Hackeando Akamai...' : 'Solicitar Lectura al Contador'),
                        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 20), textStyle: const TextStyle(fontSize: 18)),
                      ),
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // LA MAGIA: Ejecutamos JavaScript DENTRO del navegador webview para saltarnos la seguridad
  Future<void> _fetchDataThroughWebView() async {
    setState(() { _isFetching = true; _statusMessage = "Solicitando datos al navegador fantasma..."; });
    try {
      var result = await _webViewController?.callAsyncJavaScript(functionBody: """
        try {
          let resp = await fetch('https://www.i-de.es/consumidores/rest/medicion/reloj/0', {
            headers: { 'Accept': 'application/json' }
          });
          if (!resp.ok) { return "ERROR_HTTP_" + resp.status; }
          return await resp.text();
        } catch(e) {
          return "ERROR_JS_" + e.toString();
        }
      """);

      String jsonStr = result?.value?.toString() ?? "";

      if (jsonStr.startsWith("ERROR_") || jsonStr.isEmpty) {
         setState(() => _statusMessage = "Fallo de conexion interno: $jsonStr");
      } else {
         final data = jsonDecode(jsonStr);
         if (data['valMagnitud'] != null) {
            setState(() {
              _currentKw = double.parse(data['valMagnitud'].toString()) / 1000.0;
              final now = DateTime.now();
              _lastUpdate = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
              _statusMessage = "Lectura del contador extraida correctamente.";
            });
         } else {
            setState(() => _statusMessage = "Respuesta del contador vacia. JSON: $jsonStr");
         }
      }
    } catch (e) {
       setState(() => _statusMessage = "Error de motor JS: $e");
    } finally {
       setState(() => _isFetching = false);
    }
  }
}
