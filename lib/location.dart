import 'dart:math' as math;
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
    // محاولة 1: دقة عالية
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return {'lat': pos.latitude, 'lng': pos.longitude, 'acc': pos.accuracy};
    } catch (_) {
      // محاولة 2: دقة عادية أسرع
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
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
