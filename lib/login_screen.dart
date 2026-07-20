import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
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

    // بدء خدمة الخلفية الدائمة (سحب الطلبات + الإنذار المستمر)
    await FlutterForegroundTask.clearAllData();
    await startAlarmService(driver['id']);

    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFf1f5f9),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_shipping, size: 64, color: Color(0xFF1a56db)),
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
                                backgroundColor: const Color(0xFF1a56db),
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
