import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'login_screen.dart';
import 'trips_view.dart';
import 'main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _name = 'سائق';
  String _driverId = '';
  String _branchId = '';
  String _jwt = '';
  bool _ready = false;
  final GlobalKey<TripsViewState> _tripsKey = GlobalKey<TripsViewState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _stopAlarms() {
    FlutterForegroundTask.sendDataToTask('stop_alarm');
    stopAlarmSound();
    cancelAlarm();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _stopAlarms();
      _tripsKey.currentState?.load();
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString('driver_name') ?? 'سائق';
    _driverId = prefs.getString('driver_id') ?? '';
    _branchId = prefs.getString('branch_id') ?? '';
    _jwt = prefs.getString('jwt') ?? '';
    if (mounted) setState(() => _ready = true);
    try {
      FlutterForegroundTask.sendDataToTask('stop_alarm');
      await stopAlarmSound();
      await cancelAlarm();
    } catch (_) {}
    try {
      if (_driverId.isNotEmpty) await startAlarmService(_driverId);
    } catch (_) {}
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
        title: Text('أهلاً $_name · ${Config.appVersion}',
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
              onPressed: () => _tripsKey.currentState?.load(),
              icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: const Color(0xFFdcfce7),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: const Text(
                    '✅ جاهز — التنبيهات تعمل بصوت',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
                Expanded(
                  child: TripsView(
                    key: _tripsKey,
                    driverId: _driverId,
                    branchId: _branchId,
                    jwt: _jwt,
                  ),
                ),
              ],
            ),
    );
  }
}
