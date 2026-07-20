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
        '${Config.supabaseUrl}/rest/v1/drivers?branch_user_id=eq.$userId&select=id,full_name,is_online&limit=1';
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
}
