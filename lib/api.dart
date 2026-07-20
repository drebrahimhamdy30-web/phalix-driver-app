import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class Api {
  // ترويسات Supabase REST (anon key + توكن المستخدم)
  static Map<String, String> _headers(String? jwt) => {
        'apikey': Config.supabaseAnonKey,
        'Authorization': 'Bearer ${jwt ?? Config.supabaseAnonKey}',
        'Content-Type': 'application/json',
      };

  // تسجيل الدخول عبر n8n
  static Future<Map<String, dynamic>?> login(String user, String pass) async {
    try {
      final res = await http.post(
        Uri.parse(Config.loginUrl),
        headers: {'Content-Type': 'text/plain'},
        body: jsonEncode({'user': user, 'pass': pass}),
      );
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map && data['status'] == 'success') {
        return Map<String, dynamic>.from(data);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // جلب بيانات السائق (uuid + الاسم) من رقم مستخدمه
  static Future<Map<String, dynamic>?> getDriver(int userId, String jwt) async {
    final url =
        '${Config.supabaseUrl}/rest/v1/drivers?branch_user_id=eq.$userId&select=id,full_name,is_online,branch_id&limit=1';
    final res = await http.get(Uri.parse(url), headers: _headers(jwt));
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List;
      if (list.isNotEmpty) return Map<String, dynamic>.from(list.first);
    }
    return null;
  }

  // حفظ/تحديث توكن FCM للسائق
  static Future<bool> saveFcmToken(
      String driverId, String token, String jwt) async {
    final url =
        '${Config.supabaseUrl}/rest/v1/driver_fcm_tokens?on_conflict=token';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        ..._headers(jwt),
        'Prefer': 'resolution=merge-duplicates',
      },
      body: jsonEncode({
        'driver_id': driverId,
        'token': token,
        'platform': 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    return res.statusCode >= 200 && res.statusCode < 300;
  }

  // جلب طلبات السائق النشطة
  static Future<List<Map<String, dynamic>>> getOrders(
      String driverId, String jwt) async {
    final url =
        '${Config.supabaseUrl}/rest/v1/orders?driver_id=eq.$driverId'
        '&status=in.(assigned,picked,failed)'
        '&select=id,bill_no,customer_name,customer_phone,customer_address,cust_region,total_bill_net,status'
        '&order=assigned_at.desc';
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers(jwt))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  static String get _rest => '${Config.supabaseUrl}/rest/v1';

  static Future<List<Map<String, dynamic>>> _getList(
      String url, String jwt) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers(jwt))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  // تحميل لوحة الطيار: الرحلة الجارية + آخر 3 رحلات + طلباتها (مُحسّن: نداءات أقل)
  static Future<Map<String, dynamic>> loadBoard(
      String driverId, String? branchId, String jwt) async {
    final trips = await _getList(
        '$_rest/trips?driver_id=eq.$driverId&status=in.(active,pending_complete,completed)&order=created_at.desc&limit=10&select=*',
        jwt);
    final active = trips
        .where((t) => ['active', 'pending_complete'].contains(t['status']))
        .toList();
    final completed =
        trips.where((t) => t['status'] == 'completed').take(3).toList();
    final board = <Map<String, dynamic>>[];
    if (active.isNotEmpty) board.add(active.first);
    board.addAll(completed);

    final tripOrders = <String, List<Map<String, dynamic>>>{
      for (final t in board) '${t['id']}': <Map<String, dynamic>>[]
    };
    final tripIds = board.map((t) => '${t['id']}').toList();
    if (tripIds.isNotEmpty) {
      final links = await _getList(
          '$_rest/trip_orders?trip_id=in.(${tripIds.join(',')})&select=trip_id,order_id',
          jwt);
      final byTrip = <String, List<String>>{};
      final allIds = <String>{};
      for (final l in links) {
        final tid = '${l['trip_id']}';
        final oid = '${l['order_id']}';
        byTrip.putIfAbsent(tid, () => []).add(oid);
        allIds.add(oid);
      }
      if (allIds.isNotEmpty) {
        final orders = await _getList(
            '$_rest/orders?id=in.(${allIds.join(',')})&select=*', jwt);
        final byId = {for (final o in orders) '${o['id']}': o};
        for (final tid in byTrip.keys) {
          tripOrders[tid] = byTrip[tid]!
              .map((id) => byId[id])
              .whereType<Map<String, dynamic>>()
              .toList();
        }
      }
    }

    // طلبات مباشرة (بدون رحلة) لو مفيش رحلة جارية
    if (active.isEmpty) {
      final direct = await _getList(
          '$_rest/orders?driver_id=eq.$driverId&status=in.(assigned,picked)&select=*',
          jwt);
      if (direct.isNotEmpty) {
        board.insert(0, {
          'id': 'direct',
          'status': 'active',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        tripOrders['direct'] = direct;
      }
    }

    bool canComplete = true;
    int maxBreak = 15;
    if (branchId != null && branchId.isNotEmpty) {
      final s = await _getList(
          '$_rest/dispatch_settings?branch_id=eq.$branchId&select=driver_can_complete_trip,max_break_minutes',
          jwt);
      if (s.isNotEmpty) {
        canComplete = s.first['driver_can_complete_trip'] != false;
        final mb = s.first['max_break_minutes'];
        if (mb is num) maxBreak = mb.toInt();
      }
    }

    return {
      'trips': board,
      'tripOrders': tripOrders,
      'canComplete': canComplete,
      'maxBreak': maxBreak,
    };
  }

  // ترتيب/دور الطيار في طابور التوزيع بين الحاضرين بنفس الفرع
  static Future<Map<String, dynamic>?> getRank(
      String driverId, String branchId, String jwt) async {
    if (branchId.isEmpty) return null;
    try {
      final s = await _getList(
          '$_rest/dispatch_settings?branch_id=eq.$branchId&select=driver_priority',
          jwt);
      final priority =
          s.isNotEmpty ? '${s.first['driver_priority'] ?? 'least_orders'}' : 'least_orders';

      final drivers = await _getList(
          '$_rest/drivers?branch_id=eq.$branchId&is_active=eq.true&select=id',
          jwt);
      final ids = drivers.map((d) => '${d['id']}').toList();
      if (ids.isEmpty) return null;

      final att = await _getList(
          '$_rest/driver_attendance?driver_id=in.(${ids.join(',')})&order=created_at.desc&limit=500&select=driver_id,status,approved_at,created_at',
          jwt);
      final latest = <String, Map<String, dynamic>>{};
      for (final r in att) {
        final id = '${r['driver_id']}';
        latest.putIfAbsent(id, () => r);
      }
      final online = latest.entries
          .where((e) => e.value['status'] == 'online')
          .map((e) => e.key)
          .toList();
      if (!online.contains(driverId)) return null; // مش حاضر
      final total = online.length;

      DateTime arr(String id) =>
          DateTime.tryParse('${latest[id]?['approved_at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0);

      int rank = 1;
      if (priority != 'longest_idle') {
        // الأقل طلبات أولاً
        final orders = await _getList(
            '$_rest/orders?status=in.(assigned,picked)&driver_id=in.(${online.join(',')})&select=driver_id',
            jwt);
        final count = {for (final id in online) id: 0};
        for (final o in orders) {
          final d = '${o['driver_id']}';
          if (count.containsKey(d)) count[d] = count[d]! + 1;
        }
        final myCount = count[driverId] ?? 0;
        final myArr = arr(driverId);
        rank = online.where((id) {
              final tc = count[id] ?? 0;
              if (tc < myCount) return true;
              if (tc == myCount) return arr(id).isBefore(myArr);
              return false;
            }).length +
            1;
      } else {
        // الأطول فراغًا أولاً
        final lastOrders = await _getList(
            '$_rest/orders?driver_id=in.(${online.join(',')})&assigned_at=not.is.null&order=assigned_at.desc&select=driver_id,assigned_at',
            jwt);
        final lastAssigned = <String, DateTime>{};
        for (final o in lastOrders) {
          final d = '${o['driver_id']}';
          if (!lastAssigned.containsKey(d)) {
            lastAssigned[d] = DateTime.tryParse('${o['assigned_at']}') ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
        }
        for (final id in online) {
          lastAssigned.putIfAbsent(id, () => arr(id));
        }
        final myLast =
            lastAssigned[driverId] ?? DateTime.fromMillisecondsSinceEpoch(0);
        rank = online
                .where((id) =>
                    (lastAssigned[id] ??
                            DateTime.fromMillisecondsSinceEpoch(0))
                        .isBefore(myLast))
                .length +
            1;
      }
      return {'rank': rank, 'total': total};
    } catch (_) {
      return null;
    }
  }

  // الحد الأقصى لدقائق الاستراحة (لحساب العمل الفعلي)
  static Future<int> getMaxBreak(String branchId, String jwt) async {
    if (branchId.isEmpty) return 15;
    final s = await _getList(
        '$_rest/dispatch_settings?branch_id=eq.$branchId&select=max_break_minutes',
        jwt);
    if (s.isNotEmpty && s.first['max_break_minutes'] is num) {
      return (s.first['max_break_minutes'] as num).toInt();
    }
    return 15;
  }

  // سجلات الحضور خلال فترة (لحساب ساعات العمل)
  static Future<List<Map<String, dynamic>>> getAttendance(
          String driverId, String fromDate, String toDate, String jwt) =>
      _getList(
          '$_rest/driver_attendance?driver_id=eq.$driverId&date=gte.$fromDate&date=lte.$toDate&order=date.desc&limit=500&select=date,status,approved_at,ended_at',
          jwt);

  // ===== الحضور والانصراف والاستراحة =====

  // آخر سجل حضور (لتحديد الحالة الحالية للطيار)
  static Future<Map<String, dynamic>?> getLatestAttendance(
      String driverId, String jwt) async {
    if (driverId.isEmpty) return null;
    final s = await _getList(
        '$_rest/driver_attendance?driver_id=eq.$driverId&order=created_at.desc&limit=1&select=id,status,approved_at,requested_at,ended_at,created_at',
        jwt);
    return s.isEmpty ? null : s.first;
  }

  // إعدادات الحضور للفرع
  static Future<Map<String, dynamic>> getAttendanceSettings(
      String branchId, String jwt) async {
    if (branchId.isEmpty) return {'require_approval': true, 'max_break': 15};
    final s = await _getList(
        '$_rest/dispatch_settings?branch_id=eq.$branchId&select=require_attendance_approval,max_break_minutes',
        jwt);
    if (s.isEmpty) return {'require_approval': true, 'max_break': 15};
    final r = s.first;
    return {
      'require_approval': r['require_attendance_approval'] != false,
      'max_break': (r['max_break_minutes'] is num)
          ? (r['max_break_minutes'] as num).toInt()
          : 15,
    };
  }

  // فحص إمكانية الانصراف — يرجّع رسالة منع أو null لو مسموح
  static Future<String?> offlineBlockReason(
      String driverId, String jwt) async {
    final trips = await _getList(
        '$_rest/trips?driver_id=eq.$driverId&status=eq.active&select=id&limit=1',
        jwt);
    if (trips.isNotEmpty) {
      return 'لا يمكن طلب الانصراف — لديك رحلة جارية لم تنته بعد';
    }
    final orders = await _getList(
        '$_rest/orders?driver_id=eq.$driverId&status=in.(assigned,picked)&select=id&limit=1',
        jwt);
    if (orders.isNotEmpty) {
      return 'لا يمكن طلب الانصراف — لديك طلبات لم يتم توصيلها بعد';
    }
    return null;
  }

  // طلب حضور/انصراف/استراحة — type: online | offline | break
  static Future<bool> requestAttendance(
      String driverId, String type, bool requireApproval, String jwt) async {
    final today = _todayLocal();
    final nowIso = _now();
    Map<String, dynamic> body;
    if (requireApproval) {
      const m = {
        'online': 'online_request',
        'offline': 'offline_request',
        'break': 'break_request',
      };
      body = {
        'driver_id': driverId,
        'date': today,
        'status': m[type],
        'requested_at': nowIso,
      };
    } else {
      body = {
        'driver_id': driverId,
        'date': today,
        'status': type,
        'requested_at': nowIso,
        'approved_at': nowIso,
      };
    }
    return _post('$_rest/driver_attendance', body, jwt);
  }

  // إنهاء الاستراحة (يدوي أو تلقائي) — يقفل سجل الاستراحة ويفتح سجل حضور جديد
  static Future<bool> endBreak(
      String recordId, String driverId, String jwt,
      {bool auto = false}) async {
    final nowIso = _now();
    await _patch('$_rest/driver_attendance?id=eq.$recordId',
        {'status': 'break_ended', 'ended_at': nowIso}, jwt);
    return _post(
        '$_rest/driver_attendance',
        {
          'driver_id': driverId,
          'date': _todayLocal(),
          'status': 'online',
          'approved_at': nowIso,
          'notes': auto ? 'استراحة انتهت تلقائياً' : 'إنهاء استراحة يدوي',
        },
        jwt);
  }

  // تاريخ اليوم المحلي (جهاز الطيار في مصر = توقيت القاهرة)
  static String _todayLocal() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static Future<bool> _post(
      String url, Map<String, dynamic> body, String jwt) async {
    try {
      final res = await http
          .post(Uri.parse(url),
              headers: {..._headers(jwt), 'Prefer': 'return=minimal'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // تغيير كلمة المرور (عبر نقطة سيرفر تتحقق من الحالية وتشفّر الجديدة)
  static Future<Map<String, dynamic>> changePassword(
      String driverId, String oldPw, String newPw, String jwt) async {
    try {
      final res = await http
          .post(
            Uri.parse('${Config.supabaseUrl}/functions/v1/change-password'),
            headers: _headers(jwt),
            body: jsonEncode({
              'driver_id': driverId,
              'old_password': oldPw,
              'new_password': newPw,
            }),
          )
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(res.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return {'ok': false, 'error': 'تعذّر الاتصال بالخادم'};
  }

  // إعدادات فحص موقع الاستلام للفرع
  static Future<Map<String, dynamic>?> getLocationSettings(
      String branchId, String jwt) async {
    if (branchId.isEmpty) return null;
    final s = await _getList(
        '$_rest/dispatch_settings?branch_id=eq.$branchId&select=location_check_enabled,pharmacy_lat,pharmacy_lng,pickup_radius_meters',
        jwt);
    if (s.isEmpty) return null;
    return Map<String, dynamic>.from(s.first);
  }

  // تسجيل لوج للطلب (يُستخدم لتسجيل موقع الاستلام والمخالفات)
  static Future<void> logOrder(String orderId, String event,
      Map<String, dynamic> details, String driverId, String driverName,
      String jwt) async {
    try {
      await http
          .post(
            Uri.parse('$_rest/order_logs'),
            headers: {..._headers(jwt), 'Prefer': 'return=minimal'},
            body: jsonEncode({
              'order_id': orderId,
              'event': event,
              'details': details,
              'user_id': driverId,
              'user_name': driverName,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static Future<bool> _patch(String url, Map<String, dynamic> body, String jwt) async {
    try {
      final res = await http
          .patch(Uri.parse(url),
              headers: {..._headers(jwt), 'Prefer': 'return=minimal'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  static Future<bool> pickupOrder(String id, String jwt) => _patch(
      '$_rest/orders?id=eq.$id',
      {'status': 'picked', 'picked_at': _now(), 'updated_at': _now()},
      jwt);

  static Future<bool> pickupAll(List<String> ids, String jwt) => _patch(
      '$_rest/orders?id=in.(${ids.join(',')})',
      {'status': 'picked', 'picked_at': _now(), 'updated_at': _now()},
      jwt);

  static Future<bool> deliverOrder(String id, String pay, double amount,
          String? note, String jwt) =>
      _patch(
          '$_rest/orders?id=eq.$id',
          {
            'status': 'delivered',
            'payment_method': pay,
            'collected_amount': amount,
            'driver_notes': note,
            'delivered_at': _now(),
            'updated_at': _now(),
          },
          jwt);

  static Future<bool> failOrder(
          String id, String reason, String? note, int attempt, String jwt) =>
      _patch(
          '$_rest/orders?id=eq.$id',
          {
            'status': 'failed',
            'postpone_reason': reason,
            'driver_notes': note,
            'attempt_count': attempt + 1,
            'updated_at': _now(),
          },
          jwt);

  static Future<bool> retryOrder(String id, String jwt) => _patch(
      '$_rest/orders?id=eq.$id',
      {'status': 'picked', 'picked_at': _now(), 'updated_at': _now()},
      jwt);

  static Future<bool> updateTrip(
          String id, Map<String, dynamic> body, String jwt) =>
      _patch('$_rest/trips?id=eq.$id', body, jwt);

  static Future<void> releaseFailed(List<String> ids, String jwt) async {
    if (ids.isEmpty) return;
    await _patch(
        '$_rest/orders?id=in.(${ids.join(',')})',
        {
          'status': 'postponed',
          'driver_id': null,
          'deliveryman': null,
          'assigned_at': null,
          'picked_at': null,
          'updated_at': _now(),
        },
        jwt);
  }

  static Future<void> completeDelivered(List<String> ids, String jwt) async {
    if (ids.isEmpty) return;
    await _patch(
        '$_rest/orders?id=in.(${ids.join(',')})',
        {'status': 'completed', 'completed_at': _now(), 'updated_at': _now()},
        jwt);
  }

  static Future<void> deleteTripOrder(
      String tripId, String orderId, String jwt) async {
    try {
      await http
          .delete(
              Uri.parse(
                  '$_rest/trip_orders?trip_id=eq.$tripId&order_id=eq.$orderId'),
              headers: _headers(jwt))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}
