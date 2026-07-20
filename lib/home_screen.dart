import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';
import 'login_screen.dart';
import 'trips_view.dart';
import 'hours_view.dart';
import 'attendance_view.dart';
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
  int? _rank;
  int _rankTotal = 0;
  final GlobalKey<TripsViewState> _tripsKey = GlobalKey<TripsViewState>();
  final GlobalKey<AttendanceBarState> _attKey =
      GlobalKey<AttendanceBarState>();

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
      _attKey.currentState?.refresh();
      _loadRank();
    }
  }

  Future<void> _loadRank() async {
    try {
      final r = await Api.getRank(_driverId, _branchId, _jwt);
      if (r != null && mounted) {
        setState(() {
          _rank = r['rank'] is int ? r['rank'] as int : null;
          _rankTotal = r['total'] is int ? r['total'] as int : 0;
        });
      }
    } catch (_) {}
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
    _loadRank();
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

  Widget _rankBadge() {
    final rank = _rank ?? 0;
    final isNext = rank == 1;
    final Color c = isNext
        ? const Color(0xFF16a34a) // أخضر = دورك التالي
        : (rank == 2 ? AppTheme.primary : AppTheme.appBar);
    final String label = isNext
        ? 'دورك الآن #1 — أنت التالي في التوزيع'
        : 'دورك #$rank من $_rankTotal في طابور التوزيع';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Icon(isNext ? Icons.emoji_events : Icons.format_list_numbered,
              color: c, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: c, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(20)),
            child: Text('#$rank',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.appBar,
        foregroundColor: AppTheme.onAppBar,
        title: Text('أهلاً $_name · ${Config.appVersion}',
            style: const TextStyle(fontSize: 14)),
        actions: [
          if (_tab == 0)
            IconButton(
                onPressed: () {
                  _tripsKey.currentState?.load();
                  _attKey.currentState?.refresh();
                  _loadRank();
                },
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
          : Column(
              children: [
                AttendanceBar(
                  key: _attKey,
                  driverId: _driverId,
                  branchId: _branchId,
                  jwt: _jwt,
                ),
                if (_tab == 0 && _rank != null) _rankBadge(),
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      TripsView(
                        key: _tripsKey,
                        driverId: _driverId,
                        branchId: _branchId,
                        jwt: _jwt,
                        driverName: _name,
                      ),
                      HoursView(
                        driverId: _driverId,
                        jwt: _jwt,
                        maxBreak: _maxBreak,
                      ),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: !_ready
          ? null
          : BottomNavigationBar(
              currentIndex: _tab,
              selectedItemColor: AppTheme.primary,
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
