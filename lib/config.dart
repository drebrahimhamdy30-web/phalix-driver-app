import 'package:flutter/material.dart';

// ثيم التطبيق: أزرق متناغم مع لوجو التطبيق (درجات الأزرق)
class AppTheme {
  static const Color primary = Color(0xFF1E88E5); // أزرق اللوجو الفاتح (أزرار/تمييز)
  static const Color appBar = Color(0xFF0A3D62); // كحلي غامق (شريط العنوان)
  static const Color bg = Color(0xFFF5F9FF); // أزرق فاتح جداً (خلفية)
  static const Color onAppBar = Colors.white;
}

// إعدادات الاتصال بالباك إند
class Config {
  static const String supabaseUrl = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
  // مفتاح anon (عام - مصمّم ليكون في التطبيق)
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

  // webhook تسجيل الدخول في n8n
  static const String loginUrl =
      'https://agent.ebrahimhamdy.com/webhook/login';

  // webhook فحص طلبات الرحلة السابقة على نظام الصيدلية (B Connect)
  static const String checkPrevTripUrl =
      'https://agent.ebrahimhamdy.com/webhook/check_prev_trip';

  // نقطة سحب الطلبات الجديدة (خدمة الخلفية تناديها بشكل دوري)
  static const String pollUrl =
      '$supabaseUrl/functions/v1/driver-poll';
  static const String markUrl =
      '$supabaseUrl/functions/v1/driver-mark';
  static const String appSecret =
      '87bcac4b4da9317f3b8716e6af9269533f8e2228cc0db43b';
  // رقم إصدار داخلي للتشخيص
  static const String appVersion = 'poll-v31';
  // رقم البناء (يُقارن بآخر نسخة منشورة لعرض رسالة التحديث)
  static const int appBuild = 31;
  // كل كام ثانية تسحب الخدمة الطلبات الجديدة
  static const int pollIntervalMs = 10000;

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
