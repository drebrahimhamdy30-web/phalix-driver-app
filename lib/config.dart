// إعدادات الاتصال بالباك إند
class Config {
  static const String supabaseUrl = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
  // مفتاح anon (عام - مصمّم ليكون في التطبيق)
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

  // webhook تسجيل الدخول في n8n
  static const String loginUrl =
      'https://agent.ebrahimhamdy.com/webhook/login';

  // قناة الإشعارات + الصوت (قناة جديدة بصوت إنذار مستمر عالي)
  // ملاحظة: قنوات أندرويد ثابتة، فأي تغيير للصوت يتطلب معرّف قناة جديد
  static const String channelId = 'phalix_alarm_v3';
  static const String channelName = 'طلبات التوصيل (إنذار)';
  static const String channelDesc = 'إشعارات الطلبات الجديدة للسائق بصوت إنذار مستمر';
}
