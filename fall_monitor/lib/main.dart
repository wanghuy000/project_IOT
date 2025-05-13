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
  static const int minSpO2 = 95;
  static const int maxSpO2 = 100;
  static const int minGlucose = 70;
  static const int maxGlucose = 140;
  static const int warningGlucoseLow = 90;  // Cảnh báo khi glucose dưới 90
  static const int warningGlucoseHigh = 130; // Cảnh báo khi glucose trên 130
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
  int _spO2 = 0;
  int _glucose = 0;
  bool _isFalling = false;
  List<Map<String, dynamic>> _healthEvents = [];
  List<FlSpot> _heartRateData = [];
  List<FlSpot> _spO2Data = [];
  List<FlSpot> _glucoseData = [];
  Timer? _dataUpdateTimer;

  // Blynk configuration
  final String _blynkToken = 'mAiaSX1z3qwSc8_3vmXUGyiX-RI9ClWq';

  // Virtual pins for Blynk
  static const int VIRTUAL_PIN_HEART_RATE = 1;
  static const int VIRTUAL_PIN_FALL_DETECTED = 2;
  static const int VIRTUAL_PIN_SPO2 = 3;

  Timer? _blynkFetchTimer;

  // Calculate glucose level based on heart rate and SpO2
  int _calculateGlucose(int heartRate, int spo2) {
    // Giới hạn giá trị đầu vào để đảm bảo an toàn
    heartRate = heartRate.clamp(60, 100);
    spo2 = spo2.clamp(95, 100);
    
    // Áp dụng công thức mới:
    // 16714.61 + 0.47 * bpm - 351.045 * spo2 + 1.85 * (spo2 * spo2)
    double glucose = 16714.61 + 0.47 * heartRate - 351.045 * spo2 + 1.85 * (spo2 * spo2);
    
    // Giới hạn kết quả trong khoảng hợp lý (70-140 mg/dL)
    return glucose.clamp(70.0, 140.0).round();
  }

  @override
  void initState() {
    super.initState();
    _loadHealthEvents();
    _startDataUpdateTimer();
    _blynkFetchTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _fetchBlynkData();
    });
  }

  void _startDataUpdateTimer() {
    _dataUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_heartRate > 0) {
        setState(() {
          final now = DateTime.now().millisecondsSinceEpoch / 1000;
          _heartRateData.add(FlSpot(now, _heartRate.toDouble()));
          _spO2Data.add(FlSpot(now, _spO2.toDouble()));
          _glucoseData.add(FlSpot(now, _glucose.toDouble()));

          // Keep only last 5 minutes of data
          final fiveMinutesAgo = now - 300;
          _heartRateData.removeWhere((spot) => spot.x < fiveMinutesAgo);
          _spO2Data.removeWhere((spot) => spot.x < fiveMinutesAgo);
          _glucoseData.removeWhere((spot) => spot.x < fiveMinutesAgo);
        });
      }
    });
  }

  Future<void> _fetchBlynkData() async {
    try {
      final heartRateUrl = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v1';
      final fallUrl = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v2';
      final spo2Url = 'https://blynk.cloud/external/api/get?token=$_blynkToken&v3';

      final heartRateRes = await http.get(Uri.parse(heartRateUrl));
      final fallRes = await http.get(Uri.parse(fallUrl));
      final spo2Res = await http.get(Uri.parse(spo2Url));

      if (heartRateRes.statusCode == 200 && 
          fallRes.statusCode == 200 && 
          spo2Res.statusCode == 200) {
        
        final int heartRate = int.tryParse(heartRateRes.body.trim()) ?? 0;
        final bool isFalling = fallRes.body.trim() == '1';
        final int spo2 = int.tryParse(spo2Res.body.trim()) ?? 0;
        
        // Calculate glucose level
        final int glucose = _calculateGlucose(heartRate, spo2);

        setState(() {
          _heartRate = heartRate;
          _spO2 = spo2;
          _glucose = glucose;
          
          if (_isFalling != isFalling) {
            _isFalling = isFalling;
            if (_isFalling) {
              _addHealthEvent('Fall Detected');
            }
          }

          // Check for health alerts
          _checkHealthAlerts();
        });
      }
    } catch (e) {
      print('Error fetching Blynk data: $e');
    }
  }

  void _checkHealthAlerts() {
    if (_heartRate < HealthMetrics.minHeartRate || _heartRate > HealthMetrics.maxHeartRate) {
      _addHealthEvent('Abnormal Heart Rate: $_heartRate BPM');
    }
    if (_spO2 < HealthMetrics.minSpO2) {
      _addHealthEvent('Low SpO2: $_spO2%');
    }
    if (_glucose < HealthMetrics.warningGlucoseLow || _glucose > HealthMetrics.warningGlucoseHigh) {
      String status = _glucose < HealthMetrics.warningGlucoseLow ? 'Low' : 'High';
      _addHealthEvent('Warning: $status Glucose Level: $_glucose mg/dL');
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

  Widget _buildHealthMetricCard(String title, int value, String unit, IconData icon, Color color, 
      {int? minValue, int? maxValue, int? warningLow, int? warningHigh}) {
    bool isAbnormal = false;
    bool isWarning = false;
    
    if (minValue != null && maxValue != null) {
      isAbnormal = value < minValue || value > maxValue;
      if (warningLow != null && warningHigh != null) {
        isWarning = (value < warningLow || value > warningHigh) && !isAbnormal;
      }
    }

    Color statusColor = isAbnormal ? Colors.red : (isWarning ? Colors.orange : color);

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isAbnormal ? Colors.red.shade50 : (isWarning ? Colors.orange.shade50 : null),
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
                if (isWarning || isAbnormal)
                  Text(
                    isAbnormal ? 'Cảnh báo!' : 'Chú ý!',
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

  Widget _buildChart(String title, List<FlSpot> data, Color color, {double? minY, double? maxY}) {
    // Tính toán phạm vi hiển thị dựa trên dữ liệu
    double actualMinY = minY ?? 0;
    double actualMaxY = maxY ?? 100;
    
    if (data.isNotEmpty) {
      // Lọc bỏ các giá trị không hợp lệ
      var validData = data.where((spot) => spot.y.isFinite && !spot.y.isNaN).toList();
      
      if (validData.isNotEmpty) {
        // Tìm giá trị min và max thực tế
        actualMinY = validData.map((spot) => spot.y).reduce((a, b) => a < b ? a : b);
        actualMaxY = validData.map((spot) => spot.y).reduce((a, b) => a > b ? a : b);
        
        // Thêm padding 10% cho min và max
        double range = actualMaxY - actualMinY;
        actualMinY = (actualMinY - range * 0.1).clamp(minY ?? 0, maxY ?? double.infinity);
        actualMaxY = (actualMaxY + range * 0.1).clamp(minY ?? 0, maxY ?? double.infinity);
        
        // Đảm bảo khoảng cách tối thiểu giữa min và max
        if (actualMaxY - actualMinY < 10) {
          double mid = (actualMaxY + actualMinY) / 2;
          actualMinY = (mid - 5).clamp(minY ?? 0, maxY ?? double.infinity);
          actualMaxY = (mid + 5).clamp(minY ?? 0, maxY ?? double.infinity);
        }
      }
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
              child: data.isEmpty
                  ? Center(
                      child: Text(
                        'Chưa có dữ liệu',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 14,
                        ),
                      ),
                    )
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
                                  child: Text(
                                    value.toInt().toString(),
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                );
                              },
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                        ),
                        borderData: FlBorderData(show: true),
                        minY: actualMinY,
                        maxY: actualMaxY,
                        lineBarsData: [
                          LineChartBarData(
                            spots: data.where((spot) => 
                              spot.y.isFinite && !spot.y.isNaN &&
                              spot.y >= (minY ?? 0) && spot.y <= (maxY ?? double.infinity)
                            ).toList(),
                            isCurved: true,
                            color: color,
                            barWidth: 3,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: color.withOpacity(0.1),
                            ),
                          ),
                        ],
                        lineTouchData: LineTouchData(
                          touchTooltipData: LineTouchTooltipData(
                            tooltipBgColor: Colors.blueGrey.withOpacity(0.8),
                            getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
                              return touchedBarSpots.map((barSpot) {
                                final date = DateTime.fromMillisecondsSinceEpoch((barSpot.x * 1000).toInt());
                                return LineTooltipItem(
                                  '${barSpot.y.toInt()}\n${DateFormat('HH:mm:ss').format(date)}',
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
                          touchCallback: (FlTouchEvent event, LineTouchResponse? response) {
                            // Handle touch events if needed
                          },
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
            
            // Health metrics cards
            _buildHealthMetricCard(
              'Nhịp tim',
              _heartRate,
              'BPM',
              Icons.favorite,
              Colors.red,
              minValue: HealthMetrics.minHeartRate,
              maxValue: HealthMetrics.maxHeartRate,
            ),
            const SizedBox(height: 12),
            _buildHealthMetricCard(
              'SpO2',
              _spO2,
              '%',
              Icons.bloodtype,
              Colors.blue,
              minValue: HealthMetrics.minSpO2,
              maxValue: HealthMetrics.maxSpO2,
            ),
            const SizedBox(height: 12),
            _buildHealthMetricCard(
              'Glucose',
              _glucose,
              'mg/dL',
              Icons.water_drop,
              Colors.purple,
              minValue: HealthMetrics.minGlucose,
              maxValue: HealthMetrics.maxGlucose,
              warningLow: HealthMetrics.warningGlucoseLow,
              warningHigh: HealthMetrics.warningGlucoseHigh,
            ),
            const SizedBox(height: 20),

            // Charts
            _buildChart('Biểu đồ nhịp tim', _heartRateData, Colors.red,
                minY: HealthMetrics.minHeartRate.toDouble(),
                maxY: HealthMetrics.maxHeartRate.toDouble()),
            const SizedBox(height: 12),
            _buildChart('Biểu đồ SpO2', _spO2Data, Colors.blue,
                minY: HealthMetrics.minSpO2.toDouble(),
                maxY: HealthMetrics.maxSpO2.toDouble()),
            const SizedBox(height: 12),
            _buildChart('Biểu đồ Glucose', _glucoseData, Colors.purple,
                minY: HealthMetrics.minGlucose.toDouble(),
                maxY: HealthMetrics.maxGlucose.toDouble()),
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
                                : event['event'].contains('Heart')
                                    ? Icons.favorite
                                    : event['event'].contains('SpO2')
                                        ? Icons.bloodtype
                                        : Icons.water_drop,
                            color: event['event'].contains('Abnormal') || event['event'].contains('Low')
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
