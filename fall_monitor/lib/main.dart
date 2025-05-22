import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Constants for health metrics
class HealthMetrics {
  static const int minHeartRate = 60;
  static const int maxHeartRate = 100;
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fall & Heart Monitor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _selectedIndex = 0;
  int _heartRate = 0;
  bool _isFalling = false;
  List<Map<String, dynamic>> _healthEvents = [];
  List<FlSpot> _heartRateData = [];
  List<FlSpot> _pulseWaveData = [];
  Timer? _dataUpdateTimer;

  // Blynk configuration
  final String _blynkToken = 'uZ7KsOfKUp1bYydEEpYuvEOv_VmzObiB';

  // Virtual pins for Blynk
  static const int VIRTUAL_PIN_HEART_RATE = 1;
  static const int VIRTUAL_PIN_FALL_DETECTED = 2;
  static const int VIRTUAL_PIN_PULSE_WAVE = 3;

  Timer? _blynkFetchTimer;

  int _lastPulseRaw = 0;

  @override
  void initState() {
    super.initState();
    _loadHealthEvents();
    _startDataUpdateTimer();
    _blynkFetchTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      _fetchBlynkData();
    });
  }

  void _startDataUpdateTimer() {
    _dataUpdateTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_heartRate > 0) {
        setState(() {
          final now = DateTime.now().millisecondsSinceEpoch / 1000;
          _heartRateData.add(FlSpot(now, _heartRate.toDouble()));
          _pulseWaveData.add(FlSpot(now, _lastPulseRaw.toDouble()));
          // Keep only last 1 minute of data
          final oneMinuteAgo = now - 60;
          _heartRateData.removeWhere((spot) => spot.x < oneMinuteAgo);
          _pulseWaveData.removeWhere((spot) => spot.x < oneMinuteAgo);
        });
      }
    });
  }

  Future<void> _fetchBlynkData() async {
    try {
      final heartRateUrl = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v1';
      final fallUrl = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v2';
      final pulseRawUrl = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v3';

      final heartRateRes = await http.get(Uri.parse(heartRateUrl));
      final fallRes = await http.get(Uri.parse(fallUrl));
      final pulseRawRes = await http.get(Uri.parse(pulseRawUrl));

      if (heartRateRes.statusCode == 200 && 
          fallRes.statusCode == 200 && 
          pulseRawRes.statusCode == 200) {
        final int heartRate = int.tryParse(heartRateRes.body.trim()) ?? 0;
        final bool isFalling = fallRes.body.trim() == '1';
        final int pulseRaw = int.tryParse(pulseRawRes.body.trim()) ?? 0;
        setState(() {
          _heartRate = heartRate;
          _isFalling = isFalling;
          _lastPulseRaw = pulseRaw;
          // Ghi nhận sự kiện ngã
          if (isFalling) {
            _addHealthEvent('Fall Detected');
          }
          // Ghi nhận nhịp tim bất thường
          if (_heartRate < 60 || _heartRate > 100) {
            _addHealthEvent('Abnormal Heart Rate: $_heartRate BPM');
          }
        });
      }
    } catch (e) {
      print('Error fetching Blynk data: $e');
    }
  }

  Future<void> _loadHealthEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final events = prefs.getStringList('health_events') ?? [];
    setState(() {
      _healthEvents = events
          .map((e) => Map<String, dynamic>.from(json.decode(e)))
          .toList();
    });
  }

  Future<void> _addHealthEvent(String event) async {
    final now = DateTime.now();
    final eventData = {
      'timestamp': now.toIso8601String(),
      'event': event,
      'heartRate': _heartRate,
    };

    setState(() {
      _healthEvents.insert(0, eventData);
      if (_healthEvents.length > 100) {
        _healthEvents.removeLast();
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'health_events',
      _healthEvents.map((e) => json.encode(e)).toList(),
    );
  }

  Future<void> _shareHealthData() async {
    if (_healthEvents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No health data to share')),
      );
      return;
    }

    final formatter = DateFormat('yyyy-MM-dd HH:mm:ss');
    final buffer = StringBuffer('Health Monitoring Data\n\n');

    for (var event in _healthEvents) {
      final timestamp = DateTime.parse(event['timestamp']);
      buffer.writeln(
          '${formatter.format(timestamp)} - ${event['event']} (HR: ${event['heartRate']})');
    }

    await Share.share(buffer.toString());
  }

  @override
  void dispose() {
    _blynkFetchTimer?.cancel();
    _dataUpdateTimer?.cancel();
    super.dispose();
  }

  Widget _buildHealthMetricCard(String title, int value, String unit, IconData icon, Color color, {int? minValue, int? maxValue}) {
    bool isAbnormal = false;
    if (minValue != null && maxValue != null) {
      isAbnormal = value < minValue || value > maxValue;
    }
    Color statusColor = isAbnormal ? Colors.red : color;
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isAbnormal ? Colors.red.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: statusColor, size: 40),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 16)),
                Text(
                  '$value $unit',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
                if (isAbnormal)
                  Text(
                    'Cảnh báo!',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPulseWaveChart() {
    double minY = 0;
    double maxY = 4095;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Phổ nhịp tim', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
              child: _pulseWaveData.isEmpty
                  ? Center(child: Text('Chưa có dữ liệu', style: TextStyle(color: Colors.grey[600], fontSize: 14)))
                  : LineChart(
                      LineChartData(
                        gridData: const FlGridData(show: true),
                        titlesData: FlTitlesData(
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 40,
                              getTitlesWidget: (value, meta) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: Text(value.toInt().toString(), style: const TextStyle(fontSize: 10)),
                                );
                              },
                            ),
                          ),
                          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        ),
                        borderData: FlBorderData(show: true),
                        minY: minY,
                        maxY: maxY,
                        lineBarsData: [
                          LineChartBarData(
                            spots: _pulseWaveData.where((spot) => spot.y.isFinite && !spot.y.isNaN).toList(),
                            isCurved: false,
                            color: Colors.purple,
                            barWidth: 2,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(show: false),
                          ),
                        ],
                        lineTouchData: LineTouchData(
                          enabled: true,
                          touchTooltipData: LineTouchTooltipData(
                            tooltipBgColor: Colors.blueGrey.withOpacity(0.8),
                            getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
                              return touchedBarSpots.map((barSpot) {
                                final date = DateTime.fromMillisecondsSinceEpoch((barSpot.x * 1000).toInt());
                                final dateStr =
                                    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
                                final timeStr =
                                    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
                                return LineTooltipItem(
                                  'raw input: ${barSpot.y.toInt()}'
                                  '\n$dateStr\n$timeStr',
                                  const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              }).toList();
                            },
                          ),
                          handleBuiltInTouches: true,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataTab() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Fall detection card
            Card(
              color: _isFalling ? Colors.red.shade100 : Colors.green.shade100,
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 8),
                child: Column(
                  children: [
                    Icon(
                      Icons.warning,
                      color: _isFalling ? Colors.red : Colors.green,
                      size: 48,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isFalling ? 'CẢNH BÁO NGÃ!' : 'An toàn',
                      style: TextStyle(
                        color: _isFalling ? Colors.red : Colors.green,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Health metrics card: Heart Rate only
            _buildHealthMetricCard(
              'Nhịp tim',
              _heartRate,
              'BPM',
              Icons.favorite,
              Colors.red,
              minValue: 60,
              maxValue: 100,
            ),
            const SizedBox(height: 20),
            // Pulse waveform chart
            _buildPulseWaveChart(),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Lịch sử sự kiện',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: _healthEvents.isEmpty
                  ? const Center(child: Text('Chưa có sự kiện nào.'))
                  : ListView.builder(
                      itemCount: _healthEvents.length,
                      itemBuilder: (context, index) {
                        final event = _healthEvents[index];
                        final timestamp = DateTime.parse(event['timestamp']);
                        return ListTile(
                          leading: Icon(
                            event['event'].contains('Fall')
                                ? Icons.warning
                                : Icons.favorite,
                            color: event['event'].contains('Abnormal')
                                ? Colors.red
                                : Colors.blue,
                          ),
                          title: Text(
                            event['event'],
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fall & Health Monitor'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareHealthData,
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildDataTab(),
          _buildHistoryTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Dữ liệu',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Lịch sử phát hiện',
          ),
        ],
      ),
    );
  }
}
