import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';
import 'login_screen.dart';
import 'trips_view.dart';
import 'hours_view.dart';
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
  int _maxBreak = 15;
  int _tab = 0;
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
    try {
      final mb = await Api.getMaxBreak(_branchId, _jwt);
      if (mounted) setState(() => _maxBreak = mb);
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

  Future<void> _changePassword() async {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final new2C = TextEditingController();
    String? err;
    bool busy = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تغيير كلمة المرور'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: oldC,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'كلمة المرور الحالية',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newC,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: new2C,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور الجديدة',
                    border: OutlineInputBorder()),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(err!,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      final o = oldC.text.trim();
                      final n = newC.text.trim();
                      final n2 = new2C.text.trim();
                      if (o.isEmpty || n.isEmpty) {
                        setD(() => err = 'املأ كل الحقول');
                        return;
                      }
                      if (n != n2) {
                        setD(() => err = 'كلمتا المرور الجديدتان غير متطابقتين');
                        return;
                      }
                      if (n.length < 4) {
                        setD(() => err = 'كلمة المرور قصيرة (4 أحرف على الأقل)');
                        return;
                      }
                      setD(() {
                        busy = true;
                        err = null;
                      });
                      final res =
                          await Api.changePassword(_driverId, o, n, _jwt);
                      if (res['ok'] == true) {
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('✓ تم تغيير كلمة المرور')));
                        }
                      } else {
                        setD(() {
                          busy = false;
                          err = '${res['error'] ?? 'تعذّر التغيير'}';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFf1f5f9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1a56db),
        foregroundColor: Colors.white,
        title: Text('أهلاً $_name · ${Config.appVersion}',
            style: const TextStyle(fontSize: 14)),
        actions: [
          if (_tab == 0)
            IconButton(
                onPressed: () => _tripsKey.currentState?.load(),
                icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pw') _changePassword();
              if (v == 'out') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pw', child: Text('🔑 تغيير كلمة المرور')),
              PopupMenuItem(value: 'out', child: Text('🚪 تسجيل الخروج')),
            ],
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab,
              children: [
                TripsView(
                  key: _tripsKey,
                  driverId: _driverId,
                  branchId: _branchId,
                  jwt: _jwt,
                ),
                HoursView(
                  driverId: _driverId,
                  jwt: _jwt,
                  maxBreak: _maxBreak,
                ),
              ],
            ),
      bottomNavigationBar: !_ready
          ? null
          : BottomNavigationBar(
              currentIndex: _tab,
              selectedItemColor: const Color(0xFF1a56db),
              onTap: (i) => setState(() => _tab = i),
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.local_shipping), label: 'الرحلات'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.access_time), label: 'ساعات العمل'),
              ],
            ),
    );
  }
}
