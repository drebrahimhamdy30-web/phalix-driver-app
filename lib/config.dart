import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ثيم التطبيق: أزرق متناغم مع لوجو التطبيق (درجات الأزرق)
class AppTheme {
  static const Color primary = Color(0xFF1E88E5); // أزرق اللوجو الفاتح (أزرار/تمييز)
  static const Color appBar = Color(0xFF0A3D62); // كحلي غامق (شريط العنوان)
  static const Color bg = Color(0xFFF5F9FF); // أزرق فاتح جداً (خلفية)
  static const Color onAppBar = Colors.white;
}

// إعدادات الاتصال بالباك إند
class Config {
  // ═══ عنوان الباك إند — يُقرأ وقت التشغيل مش محروق في التطبيق ═══
  //
  // ليه: لو العنوان ثابت جوّه التطبيق، أي نقل للباك إند (أو رجوع عنه)
  // يتطلب نسخة جديدة + تحديث إجباري لكل الطيارين — وده بيخلّي النقل
  // «نقطة لا رجوع»: لو حصلت مشكلة بعد التحويل، الرجوع محتاج نسخة تالتة
  // وتحديث إجباري تالت. دلوقتي التحويل = تعديل سطر في app-config.json
  // والتطبيقات بتتحوّل لوحدها أول ما تفتح.
  //
  // ⚠️ ملف الإعداد على استضافة الشاشات **مش** على سوبابيز — عن قصد:
  // لو الباك إند نفسه وقع، لازم نفضل قادرين نوجّه التطبيقات لمكان تاني.

  static const String defaultSupabaseUrl = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
  // مفتاح anon (عام - مصمّم ليكون في التطبيق)
  static const String defaultSupabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

  static const String remoteConfigUrl =
      'https://phalix.ebrahimhamdy.com/app-config.json';

  // القيم الحيّة: الافتراضي ← المحفوظ من آخر مرة ← البعيد
  static String supabaseUrl = defaultSupabaseUrl;
  static String supabaseAnonKey = defaultSupabaseAnonKey;

  /// يقرا الإعداد: الكاش الأول (فوري) وبعدين البعيد (لو الشبكة سمحت).
  /// بيتنده في main() **قبل** تهيئة سوبابيز، وفي الخدمة الخلفية كمان
  /// لأنها isolate منفصل بمتغيّراته الساكنة الخاصة.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cu = prefs.getString('cfg_url');
      final ck = prefs.getString('cfg_key');
      if (_valid(cu, ck)) {
        supabaseUrl = cu!;
        supabaseAnonKey = ck!;
      }
    } catch (_) {}

    try {
      // t= عشان نعدّي على كاش الـCDN — التحويل لازم يوصل في دقايق مش ساعات
      final t = DateTime.now().millisecondsSinceEpoch ~/ 60000;
      final res = await http
          .get(Uri.parse('$remoteConfigUrl?t=$t'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body);
      final u = (j is Map ? j['supabaseUrl'] : null) as String?;
      final k = (j is Map ? j['supabaseAnonKey'] : null) as String?;
      if (!_valid(u, k)) return; // إعداد مكسور = نسيب اللي عندنا
      supabaseUrl = u!;
      supabaseAnonKey = k!;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cfg_url', u);
      await prefs.setString('cfg_key', k);
    } catch (_) {
      // مفيش نت أو الملف مش راد — بنكمّل باللي عندنا.
      // التطبيق مايقفش عشان ملف إعداد مش وصل.
    }
  }

  static bool _valid(String? u, String? k) =>
      u != null &&
      k != null &&
      u.startsWith('https://') &&
      u.length > 12 &&
      '.'.allMatches(k).length == 2 && // شكل JWT: تلات أجزاء
      k.length > 100;

  // webhook تسجيل الدخول في n8n
  static const String loginUrl =
      'https://agent.ebrahimhamdy.com/webhook/login';

  // webhook طلب كود استعادة كلمة السر (يبعت كود 6 أرقام على إيميل الطيار)
  static const String forgotPasswordUrl =
      'https://agent.ebrahimhamdy.com/webhook/forgot_password';

  // webhook فحص طلبات الرحلة السابقة على نظام الصيدلية (B Connect)
  static const String checkPrevTripUrl =
      'https://agent.ebrahimhamdy.com/webhook/check_prev_trip';

  // نقطة سحب الطلبات الجديدة (خدمة الخلفية تناديها بشكل دوري)
  // getters مش const — العنوان بيتحدد وقت التشغيل
  static String get pollUrl => '$supabaseUrl/functions/v1/driver-poll';
  static String get markUrl => '$supabaseUrl/functions/v1/driver-mark';
  static const String appSecret =
      '87bcac4b4da9317f3b8716e6af9269533f8e2228cc0db43b';
  // رقم إصدار داخلي للتشخيص
  static const String appVersion = 'poll-v72';
  // رقم البناء (يُقارن بآخر نسخة منشورة لعرض رسالة التحديث)
  // ملاحظة: الـworkflow يزامن هذا الرقم تلقائيًا من pubspec عند البناء
  static const int appBuild = 72;
  // كل كام ثانية تسحب الخدمة الطلبات الجديدة — 20ث لتخفيف الضغط على اتصالات قاعدة البيانات
  // (الطلبات الجديدة بتوصل بالإشعار FCM فورًا، فالسحب مجرد تحديث دوري للحالة)
  static const int pollIntervalMs = 20000;

  // قناة الإنذار (صوت إنذار مستمر عالي) — قنوات أندرويد ثابتة فأي تغيير للصوت يتطلب معرّف قناة جديد
  static const String channelId = 'phalix_alarm_v4';
  static const String channelName = 'طلبات التوصيل (إنذار)';
  static const String channelDesc = 'إشعارات الطلبات الجديدة للسائق بصوت إنذار مستمر';

  // قناة الإشعارات العادية (رسائل/سحب طلب) — بصوت افتراضي قصير
  static const String notifyChannelId = 'phalix_notify_v1';
  static const String notifyChannelName = 'تنبيهات وإشعارات';
  static const String notifyChannelDesc = 'رسائل الإدارة وتنبيهات سحب الطلبات';

  // قناة الخدمة الدائمة (إشعار صامت ثابت يوضّح أن التطبيق يعمل)
  static const String serviceChannelId = 'phalix_service';
  static const String serviceChannelName = 'تشغيل التطبيق';
  static const String serviceChannelDesc =
      'يبقى التطبيق صاحيًا لاستقبال الطلبات فورًا';
}
