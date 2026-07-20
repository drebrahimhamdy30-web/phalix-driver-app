import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';
import 'login_screen.dart';
import 'main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _name = 'سائق';
  String _driverId = '';
  String _jwt = '';
  bool _loading = true;
  bool _fcmOk = false;
  List<Map<String, dynamic>> _orders = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    // تحديث التوكن لو اتغيّر
    FirebaseMessaging.instance.onTokenRefresh.listen((t) async {
      if (_driverId.isNotEmpty) await Api.saveFcmToken(_driverId, t, _jwt);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // إيقاف الإنذار (صوت + اهتزاز) في الخدمة والواجهة
  void _stopAlarms() {
    FlutterForegroundTask.sendDataToTask('stop_alarm');
    stopAlarmSound();
    cancelAlarm();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // كل مرة يرجع التطبيق للواجهة → أوقف الإنذار
    if (state == AppLifecycleState.resumed) {
      _stopAlarms();
      _loadOrders();
    }
  }

  Future<void> _init() async {
    // إيقاف صوت الإنذار بمجرد فتح التطبيق (الخدمة + الواجهة)
    FlutterForegroundTask.sendDataToTask('stop_alarm');
    await stopAlarmSound();
    await cancelAlarm();
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString('driver_name') ?? 'سائق';
    _driverId = prefs.getString('driver_id') ?? '';
    _jwt = prefs.getString('jwt') ?? '';
    // التأكد إن خدمة الخلفية شغّالة
    if (_driverId.isNotEmpty) await startAlarmService(_driverId);
    // إعادة تسجيل التوكن للتأكيد
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && _driverId.isNotEmpty) {
        _fcmOk = await Api.saveFcmToken(_driverId, token, _jwt);
      }
    } catch (_) {}
    await _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    final orders = await Api.getOrders(_driverId, _jwt);
    if (!mounted) return;
    setState(() { _orders = orders; _loading = false; });
  }

  Future<void> _logout() async {
    await stopAlarmService();
    await FlutterForegroundTask.clearAllData();
    await cancelAlarm();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFf1f5f9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1a56db),
        foregroundColor: Colors.white,
        title: Text('أهلاً $_name · ${Config.appVersion}'),
        actions: [
          IconButton(onPressed: _loadOrders, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _fcmOk ? const Color(0xFFdcfce7) : const Color(0xFFfef9c3),
            padding: const EdgeInsets.all(10),
            child: Text(
              _fcmOk
                  ? '✅ الإشعارات مفعّلة — هتوصلك الطلبات بصوت'
                  : '⏳ جاري تفعيل الإشعارات...',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _orders.isEmpty
                    ? const Center(
                        child: Text('لا توجد طلبات حالياً',
                            style: TextStyle(color: Colors.grey)))
                    : RefreshIndicator(
                        onRefresh: _loadOrders,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _orders.length,
                          itemBuilder: (_, i) => _orderCard(_orders[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('طلب #${o['bill_no'] ?? '-'}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text('${o['total_bill_net'] ?? 0} ج',
                    style: const TextStyle(color: Color(0xFF16a34a), fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            Text('${o['customer_name'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('${o['customer_address'] ?? ''}  •  ${o['cust_region'] ?? ''}',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: _statusColor(o['status'])),
                const SizedBox(width: 6),
                Text(_statusLabel(o['status']),
                    style: TextStyle(color: _statusColor(o['status']), fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'assigned': return const Color(0xFFca8a04);
      case 'picked': return const Color(0xFF0891b2);
      case 'failed': return const Color(0xFFdc2626);
      default: return Colors.grey;
    }
  }

  String _statusLabel(String? s) {
    switch (s) {
      case 'assigned': return 'بانتظار الاستلام';
      case 'picked': return 'في الطريق';
      case 'failed': return 'فشل التسليم';
      default: return s ?? '';
    }
  }
}
