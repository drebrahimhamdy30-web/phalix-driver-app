import 'package:supabase_flutter/supabase_flutter.dart';
import 'location.dart';

// يرد على طلب "موقع الطيار الحالي" من شاشة التوزيع.
// الإدارة بتبعت broadcast (event: request) على قناة driver-loc-<driverId>،
// والتطبيق يقرا الـ GPS مرة واحدة ويرجّع الإحداثيات فورًا (broadcast response)
// + يخزّنها في جدول driver_locations كآخر موقع معروف.
class LocationResponder {
  RealtimeChannel? _ch;
  String _driverId = '';
  bool _busy = false;

  void start(String driverId) {
    if (driverId.isEmpty) return;
    if (_ch != null && _driverId == driverId) return; // مشترك بالفعل
    stop();
    _driverId = driverId;
    final client = Supabase.instance.client;
    _ch = client.channel('driver-loc-$driverId');
    _ch!
        .onBroadcast(
          event: 'request',
          callback: (payload) {
            _respond();
          },
        )
        .subscribe();
  }

  Future<void> _respond() async {
    if (_busy) return;
    _busy = true;
    try {
      final loc = await getCurrentLatLng();
      final client = Supabase.instance.client;
      if (loc != null) {
        try {
          await client.from('driver_locations').upsert({
            'driver_id': _driverId,
            'lat': loc['lat'],
            'lng': loc['lng'],
            'acc': loc['acc'],
            'reported_at': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (_) {}
        await _ch?.sendBroadcastMessage(
          event: 'response',
          payload: {
            'ok': true,
            'lat': loc['lat'],
            'lng': loc['lng'],
            'acc': loc['acc'],
          },
        );
      } else {
        await _ch?.sendBroadcastMessage(
          event: 'response',
          payload: {'ok': false, 'reason': 'no_gps'},
        );
      }
    } catch (_) {
      await _ch?.sendBroadcastMessage(
        event: 'response',
        payload: {'ok': false, 'reason': 'error'},
      );
    } finally {
      _busy = false;
    }
  }

  void stop() {
    final ch = _ch;
    if (ch != null) {
      try {
        Supabase.instance.client.removeChannel(ch);
      } catch (_) {}
      _ch = null;
    }
    _driverId = '';
  }
}
