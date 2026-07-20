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
