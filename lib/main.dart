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
      title: 'eConsumo Control',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1DB954)), // Color Octopus/Energia
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
      ),
      home: const MainDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});
  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  InAppWebViewController? _webViewController;
  bool _isLogged = false;
  
  // Datos de tu contrato (Extraidos de tu factura)
  final double potPunta = 4.4; 
  final double potValle = 3.6;
  final double precioPotenciaAnual = 30.0; // Media aprox. de peajes + margen
  final double comisionOctopusMensual = 6.0; // Gestion Octopus Flexi aprox.

  // Variables de estado
  double _kwhMes = 0.0;
  double _estimacionEuros = 0.0;
  double _instantKw = 0.0;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi Control de Suministros', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (_isLogged) IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshAll)
        ],
      ),
      body: Stack(
        children: [
          // Navegador Invisible para i-DE
          Offstage(
            offstage: _isLogged,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.i-de.es/consumidores/web/login')),
              onLoadStop: (controller, url) {
                if (url?.path.contains('dashboard') == true || url?.path.contains('inicio') == true) {
                  setState(() => _isLogged = true);
                  _refreshAll();
                }
              },
              onWebViewCreated: (c) => _webViewController = c,
            ),
          ),

          if (_isLogged)
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  _buildMainStats(),
                  const SizedBox(height: 20),
                  const Text("DESGLOSE ESTIMADO (OCTOPUS FLEXI)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                  const SizedBox(height: 10),
                  _buildCostDetail(),
                  const SizedBox(height: 20),
                  _buildInstantCard(),
                  const SizedBox(height: 40),
                  _buildFutureModules(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF007A53), Color(0xFF1DB954)]),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Gasto Acumulado Abril", style: TextStyle(color: Colors.white70, fontSize: 14)),
              Text("${_estimacionEuros.toStringAsFixed(2)} €", style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
            ],
          ),
          const Icon(Icons.account_balance_wallet, color: Colors.white, size: 40),
        ],
      ),
    );
  }

  Widget _buildMainStats() {
    return Row(
      children: [
        Expanded(child: _miniCard("Energia", "${_kwhMes.toStringAsFixed(1)} kWh", Icons.bolt, Colors.orange)),
        const SizedBox(width: 10),
        Expanded(child: _miniCard("Dias", "${DateTime.now().day} / 30", Icons.today, Colors.blue)),
      ],
    );
  }

  Widget _miniCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 5),
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildCostDetail() {
    double costeEnergia = _kwhMes * 0.15; // Estimacion media Octopus Flexi
    double costePotencia = ((potPunta * 0.08) + (potValle * 0.01)) * DateTime.now().day;
    
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          _rowCost("Consumo energia (Variable)", "${costeEnergia.toStringAsFixed(2)} €"),
          const Divider(),
          _rowCost("Termino Potencia (Fijo)", "${costePotencia.toStringAsFixed(2)} €"),
          const Divider(),
          _rowCost("Cuota Octopus + Impuestos", "${(comisionOctopusMensual + 5).toStringAsFixed(2)} €"),
        ],
      ),
    );
  }

  Widget _rowCost(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildInstantCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          const Text("LECTURA INSTANTÁNEA PLC", style: TextStyle(color: Colors.greenAccent, fontSize: 10, letterSpacing: 2)),
          const SizedBox(height: 10),
          Text("${_instantKw.toStringAsFixed(3)} kW", style: const TextStyle(color: Colors.white, fontSize: 40, fontFamily: 'monospace')),
          const SizedBox(height: 15),
          ElevatedButton(
            onPressed: _fetchInstant,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black),
            child: const Text("SINCRONIZAR CONTADOR"),
          )
        ],
      ),
    );
  }

  Widget _buildFutureModules() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("PRÓXIMOS MÓDULOS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
        const SizedBox(height: 10),
        Row(
          children: [
            _futureIcon(Icons.directions_car, "EV Car"),
            _futureIcon(Icons.water_drop, "Agua"),
            _futureIcon(Icons.wifi, "Internet"),
            _futureIcon(Icons.tv, "Netflix"),
          ],
        ),
      ],
    );
  }

  Widget _futureIcon(IconData icon, String label) {
    return Expanded(
      child: Opacity(
        opacity: 0.3,
        child: Column(
          children: [
            Icon(icon, size: 30),
            Text(label, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }

  // --- LOGICA DE DATOS ---

  Future<void> _refreshAll() async {
    _fetchMonthly();
  }

  Future<void> _fetchMonthly() async {
    DateTime now = DateTime.now();
    String start = "01-${now.month.toString().padLeft(2, '0')}-${now.year}";
    String today = "${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')}-${now.year}";
    
    var result = await _webViewController?.callAsyncJavaScript(functionBody: """
      let resp = await fetch('https://www.i-de.es/consumidores/rest/consumoNew/obtenerDatosConsumoDH/$start/$today/dias/USU/');
      return await resp.text();
    """);
    
    if (result?.value != null) {
      final List data = jsonDecode(result!.value.toString());
      setState(() {
        _kwhMes = double.parse(data[0]['total'].toString()) / 1000.0;
        // Calculo aproximado: 0.15€/kWh + costes fijos diarios
        _estimacionEuros = (_kwhMes * 0.15) + (((potPunta*0.08)+(potValle*0.01)) * now.day) + 10;
      });
    }
  }

  Future<void> _fetchInstant() async {
    setState(() => _loading = true);
    await _webViewController?.evaluateJavascript(source: "fetch('https://www.i-de.es/consumidores/rest/escenarioNew/validarComunicacionContador/')");
    await _webViewController?.evaluateJavascript(source: "fetch('https://www.i-de.es/consumidores/rest/escenarioNew/nuevoEscenario/')");
    await Future.delayed(const Duration(seconds: 4));
    var result = await _webViewController?.callAsyncJavaScript(functionBody: "let r = await fetch('https://www.i-de.es/consumidores/rest/escenarioNew/obtenerMedicionOnline/24'); return await r.text();");
    if (result?.value != null) {
      final data = jsonDecode(result!.value.toString());
      setState(() {
        _instantKw = double.parse(data['valMagnitud'].toString()) / 1000.0;
      });
    }
    setState(() => _loading = false);
  }
}
