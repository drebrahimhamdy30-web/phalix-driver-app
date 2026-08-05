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

  // إحصائيات الشهر الحالي للطيار: عدد الرحلات + عدد الطلبات
  static Future<Map<String, dynamic>> getMonthStats(
      String driverId, String jwt) async {
    final r = await _getList(
        '$_rest/rpc/get_driver_month_stats?p_driver=$driverId', jwt);
    return r.isNotEmpty ? r.first : {'trips': 0, 'orders': 0};
  }

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

  // أعمدة الطلب المطلوبة فقط (بدل select=* الذي يجلب عمود source_data الضخم غير المستخدم — توفير نت)
  static const String _orderCols =
      'id,bill_no,cust_code,customer_name,cust_name,customer_address,cust_address,'
      'customer_phone,cust_phone,cust_region,total_bill_net,status,payment_method,'
      'count_of_items,collected_amount,collected_approved,notes,staff_notes,driver_notes,'
      'assigned_at,picked_at,delivered_at,created_at,updated_at,bill_date,last_activated_at,'
      'perf_rating,actual_minutes,expected_minutes,distance_meters,current_customer_balance,'
      'postpone_reason,attempt_count,driver_id,deliveryman,branch_id';

  // تحميل لوحة الطيار: الرحلة الجارية + آخر 3 رحلات + طلباتها (مُحسّن: نداءات أقل)
  static Future<Map<String, dynamic>> loadBoard(
      String driverId, String? branchId, String jwt) async {
    // إعدادات الفرع مستقلة عن الرحلات → نجيبها بالتوازي لتوفير لفة شبكة
    final settingsFut = (branchId != null && branchId.isNotEmpty)
        ? _getList(
            '$_rest/dispatch_settings?branch_id=eq.$branchId&select=driver_can_complete_trip,max_break_minutes,max_assigned_minutes,max_picked_minutes,driver_show_stats,driver_show_order_rating,driver_show_trip_rating',
            jwt)
        : Future<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
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
            '$_rest/orders?id=in.(${allIds.join(',')})&select=$_orderCols', jwt);
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
          '$_rest/orders?driver_id=eq.$driverId&status=in.(assigned,picked)&select=$_orderCols',
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
    int lateAssigned = 10;
    int latePicked = 30;
    bool showStats = false;
    bool showOrderRating = false;
    bool showTripRating = false;
    final s = await settingsFut;
    if (s.isNotEmpty) {
      canComplete = s.first['driver_can_complete_trip'] != false;
      final mb = s.first['max_break_minutes'];
      if (mb is num) maxBreak = mb.toInt();
      final ma = s.first['max_assigned_minutes'];
      if (ma is num) lateAssigned = ma.toInt();
      final mp = s.first['max_picked_minutes'];
      if (mp is num) latePicked = mp.toInt();
      showStats = s.first['driver_show_stats'] == true;
      showOrderRating = s.first['driver_show_order_rating'] == true;
      showTripRating = s.first['driver_show_trip_rating'] == true;
    }

    return {
      'trips': board,
      'tripOrders': tripOrders,
      'canComplete': canComplete,
      'maxBreak': maxBreak,
      'lateAssigned': lateAssigned,
      'latePicked': latePicked,
      'showStats': showStats,
      'showOrderRating': showOrderRating,
      'showTripRating': showTripRating,
    };
  }

  // ترتيب/دور الطيار في طابور التوزيع — بين المتاحين فقط (اللي مش خارجين برحلة)
  // بنفس منطق التوزيع الفعلي على السيرفر: الأقل طلبات / الأطول فراغًا (آخر إنهاء رحلة)
  static Future<Map<String, dynamic>?> getRank(
      String driverId, String branchId, String jwt) async {
    if (branchId.isEmpty || driverId.isEmpty) return null;
    try {
      // الحساب اتنقل للسيرفر (RPC) — بدل تحميل مئات صفوف الحضور والطلبات
      final res = await _getList(
          '$_rest/rpc/get_driver_rank?p_driver=$driverId&p_branch=$branchId',
          jwt);
      if (res.isEmpty) return null;
      final r = res.first;
      if (r['rank'] == null) return null; // مش حاضر
      return {'rank': r['rank'], 'total': r['total']};
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

  // جلب أصناف الفاتورة من ويبهوك n8n (بناءً على رقم الفاتورة + الفرع)
  static Future<List<Map<String, dynamic>>> getBillItems(
      String billNo, String branchId) async {
    if (billNo.trim().isEmpty) return [];
    final res = await http.post(
      Uri.parse('https://agent.ebrahimhamdy.com/webhook/sales_item'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'branch_id': branchId, 'bill_no': billNo}),
    );
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final data = jsonDecode(res.body);
    final root = data is List ? (data.isNotEmpty ? data[0] : {}) : data;
    final bills = (root is Map ? root['Data'] : null);
    final list = bills is List ? bills : [];
    Map bill = {};
    for (final b in list) {
      if (b is Map && '${b['bill_no']}' == billNo) {
        bill = b;
        break;
      }
    }
    if (bill.isEmpty && list.isNotEmpty && list.first is Map) {
      bill = list.first as Map;
    }
    final raw = (bill['Items'] is List) ? bill['Items'] as List : [];
    return raw.map<Map<String, dynamic>>((it) {
      final m = it is Map ? it : {};
      return {
        'name': (m['itm_name_ar'] ?? m['itm_name_en'] ?? '').toString().trim(),
        'qty': m['itm_qty'],
        'unit': m['unit_name'] ?? '',
        'price': m['unit_price'],
      };
    }).toList();
  }

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

  // آخر نسخة منشورة للتطبيق (لرسالة التحديث)
  static Future<Map<String, dynamic>?> getLatestVersion() async {
    try {
      final s = await _getList(
          '$_rest/driver_app_version?id=eq.1&select=version_code,version_name,apk_url,force_update,notes',
          Config.supabaseAnonKey);
      return s.isEmpty ? null : s.first;
    } catch (_) {
      return null;
    }
  }

  // تسجيل تشخيصي (يذهب إلى driver_debug عبر driver-mark)
  static Future<void> debug(String event, Map<String, dynamic> data) async {
    try {
      await http
          .post(Uri.parse(Config.markUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'event': event, ...data}))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
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

  // تسجيل لوج للرحلة (trip_logs)
  static Future<void> logTrip(String tripId, String event,
      Map<String, dynamic> details, String driverId, String driverName,
      String jwt) async {
    if (tripId.isEmpty || tripId == 'direct') return;
    try {
      await http
          .post(
            Uri.parse('$_rest/trip_logs'),
            headers: {..._headers(jwt), 'Prefer': 'return=minimal'},
            body: jsonEncode({
              'trip_id': tripId,
              'event': event,
              'details': details,
              'user_id': driverId,
              'user_name': driverName,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // طلبات الرحلة السابقة غير المقفولة على نظام الصيدلية (B Connect)
  static Future<List<Map<String, dynamic>>> getReviewFlags(
      String tripId, String jwt) async {
    if (tripId.isEmpty || tripId == 'direct') return [];
    try {
      final res = await http
          .post(
            Uri.parse('$_rest/rpc/get_trip_review_flags'),
            headers: _headers(jwt),
            body: jsonEncode({'p_trip_id': tripId}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) {
          return data.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  // يشغّل فحص الرحلة السابقة على نظام الصيدلية عبر n8n (fire-and-forget)
  static Future<void> triggerPrevTripCheck(
      String driverId, String tripId) async {
    if (driverId.isEmpty || tripId.isEmpty || tripId == 'direct') return;
    try {
      await http
          .post(
            Uri.parse(Config.checkPrevTripUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'driver_id': driverId,
              'current_trip_id': tripId,
            }),
          )
          .timeout(const Duration(seconds: 8));
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
          String? note, String jwt,
          {double? lat, double? lng}) =>
      _patch(
          '$_rest/orders?id=eq.$id',
          {
            'status': 'delivered',
            'payment_method': pay,
            'collected_amount': amount,
            'driver_notes': note,
            'delivered_at': _now(),
            'updated_at': _now(),
            if (lat != null) 'delivery_lat': lat,
            if (lng != null) 'delivery_lng': lng,
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
