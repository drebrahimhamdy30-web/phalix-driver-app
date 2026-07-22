import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_update/ota_update.dart';
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
  final GlobalKey<TripsViewState> _tripsKey = GlobalKey<TripsViewState>();
  final GlobalKey<TripsViewState> _prevKey = GlobalKey<TripsViewState>();
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
      _prevKey.currentState?.load();
      _attKey.currentState?.refresh();
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
    _checkUpdate();
  }

  // فحص آخر نسخة وعرض رسالة تحديث لو فيه أحدث
  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _checkUpdate({bool manual = false}) async {
    try {
      final v = await Api.getLatestVersion();
      if (v == null || !mounted) {
        if (manual) _snack('تعذّر التحقق من التحديثات، حاول تاني');
        return;
      }
      final latest = v['version_code'] is int
          ? v['version_code'] as int
          : int.tryParse('${v['version_code']}') ?? 0;
      final apkUrl = '${v['apk_url'] ?? ''}';
      if (latest <= Config.appBuild || apkUrl.isEmpty) {
        if (manual) _snack('أنت على أحدث نسخة (v${Config.appBuild}) ✅');
        return;
      }
      _showUpdateDialog(apkUrl, v['force_update'] == true, '${v['notes'] ?? ''}');
    } catch (_) {
      if (manual) _snack('تعذّر التحقق من التحديثات');
    }
  }

  void _showUpdateDialog(String apkUrl, bool force, String notes) {
    showDialog(
      context: context,
      barrierDismissible: !force,
      builder: (ctx) => PopScope(
        canPop: !force,
        child: AlertDialog(
          title: const Text('🔄 تحديث متاح'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('فيه نسخة أحدث من التطبيق. برجاء التحديث لآخر نسخة.'),
              if (notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(notes,
                      style:
                          const TextStyle(fontSize: 13, color: Colors.grey)),
                ),
            ],
          ),
          actions: [
            if (!force)
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('لاحقاً')),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => UpdateProgressDialog(apkUrl: apkUrl));
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white),
              child: const Text('تحديث الآن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    // الأهم: مسح بيانات الدخول أولاً (حتى لو فشل تنظيف الخدمات)
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    // تنظيف الخدمات best-effort — لا يمنع الخروج لو رمى خطأ أو تأخّر
    try {
      await stopAlarmService().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await FlutterForegroundTask.clearAllData().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await cancelAlarm().timeout(const Duration(seconds: 3));
    } catch (_) {}
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

  void _refreshCurrent() {
    _tripsKey.currentState?.load();
    _prevKey.currentState?.load();
    _attKey.currentState?.refresh();
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
          if (_tab != 2)
            IconButton(
                onPressed: _refreshCurrent, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'upd') _checkUpdate(manual: true);
              if (v == 'pw') _changePassword();
              if (v == 'out') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'upd', child: Text('🔄 التحقق من التحديثات')),
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
                        mode: 'active',
                      ),
                      TripsView(
                        key: _prevKey,
                        driverId: _driverId,
                        branchId: _branchId,
                        jwt: _jwt,
                        driverName: _name,
                        mode: 'previous',
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
              type: BottomNavigationBarType.fixed,
              selectedItemColor: AppTheme.primary,
              onTap: (i) => setState(() => _tab = i),
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.local_shipping), label: 'الرحلات الجارية'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.history), label: 'الرحلات السابقة'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.access_time), label: 'ساعات العمل'),
              ],
            ),
    );
  }
}

// نافذة تقدّم التنزيل والتثبيت
class UpdateProgressDialog extends StatefulWidget {
  final String apkUrl;
  const UpdateProgressDialog({super.key, required this.apkUrl});
  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog> {
  String _status = 'جاري التنزيل...';
  int _pct = 0;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    try {
      OtaUpdate()
          .execute(widget.apkUrl, destinationFilename: 'phalix-driver.apk')
          .listen((e) {
        if (!mounted) return;
        if (e.status == OtaStatus.DOWNLOADING) {
          setState(() => _pct = int.tryParse(e.value ?? '0') ?? _pct);
        } else if (e.status == OtaStatus.INSTALLING) {
          setState(() => _status = 'جاري التثبيت...');
        } else {
          setState(() {
            _error = true;
            _status = 'تعذّر التحديث تلقائيًا — حمّل النسخة يدويًا';
          });
        }
      });
    } catch (_) {
      setState(() {
        _error = true;
        _status = 'تعذّر التحديث';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تحديث التطبيق'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_error)
            LinearProgressIndicator(value: _pct > 0 ? _pct / 100 : null),
          const SizedBox(height: 12),
          Text(_error ? _status : '$_status $_pct%'),
        ],
      ),
      actions: _error
          ? [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إغلاق')),
            ]
          : null,
    );
  }
}
