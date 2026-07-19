import 'package:firebase_core/firebase_core.dart';

// إعدادات مشروع Firebase (phalix-delivery) — صريحة، بدون الحاجة لملف gradle
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => android;

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDCiRb9S2ySuZk9ymQm3_tX2v8SffmIyWk',
    appId: '1:481699262602:android:c71a923ff2352dac023d73',
    messagingSenderId: '481699262602',
    projectId: 'phalix-delivery',
    storageBucket: 'phalix-delivery.firebasestorage.app',
  );
}
