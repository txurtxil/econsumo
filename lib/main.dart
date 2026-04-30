import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EConsumoApp());
}

class EConsumoApp extends StatelessWidget {
  const EConsumoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eConsumo Sniffer',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007A53)), useMaterial3: true),
      home: const SnifferScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SnifferScreen extends StatefulWidget {
  const SnifferScreen({super.key});
  @override
  State<SnifferScreen> createState() => _SnifferScreenState();
}

class _SnifferScreenState extends State<SnifferScreen> {
  InAppWebViewController? _webViewController;
  String _sniffedUrl = "Esperando a que pulses 'Nueva medición' en la web...";
  String _sniffedData = "...";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('eConsumo - Modo Diagnóstico', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF007A53),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // MITAD SUPERIOR: Navegador Web Real
          Expanded(
            flex: 6,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
              initialSettings: InAppWebViewSettings(
                userAgent: 'Mozilla/5.0 (Linux; Android 13; SM-S901B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
                javaScriptEnabled: true,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                
                // Escuchador que recibe los datos robados por el JavaScript
                controller.addJavaScriptHandler(handlerName: 'apiSniffer', callback: (args) {
                  String payload = args[0].toString();
                  List<String> parts = payload.split('|||');
                  if(parts.length == 2) {
                    String url = parts[0];
                    String json = parts[1];
                    
                    // Filtramos solo las peticiones importantes de la API
                    if(url.contains('/rest/') || url.contains('/api/')) {
                       setState(() {
                         _sniffedUrl = url;
                         _sniffedData = json.length > 500 ? json.substring(0, 500) + '...' : json;
                       });
                    }
                  }
                });
              },
              onLoadStop: (controller, url) async {
                // Inyectamos el Caballo de Troya que intercepta las peticiones Fetch y XHR
                await controller.evaluateJavascript(source: """
                  (function() {
                    if (window.hasSniffer) return;
                    window.hasSniffer = true;

                    const originalFetch = window.fetch;
                    window.fetch = async function() {
                        const url = typeof arguments[0] === 'string' ? arguments[0] : (arguments[0]?.url || '');
                        const response = await originalFetch.apply(this, arguments);
                        if(url.includes('/rest/') || url.includes('/api/')) {
                           const clone = response.clone();
                           clone.text().then(text => {
                                window.flutter_inappwebview.callHandler('apiSniffer', url + "|||" + text);
                           }).catch(e => {});
                        }
                        return response;
                    };

                    const origOpen = XMLHttpRequest.prototype.open;
                    XMLHttpRequest.prototype.open = function(method, url) {
                        this.addEventListener('load', function() {
                            if(url.includes('/rest/') || url.includes('/api/')) {
                                window.flutter_inappwebview.callHandler('apiSniffer', url + "|||" + this.responseText);
                            }
                        });
                        origOpen.apply(this, arguments);
                    };
                  })();
                """);
              }
            ),
          ),
          
          // MITAD INFERIOR: Terminal de Interceptación
          Expanded(
            flex: 4,
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("🕵️ MODO SNIFFER ACTIVADO", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    const Text("1. Inicia sesión en la parte superior.", style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const Text("2. Ve al menú 'Contador' y pulsa 'Nueva medición'.", style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 16),
                    const Text("URL DETECTADA (Endpoint):", style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold)),
                    SelectableText(_sniffedUrl, style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace')),
                    const SizedBox(height: 12),
                    const Text("PAYLOAD (Datos recibidos):", style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold)),
                    SelectableText(_sniffedData, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}
