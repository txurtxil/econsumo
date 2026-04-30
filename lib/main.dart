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
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007A53)), useMaterial3: true),
      home: const MonitorScreen(),
      debugShowCheckedModeBanner: false,
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

  Future<void> _fetchData() async {
    setState(() => _isFetching = true);
    await Future.delayed(const Duration(seconds: 2)); // Simulación latencia i-DE
    setState(() {
      _currentKw = (Random().nextDouble() * 4.5);
      _isFetching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('eConsumo - Tiempo Real'), backgroundColor: const Color(0xFF007A53), foregroundColor: Colors.white),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Potencia Demandada', style: TextStyle(fontSize: 18, color: Colors.grey)),
            Text('${_currentKw.toStringAsFixed(2)} kW', style: const TextStyle(fontSize: 60, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _isFetching ? null : _fetchData,
              icon: _isFetching ? const CircularProgressIndicator() : const Icon(Icons.refresh),
              label: const Text('Consultar Contador'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20)),
            )
          ],
        ),
      ),
    );
  }
}
