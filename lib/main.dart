import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
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

// قناة الإنذار (الصوت يُشغَّل بمشغّل الصوت في حلقة، فالقناة صامتة + اهتزاز)
final AndroidNotificationChannel ordersChannel = AndroidNotificationChannel(
  Config.channelId,
  Config.channelName,
  description: Config.channelDesc,
  importance: Importance.max,
  playSound: false,
  enableVibration: true,
  vibrationPattern: _vibration,
);

// مشغّل صوت الإنذار (حلقة مستمرة)
AudioPlayer? _alarmPlayer;
Future<void> startAlarmSound() async {
  try {
    _alarmPlayer ??= AudioPlayer();
    await _alarmPlayer!.setReleaseMode(ReleaseMode.loop);
    await _alarmPlayer!.setVolume(1.0);
    await _alarmPlayer!.play(AssetSource('alert.mp3'), volume: 1.0);
    // اهتزاز متكرر مع الصوت
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 700, 400, 700, 400], repeat: 0);
      }
    } catch (_) {}
    await _report('sound_started', {});
  } catch (e) {
    await _report('sound_error', {'err': e.toString()});
  }
}

Future<void> stopAlarmSound() async {
  try {
    await _alarmPlayer?.stop();
  } catch (_) {}
  try {
    Vibration.cancel();
  } catch (_) {}
}

// قناة الإشعارات العادية (رسائل/سحب طلب) — صوت افتراضي قصير
final AndroidNotificationChannel notifyChannel = AndroidNotificationChannel(
  Config.notifyChannelId,
  Config.notifyChannelName,
  description: Config.notifyChannelDesc,
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

// تهيئة نظام الإشعارات + القنوات (تُستدعى في كل عملية/isolate)
Future<void> initNotifications() async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await localNotifications.initialize(initSettings);
  final android = localNotifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(ordersChannel);
  await android?.createNotificationChannel(notifyChannel);
}

// إشعار عادي (رسالة إدارة / سحب طلب) — صوت قصير، يُمسح بالفتح
int _notifyId = 200;
Future<void> showNotify(String title, String body) async {
  try {
    _notifyId = _notifyId >= 260 ? 200 : _notifyId + 1;
    await localNotifications.show(
      _notifyId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          Config.notifyChannelId,
          Config.notifyChannelName,
          channelDescription: Config.notifyChannelDesc,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          autoCancel: true,
        ),
      ),
    );
  } catch (e) {
    await _report('notify_error', {'err': e.toString()});
  }
}

// تسجيل تشخيصي للخادم
Future<void> _report(String event, Map<String, dynamic> data) async {
  try {
    await http
        .post(Uri.parse(Config.markUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'event': event, ...data}))
        .timeout(const Duration(seconds: 5));
  } catch (_) {}
}

// عرض إنذار مستمر (يعيد الصوت لحد ما يُفتح الطلب)
Future<void> showAlarm(String title, String body) async {
 try {
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
        playSound: false, // الصوت يُشغَّل بمشغّل الصوت في حلقة مستمرة
        enableVibration: true,
        vibrationPattern: _vibration,
        ongoing: true, // لا يُمسح بالسحب — لازم يفتح التطبيق
        autoCancel: false,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true, // يظهر بارزًا حتى والشاشة مقفولة
      ),
    ),
  );
  await _report('alarm_shown', {'note': body});
 } catch (e) {
  await _report('alarm_error', {'err': e.toString()});
 }
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
  List<int> _pendingAck = [];

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // تسجيل الـ plugins داخل عملية الخدمة (لازم عشان الإشعارات تشتغل هنا)
    ui.DartPluginRegistrant.ensureInitialized();
    await initNotifications();
    _driverId =
        (await FlutterForegroundTask.getData<String>(key: 'driver_id')) ?? '';
    await _report('start', {'v': Config.appVersion, 'driver_id': _driverId});
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_busy || _driverId.isEmpty) return;
    _busy = true;
    _poll().whenComplete(() => _busy = false);
  }

  Future<void> _poll() async {
    final events = await _fetchEvents();
    if (events.isEmpty) return;
    final ackIds = <int>[];
    bool loud = false;
    for (final e in events) {
      final id = e['id'];
      if (id is int) ackIds.add(id);
      final type = '${e['type']}';
      final title = '${e['title'] ?? 'تنبيه'}';
      final body = '${e['body'] ?? ''}';
      if (type == 'order_added' || type == 'summon') {
        await showAlarm(title, body); // إنذار عالٍ مستمر
        loud = true;
      } else {
        await showNotify(title, body); // إشعار عادي (سحب طلب / رسالة)
      }
    }
    if (loud) await startAlarmSound();
    _pendingAck = ackIds; // تُؤكَّد في السحبة الجاية
  }

  Future<List<Map<String, dynamic>>> _fetchEvents() async {
    final toAck = _pendingAck;
    try {
      final res = await http
          .post(
            Uri.parse(Config.pollUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'driver_id': _driverId,
              'secret': Config.appSecret,
              'ack': toAck,
            }),
          )
          .timeout(const Duration(seconds: 8));
      _pendingAck = []; // اتبعتت للتأكيد
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final list = (data is Map ? data['events'] : null) as List? ?? [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  void onNotificationPressed() {
    stopAlarmSound();
    cancelAlarm();
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onReceiveData(Object data) {
    if (data == 'stop_alarm') {
      stopAlarmSound();
      cancelAlarm();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await stopAlarmSound();
  }
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
  await startAlarmSound();
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
