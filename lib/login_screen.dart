import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';
import 'home_screen.dart';
import 'main.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    setState(() { _loading = true; _error = null; });
    final u = _user.text.trim();
    final p = _pass.text.trim();
    if (u.isEmpty || p.isEmpty) {
      setState(() { _loading = false; _error = 'أدخل اسم المستخدم وكلمة المرور'; });
      return;
    }

    final res = await Api.login(u, p);
    if (res == null) {
      setState(() { _loading = false; _error = 'اسم المستخدم أو كلمة المرور غير صحيحة'; });
      return;
    }
    if (res['role'] != 'driver') {
      setState(() { _loading = false; _error = 'هذا التطبيق مخصّص للسائقين فقط'; });
      return;
    }

    final jwt = res['jwt'] as String? ?? '';
    final userId = res['id'] is int ? res['id'] as int : int.tryParse('${res['id']}') ?? 0;
    final driver = await Api.getDriver(userId, jwt);
    if (driver == null) {
      setState(() { _loading = false; _error = 'لم يتم العثور على بيانات السائق'; });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', driver['id']);
    await prefs.setString('driver_name', driver['full_name'] ?? res['user'] ?? 'سائق');
    await prefs.setString('jwt', jwt);
    await prefs.setString('branch', res['branch'] ?? '');
    await prefs.setString('branch_id', '${driver['branch_id'] ?? ''}');

    // بدء خدمة الخلفية الدائمة (سحب الطلبات + الإنذار المستمر)
    await FlutterForegroundTask.clearAllData();
    await startAlarmService(driver['id']);

    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  // نسيت كلمة السر: خطوة 1 اسم/إيميل → إرسال كود، خطوة 2 كود + كلمة سر جديدة
  Future<void> _forgotPassword() async {
    final loginCtrl = TextEditingController(text: _user.text.trim());
    final login = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة كلمة السر'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'اكتب اسم المستخدم أو الإيميل المسجّل، وهنبعتلك كود على إيميلك.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 10),
          TextField(
              controller: loginCtrl,
              decoration: const InputDecoration(
                  labelText: 'اسم المستخدم / الإيميل',
                  border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, loginCtrl.text.trim()),
              child: const Text('إرسال الكود')),
        ],
      ),
    );
    if (login == null || login.isEmpty) return;
    await Api.requestPasswordReset(login);
    if (!mounted) return;

    final codeCtrl = TextEditingController();
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    String? err;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تعيين كلمة سر جديدة'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'لو الحساب موجود، وصلك كود من 6 أرقام على إيميلك (صالح 15 دقيقة). راجع الـSpam كمان.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'الكود (6 أرقام)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(
                  controller: p1,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'كلمة السر الجديدة',
                      border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(
                  controller: p2,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'تأكيد كلمة السر',
                      border: OutlineInputBorder())),
              if (err != null)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(err!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 13))),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
                onPressed: () async {
                  final code = codeCtrl.text.trim();
                  if (code.length != 6 ||
                      int.tryParse(code) == null) {
                    setD(() => err = 'اكتب الكود المكوّن من 6 أرقام');
                    return;
                  }
                  if (p1.text.length < 6) {
                    setD(() => err = 'كلمة السر 6 أحرف على الأقل');
                    return;
                  }
                  if (p1.text != p2.text) {
                    setD(() => err = 'كلمتا السر غير متطابقتين');
                    return;
                  }
                  setD(() => err = null);
                  final r = await Api.resetPasswordWithCode(
                      login, code, p1.text);
                  if (r['success'] == true) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setD(() =>
                        err = '${r['error'] ?? 'تعذّر تغيير كلمة السر'}');
                  }
                },
                child: const Text('حفظ')),
          ],
        ),
      ),
    );
    if (done == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✓ اتغيّرت كلمة السر — سجّل دخول بيها دلوقتي')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_shipping, size: 64, color: AppTheme.primary),
                const SizedBox(height: 12),
                const Text('Phalix — السائق',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        TextField(
                          controller: _user,
                          decoration: const InputDecoration(
                            labelText: 'اسم المستخدم / الموبايل',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _pass,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'كلمة المرور',
                            prefixIcon: Icon(Icons.lock_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(_error!,
                                style: const TextStyle(color: Colors.red)),
                          ),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _login,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white),
                            child: _loading
                                ? const SizedBox(
                                    width: 22, height: 22,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2))
                                : const Text('تسجيل الدخول',
                                    style: TextStyle(fontSize: 16)),
                          ),
                        ),
                        const SizedBox(height: 2),
                        TextButton(
                          onPressed: _loading ? null : _forgotPassword,
                          child: const Text('نسيت كلمة السر؟'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
