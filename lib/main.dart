import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'firebase_options.dart';
import 'login_screen.dart';
import 'home_screen.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

final Int64List _vibration =
    Int64List.fromList([0, 800, 400, 800, 400, 800, 400, 800]);

// قناة الإنذار (صوت عالي مستمر + اهتزاز)
final AndroidNotificationChannel ordersChannel = AndroidNotificationChannel(
  Config.channelId,
  Config.channelName,
  description: Config.channelDesc,
  importance: Importance.max,
  playSound: true,
  sound: const RawResourceAndroidNotificationSound('alert'),
  audioAttributesUsage: AudioAttributesUsage.alarm,
  enableVibration: true,
  vibrationPattern: _vibration,
);

// تهيئة نظام الإشعارات + قناة الإنذار (تُستدعى في كل عملية/isolate)
Future<void> initNotifications() async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await localNotifications.initialize(initSettings);
  await localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(ordersChannel);
}

// عرض إنذار مستمر (يعيد الصوت لحد ما يُفتح الطلب)
Future<void> showAlarm(String title, String body) async {
  await localNotifications.show(
    88, // معرّف ثابت — إشعار إنذار واحد يتجدّد
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        Config.channelId,
        Config.channelName,
        channelDescription: Config.channelDesc,
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('alert'),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        vibrationPattern: _vibration,
        additionalFlags: Int32List.fromList(<int>[4]), // FLAG_INSISTENT: يكرّر الصوت
        ongoing: true, // لا يُمسح بالسحب — لازم يفتح التطبيق
        autoCancel: false,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true, // يظهر كمكالمة حتى والشاشة مقفولة
      ),
    ),
  );
}

Future<void> cancelAlarm() async {
  await localNotifications.cancel(88);
}

// ================= خدمة الخلفية الدائمة =================
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(AlarmTaskHandler());
}

class AlarmTaskHandler extends TaskHandler {
  bool _busy = false;
  String _driverId = '';
  DateTime _baseline = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await initNotifications();
    _driverId =
        (await FlutterForegroundTask.getData<String>(key: 'driver_id')) ?? '';
    final savedBase =
        await FlutterForegroundTask.getData<String>(key: 'baseline');
    if (savedBase != null && savedBase.isNotEmpty) {
      _baseline = DateTime.tryParse(savedBase)?.toUtc() ?? _baseline;
    } else {
      // تهيئة خط الأساس: لا ننبّه على الطلبات الموجودة مسبقًا
      final orders = await _fetch();
      _baseline = _maxAssigned(orders, _baseline);
      await FlutterForegroundTask.saveData(
          key: 'baseline', value: _baseline.toIso8601String());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_busy || _driverId.isEmpty) return;
    _busy = true;
    _poll().whenComplete(() => _busy = false);
  }

  Future<void> _poll() async {
    final orders = await _fetch();
    if (orders.isEmpty) return;
    final fresh = orders.where((o) {
      final a = DateTime.tryParse('${o['assigned_at']}')?.toUtc();
      return a != null && a.isAfter(_baseline);
    }).toList();
    if (fresh.isNotEmpty) {
      final o = fresh.first; // الأحدث (مرتّبة تنازليًا)
      final bill = o['bill_no'] ?? '';
      final region = o['cust_region'] ?? '';
      await showAlarm('📦 طلب جديد وصلك!',
          'طلب #$bill${region != '' ? ' - $region' : ''}');
      _baseline = _maxAssigned(orders, _baseline);
      await FlutterForegroundTask.saveData(
          key: 'baseline', value: _baseline.toIso8601String());
    }
  }

  Future<List<Map<String, dynamic>>> _fetch() async {
    try {
      final res = await http
          .post(
            Uri.parse(Config.pollUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(
                {'driver_id': _driverId, 'secret': Config.appSecret}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final list = (data is Map ? data['orders'] : null) as List? ?? [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  DateTime _maxAssigned(List<Map<String, dynamic>> orders, DateTime current) {
    var mx = current;
    for (final o in orders) {
      final a = DateTime.tryParse('${o['assigned_at']}')?.toUtc();
      if (a != null && a.isAfter(mx)) mx = a;
    }
    return mx;
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
    cancelAlarm();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

// بدء خدمة الخلفية
Future<void> startAlarmService(String driverId) async {
  await FlutterForegroundTask.saveData(key: 'driver_id', value: driverId);
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 256,
    notificationTitle: 'Phalix — جاهز لاستقبال الطلبات',
    notificationText: 'التطبيق يعمل في الخلفية لتنبيهك بالطلبات فورًا',
    callback: startCallback,
  );
}

Future<void> stopAlarmService() async {
  await FlutterForegroundTask.stopService();
}

// إعداد خيارات الخدمة الدائمة
void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: Config.serviceChannelId,
      channelName: Config.serviceChannelName,
      channelDescription: Config.serviceChannelDesc,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(Config.pollIntervalMs),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

// طلب الأذونات اللازمة لعمل الخدمة بلا توقف
Future<void> _requestPermissions() async {
  final np = await FlutterForegroundTask.checkNotificationPermission();
  if (np != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

// ================= FCM (مسار احتياطي عند فتح التطبيق) =================
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initNotifications();
  final t =
      message.notification?.title ?? message.data['title'] ?? '📦 طلب جديد';
  final b =
      message.notification?.body ?? message.data['body'] ?? 'وصلك طلب جديد';
  await showAlarm(t, b);
}

Future<void> _fgMessage(RemoteMessage message) async {
  final t =
      message.notification?.title ?? message.data['title'] ?? '📦 طلب جديد';
  final b =
      message.notification?.body ?? message.data['body'] ?? 'وصلك طلب جديد';
  await showAlarm(t, b);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await initNotifications();
  _initForegroundTask();

  await FirebaseMessaging.instance
      .requestPermission(alert: true, badge: true, sound: true);
  await _requestPermissions();

  FirebaseMessaging.onBackgroundMessage(_bgHandler);
  FirebaseMessaging.onMessage.listen(_fgMessage);

  final prefs = await SharedPreferences.getInstance();
  final driverId = prefs.getString('driver_id');
  final loggedIn = driverId != null && driverId.isNotEmpty;

  if (loggedIn) {
    await startAlarmService(driverId);
  }

  runApp(PhalixDriverApp(loggedIn: loggedIn));
}

class PhalixDriverApp extends StatelessWidget {
  final bool loggedIn;
  const PhalixDriverApp({super.key, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phalix Driver',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        primaryColor: const Color(0xFF1a56db),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1a56db)),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: loggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
