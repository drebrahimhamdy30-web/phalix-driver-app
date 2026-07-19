import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'firebase_options.dart';
import 'login_screen.dart';
import 'home_screen.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

final Int64List _vibration = Int64List.fromList([0, 800, 400, 800, 400, 800, 400, 800]);

// قناة بمستوى المنبّه (صوت عالي + اهتزاز، تصوّت حتى والتطبيق مقفول)
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

// معالج الرسائل والتطبيق مقفول/في الخلفية (لازم top-level)
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _showNotification(message);
}

Future<void> _showNotification(RemoteMessage message) async {
  final n = message.notification;
  final title = n?.title ?? message.data['title'] ?? '📦 طلب جديد';
  final body = n?.body ?? message.data['body'] ?? 'وصلك طلب جديد';
  await localNotifications.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
        additionalFlags: Int32List.fromList(<int>[4]), // FLAG_INSISTENT: يكرر الصوت لحد ما يُفتح
        category: AndroidNotificationCategory.alarm,
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // إعداد الإشعارات المحلية + القناة
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await localNotifications.initialize(initSettings);
  await localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(ordersChannel);

  // أذونات الإشعارات (أندرويد 13+)
  await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
  await localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  // معالج الخلفية
  FirebaseMessaging.onBackgroundMessage(_bgHandler);

  // رسالة والتطبيق مفتوح (foreground) — نعرضها يدويًا بالصوت
  FirebaseMessaging.onMessage.listen(_showNotification);

  final prefs = await SharedPreferences.getInstance();
  final loggedIn = prefs.getString('driver_id') != null;

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
