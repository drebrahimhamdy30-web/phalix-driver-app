import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

// نتيجة فحص موقع الاستلام
class LocResult {
  final bool ok; // true = داخل النطاق أو الفحص مقفول
  final bool noLoc; // true = تعذّر تحديد الموقع (إذن/GPS)
  final int? distance; // المسافة بالمتر من الصيدلية
  final double? lat;
  final double? lng;
  final double? acc; // دقة الـ GPS بالمتر
  const LocResult({
    required this.ok,
    this.noLoc = false,
    this.distance,
    this.lat,
    this.lng,
    this.acc,
  });
}

// مسافة هافرساين بين نقطتين بالمتر
int _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0; // نصف قطر الأرض
  double toRad(double d) => d * math.pi / 180;
  final dLat = toRad(lat2 - lat1);
  final dLng = toRad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(toRad(lat1)) *
          math.cos(toRad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return (r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))).round();
}

// يجيب موقع الطيار — يرجّع {lat,lng,acc} أو null
Future<Map<String, double>?> _getMyLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    // مسار سريع (شبه فوري): آخر موقع معروف لو حديث ودقته كويسة —
    // الطيار عند الصيدلية فمعقول نستخدمه بدل ما نستنى قفلة GPS جديدة
    try {
      final last = await Geolocator.getLastKnownPosition();
      final ts = last?.timestamp;
      if (last != null &&
          last.accuracy > 0 &&
          last.accuracy <= 80 &&
          ts != null &&
          DateTime.now().difference(ts).inSeconds <= 45) {
        return {
          'lat': last.latitude,
          'lng': last.longitude,
          'acc': last.accuracy
        };
      }
    } catch (_) {}
    // محاولة: دقة متوسطة (أسرع بكتير من العالية — بتستخدم الشبكة/الواي فاي،
    // وكافية لفحص نطاق ~50م) بمهلة أقصر
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return {'lat': pos.latitude, 'lng': pos.longitude, 'acc': pos.accuracy};
    } catch (_) {
      // احتياطي أخير: دقة منخفضة أسرع
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 6),
        ),
      );
      return {'lat': pos.latitude, 'lng': pos.longitude, 'acc': pos.accuracy};
    }
  } catch (_) {
    return null;
  }
}

// يجيب موقع الطيار الحالي (لموقع التسليم) — {lat,lng,acc} أو null
Future<Map<String, double>?> getCurrentLatLng() => _getMyLocation();

// يفحص موقع الاستلام مقابل إعدادات الفرع
Future<LocResult> checkPickupLocation(Map<String, dynamic>? settings) async {
  if (settings == null) return const LocResult(ok: true);
  if (settings['location_check_enabled'] != true) {
    return const LocResult(ok: true);
  }
  final plat = double.tryParse('${settings['pharmacy_lat']}');
  final plng = double.tryParse('${settings['pharmacy_lng']}');
  if (plat == null || plng == null || plat == 0 || plng == 0) {
    return const LocResult(ok: true); // مفيش إحداثيات → منعدرش نفحص
  }
  final radius = (settings['pickup_radius_meters'] is num)
      ? (settings['pickup_radius_meters'] as num).toInt()
      : 150;

  final loc = await _getMyLocation();
  if (loc == null) {
    // رفض الإذن أو فشل الـ GPS → مخالفة "بدون موقع" بس الاستلام يعدي
    return const LocResult(ok: false, noLoc: true);
  }

  final dist = _distanceMeters(loc['lat']!, loc['lng']!, plat, plng);
  if (dist > radius) {
    return LocResult(
        ok: false,
        distance: dist,
        lat: loc['lat'],
        lng: loc['lng'],
        acc: loc['acc']);
  }
  return LocResult(
      ok: true, distance: dist, lat: loc['lat'], lng: loc['lng'], acc: loc['acc']);
}

// رسالة منع موحّدة تظهر لما الطيار بره نطاق الصيدلية أو الموقع غير متاح
// action مثال: "تستلم الطلب" / "تنهي الرحلة" / "تطلب الحضور"
Future<void> showLocBlockDialog(
    BuildContext context, LocResult res, String action) async {
  if (!context.mounted) return;
  final msg = res.noLoc
      ? 'مش قادر أحدّد موقعك، فمش هينفع $action دلوقتي.\n\nشغّل الـGPS (خدمة الموقع) واسمح للتطبيق بالوصول للموقع، وبعدين حاول تاني.'
      : 'لازم تكون داخل نطاق الصيدلية عشان $action.\n\nإنت على بُعد ${res.distance} متر من الصيدلية.';
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(res.noLoc ? '📍 الموقع غير مفعّل' : '📍 خارج نطاق الصيدلية'),
      content: Text(msg, style: const TextStyle(height: 1.5)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('حسناً')),
      ],
    ),
  );
}

// بوابة موقع: تجيب الإعدادات وتفحص، وتظهر رسالة منع لو ممنوع. ترجّع true لو مسموح.
Future<bool> gateAtPharmacy(BuildContext context,
    Map<String, dynamic>? settings, String action) async {
  final res = await checkPickupLocation(settings);
  if (res.ok) return true;
  await showLocBlockDialog(context, res, action);
  return false;
}
