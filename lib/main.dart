import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';

void main() => runApp(const EConsumoApp());

class EConsumoApp extends StatelessWidget {
  const EConsumoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eConsumo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007A53)), 
        useMaterial3: true
      ),
      home: const AuthScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- SERVICIO DE API i-DE ---
class IDEApiService {
  static const String baseUrl = 'https://www.i-de.es/consumidores/rest';
  static String cookies = '';

  static Map<String, String> get _headers => {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Content-Type': 'application/json',
    'Cookie': cookies,
  };

  static void _updateCookies(http.Response response) {
    String? rawCookie = response.headers['set-cookie'];
    if (rawCookie != null) {
      cookies = rawCookie.split(';')[0]; // Guardamos la cookie de sesión JSESSIONID
    }
  }

  static Future<bool> login(String document, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/login'),
        headers: _headers,
        body: jsonEncode([document, password]),
      );
      
      _updateCookies(response);
      
      if (response.statusCode == 200 && response.body.contains('true')) {
        return true;
      }
      return false;
    } catch (e) {
      throw Exception('Error de conexión al hacer login: $e');
    }
  }

  static Future<double> getInstantConsumption() async {
    try {
      // 1. Petición para despertar el contador y pedir lectura instantánea
      final response = await http.get(
        Uri.parse('$baseUrl/medicion/reloj/0'),
        headers: _headers,
      );
      
      if (response.statusCode != 200) {
        throw Exception('Error del servidor i-DE: HTTP ${response.statusCode}');
      }

      // 2. Analizar el JSON devuelto
      final data = jsonDecode(response.body);
      
      // La API de i-DE suele devolver la potencia en vatios o kW bajo el campo 'valMagnitud' o similar.
      // Dependiendo de la versión de la API, la estructura varía. 
      if (data != null && data['valMagnitud'] != null) {
        // Asumiendo que devuelve W, convertimos a kW
        return double.parse(data['valMagnitud'].toString()) / 1000.0;
      } else {
         throw Exception('Estructura JSON no esperada o contador no accesible.');
      }
    } catch (e) {
      throw Exception('$e');
    }
  }
}

// --- PANTALLAS ---

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('ide_user') != null && mounted) {
      // Si ya hay usuario, idealmente haríamos login silencioso en background
      // Para este prototipo, saltamos al dashboard
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
    }
  }

  Future<void> _login() async {
    if (_userController.text.isEmpty || _passwordController.text.isEmpty) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    
    try {
      bool success = await IDEApiService.login(_userController.text, _passwordController.text);
      
      if (success) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ide_user', _userController.text);

        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
        }
      } else {
        setState(() => _errorMessage = 'Credenciales incorrectas o bloqueo de i-DE.');
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

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
              const SizedBox(height: 48),
              TextField(
                controller: _userController,
                decoration: const InputDecoration(labelText: 'DNI Titular', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Contraseña i-DE', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)),
              ),
              if (_errorMessage.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(_errorMessage, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _isLoading ? null : _login,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _isLoading 
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                  : const Text('Iniciar Sesión en i-DE', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
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
  String _statusMessage = "";

  Future<void> _fetchData() async {
    setState(() {
      _isFetching = true;
      _statusMessage = "Conectando con el contador...";
    });
    
    try {
      double kw = await IDEApiService.getInstantConsumption();
      setState(() {
        _currentKw = kw;
        final now = DateTime.now();
        _lastUpdate = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
        _statusMessage = "Lectura exitosa.";
      });
    } catch (e) {
      setState(() => _statusMessage = "Error: $e");
    } finally {
      setState(() => _isFetching = false);
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    IDEApiService.cookies = ''; // Limpiamos sesión
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AuthScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medidor i-DE Real'), 
        backgroundColor: const Color(0xFF007A53), 
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _logout)],
      ),
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
              Text(_statusMessage, style: TextStyle(color: _statusMessage.startsWith('Error') ? Colors.red : Colors.green), textAlign: TextAlign.center),
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
