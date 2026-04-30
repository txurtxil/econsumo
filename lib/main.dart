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
  List<String> _logs = ["Esperando intercepcion de red..."];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sniffer Avanzado - i-DE', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF007A53),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // NAVEGADOR
          Expanded(
            flex: 5,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
              initialSettings: InAppWebViewSettings(
                userAgent: 'Mozilla/5.0 (Linux; Android 13; SM-S901B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
                javaScriptEnabled: true,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                controller.addJavaScriptHandler(handlerName: 'apiSniffer', callback: (args) {
                  String payload = args[0].toString();
                  List<String> parts = payload.split('|||');
                  if(parts.length == 2) {
                    String url = parts[0];
                    String json = parts[1];
                    
                    if(url.contains('/rest/') || url.contains('/api/')) {
                       setState(() {
                         // Evitamos saturar la pantalla con los latidos de sesion
                         if (url.contains('mantenerSesion')) return; 
                         
                         String entry = "URL: $url\nDATOS: ${json.length > 200 ? json.substring(0, 200) + '...' : json}\n-------------------------";
                         if (_logs[0] == "Esperando intercepcion de red...") {
                            _logs.clear();
                         }
                         _logs.insert(0, entry);
                         if (_logs.length > 15) _logs.removeLast();
                       });
                    }
                  }
                });
              },
              onLoadStop: (controller, url) async {
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
          
          // TERMINAL LOG
          Expanded(
            flex: 5,
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: SelectableText(
                      _logs[index], 
                      style: TextStyle(
                        color: _logs[index].contains('URL:') ? Colors.greenAccent : Colors.white70, 
                        fontSize: 11, 
                        fontFamily: 'monospace'
                      )
                    ),
                  );
                },
              ),
            ),
          )
        ],
      ),
    );
  }
}
