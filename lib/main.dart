import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';

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

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('ide_token') != null && mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
    }
  }

  Future<void> _login() async {
    if (_userController.text.isEmpty || _passwordController.text.isEmpty) return;
    
    setState(() => _isLoading = true);
    
    // TODO: Implementar petición POST real al endpoint de autenticación de i-DE
    // Aquí es donde haríamos la ingeniería inversa de su API.
    // Por ahora, guardamos las credenciales y pasamos al dashboard.
    await Future.delayed(const Duration(seconds: 2)); // Simula red
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ide_token', 'token_temporal_simulado');
    await prefs.setString('ide_user', _userController.text);

    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MonitorScreen()));
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
              const Text('Conexión API i-DE (Iberdrola)', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 48),
              TextField(
                controller: _userController,
                decoration: const InputDecoration(labelText: 'DNI / Email (i-DE)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _isLoading ? null : _login,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _isLoading 
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                  : const Text('Vincular Contador', style: TextStyle(fontSize: 18)),
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
  String _lastUpdate = "Sin datos";

  Future<void> _fetchData() async {
    setState(() => _isFetching = true);
    
    // TODO: Implementar petición GET real al endpoint de lectura instantánea de i-DE
    // enviando el 'ide_token' en los headers.
    await Future.delayed(const Duration(seconds: 3)); // Simulación de los 10-15s que tarda el PLC real
    
    setState(() {
      _currentKw = double.parse((Random().nextDouble() * 4.5).toStringAsFixed(2));
      final now = DateTime.now();
      _lastUpdate = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      _isFetching = false;
    });
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AuthScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor Tiempo Real'), 
        backgroundColor: const Color(0xFF007A53), 
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _logout)],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Potencia Demandada', style: TextStyle(fontSize: 18, color: Colors.grey)),
            Text('${_currentKw.toStringAsFixed(2)} kW', style: const TextStyle(fontSize: 60, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Última lectura: $_lastUpdate', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _isFetching ? null : _fetchData,
              icon: _isFetching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.speed),
              label: Text(_isFetching ? 'Leyendo PLC...' : 'Solicitar Lectura'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20)),
            )
          ],
        ),
      ),
    );
  }
}
