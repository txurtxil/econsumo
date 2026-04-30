import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:convert';
import 'dart:async';

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
      home: const BootScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BootScreen extends StatefulWidget {
  const BootScreen({super.key});
  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final cookies = prefs.getString('ide_cookies');
    if (cookies != null && cookies.isNotEmpty && mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
    } else if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AuthScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFF007A53))));
  }
}

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.bolt, size: 80, color: Color(0xFF007A53)),
              const SizedBox(height: 16),
              const Text('eConsumo', textAlign: TextAlign.center, style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF007A53))),
              const SizedBox(height: 16),
              const Text('Usando navegador seguro para evitar bloqueos.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 48),
              ElevatedButton.icon(
                onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const WebViewLoginScreen())),
                icon: const Icon(Icons.public),
                label: const Text('Abrir Portal i-DE', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WebViewLoginScreen extends StatefulWidget {
  const WebViewLoginScreen({super.key});
  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  bool _isLoading = true;
  InAppWebViewController? _webViewController;
  final CookieManager _cookieManager = CookieManager.instance();

  Future<void> _extractAndSaveCookies(WebUri? url) async {
    try {
      if (url == null) return;
      List<Cookie> cookies = await _cookieManager.getCookies(url: url);
      if (cookies.isNotEmpty) {
        String cookieHeader = cookies.map((c) => '${c.name}=${c.value}').join('; ');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ide_cookies', cookieHeader);
        
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aún no hay sesión activa. Inicia sesión primero.')));
      }
    } catch (e) {
      debugPrint('Error extrayendo cookies: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login i-DE', style: TextStyle(fontSize: 16)), 
        backgroundColor: const Color(0xFF007A53), 
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            onPressed: () async {
              if (_webViewController != null) {
                WebUri? currentUrl = await _webViewController!.getUrl();
                await _extractAndSaveCookies(currentUrl);
              }
            },
            icon: const Icon(Icons.check_circle, color: Colors.white),
            label: const Text('¡Ya estoy dentro!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
            initialSettings: InAppWebViewSettings(
              userAgent: 'Mozilla/5.0 (Linux; Android 13; SM-S901B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
              javaScriptEnabled: true,
              domStorageEnabled: true,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
            },
            onLoadStop: (controller, url) async {
              if (mounted) setState(() => _isLoading = false);
              // Auto-detección mejorada para diferentes URLs de i-DE
              if (url != null && (url.path.contains('inicio') || url.path.contains('medicion') || url.path.contains('dashboard'))) {
                await _extractAndSaveCookies(url);
              }
            },
            onUpdateVisitedHistory: (controller, url, androidIsReload) async {
              // Interceptar cambios de URL en SPA
              if (url != null && (url.path.contains('inicio') || url.path.contains('medicion') || url.path.contains('dashboard'))) {
                 await _extractAndSaveCookies(url);
              }
            },
          ),
          if (_isLoading) const Center(child: CircularProgressIndicator(color: Color(0xFF007A53))),
        ],
      ),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});
  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  double _currentKw = 0.0;
  bool _isFetching = false;
  String _lastUpdate = "Esperando lectura...";
  String _statusMessage = "¡Sesión capturada! Listo para leer.";

  Future<void> _fetchData() async {
    setState(() { _isFetching = true; _statusMessage = "Conectando al contador..."; });
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final cookies = prefs.getString('ide_cookies') ?? '';

      final response = await http.get(
        Uri.parse('https://www.i-de.es/consumidores/rest/medicion/reloj/0'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-S901B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
          'Accept': 'application/json, text/plain, */*',
          'Cookie': cookies,
        }
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data != null && data['valMagnitud'] != null) {
          setState(() {
            _currentKw = double.parse(data['valMagnitud'].toString()) / 1000.0;
            final now = DateTime.now();
            _lastUpdate = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
            _statusMessage = "Lectura exitosa.";
          });
        } else {
           setState(() => _statusMessage = "Respuesta del contador vacía o formato desconocido.\n${response.body}");
        }
      } else {
        setState(() => _statusMessage = "Error HTTP ${response.statusCode}. La sesión expiró o fue rechazada.");
        if (response.statusCode == 401 || response.statusCode == 403) {
            await prefs.remove('ide_cookies'); 
        }
      }
    } catch (e) {
      setState(() => _statusMessage = "Error de red: $e");
    } finally {
      setState(() => _isFetching = false);
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await CookieManager.instance().deleteAllCookies();
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monitor Tiempo Real'), backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white, actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _logout)]),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Potencia Demandada', style: TextStyle(fontSize: 18, color: Colors.grey)),
              Text('${_currentKw.toStringAsFixed(2)} kW', style: const TextStyle(fontSize: 60, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text('Última actualización: $_lastUpdate', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _statusMessage.contains('Error') || _statusMessage.contains('vacía') ? Colors.red.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_statusMessage, style: TextStyle(color: _statusMessage.contains('Error') || _statusMessage.contains('vacía') ? Colors.red : Colors.green.shade800, fontSize: 13), textAlign: TextAlign.center),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isFetching ? null : _fetchData,
                  icon: _isFetching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.speed),
                  label: Text(_isFetching ? 'Leyendo PLC...' : 'Solicitar Lectura al Contador'),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 20), textStyle: const TextStyle(fontSize: 18)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
