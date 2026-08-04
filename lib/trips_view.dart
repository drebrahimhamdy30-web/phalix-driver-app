import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'config.dart';
import 'location.dart';

const _stLabel = {
  'pending': 'جاهز',
  'assigned': 'على رحلة',
  'picked': 'استلم',
  'delivered': 'وصّل',
  'completed': 'مكتمل',
  'postponed': 'تعذر',
  'failed': 'متعذر',
};
const _payLabel = {
  'cash': '💵 كاش',
  'visa': '💳 فيزا',
  'transfer': '🏦 تحويل',
  'deferred': '📋 آجل',
  'paid': '✅ خالص',
};
const _payOptions = ['cash', 'visa', 'transfer', 'paid'];
const _failReasons = [
  'لم أستطع التواصل مع العميل',
  'العميل ألغى الطلب',
  'العنوان غير صحيح',
  'رفض الاستلام',
];

String _money(dynamic v) {
  final n = (v is num) ? v : num.tryParse('${v ?? 0}') ?? 0;
  final s = n.toStringAsFixed(0);
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

Color _statusColor(String? s) {
  switch (s) {
    case 'assigned':
      return const Color(0xFFca8a04);
    case 'picked':
      return const Color(0xFF0891b2);
    case 'delivered':
    case 'completed':
      return const Color(0xFF16a34a);
    case 'failed':
      return const Color(0xFFdc2626);
    default:
      return Colors.grey;
  }
}

class TripsView extends StatefulWidget {
  final String driverId;
  final String branchId;
  final String jwt;
  final String driverName;
  final String mode; // 'active' = الرحلة الجارية · 'previous' = آخر 3 رحلات
  const TripsView(
      {super.key,
      required this.driverId,
      required this.branchId,
      required this.jwt,
      this.driverName = 'سائق',
      this.mode = 'active'});

  @override
  State<TripsView> createState() => TripsViewState();
}

class TripsViewState extends State<TripsView> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _trips = [];
  Map<String, List<Map<String, dynamic>>> _tripOrders = {};
  bool _canComplete = true;
  String? _selected;
  final Set<String> _expanded = {};
  final Map<String, List<Map<String, dynamic>>> _itemsCache = {};
  Map<String, dynamic>? _locSettings;
  int _lateAssigned = 10;
  int _latePicked = 30;
  int _monthTrips = 0;   // عدد رحلات الشهر الحالي (لشاشة الرحلات السابقة)
  int _monthOrders = 0;  // عدد طلبات الشهر الحالي
  bool _showStats = false;
  bool _showOrderRating = false;
  bool _showTripRating = false;
  List<Map<String, dynamic>> _reviewFlags = [];

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    load();
    // تحديث العدّادات كل دقيقة (بدون إعادة تحميل من الشبكة)
    _tick = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> load({bool background = false}) async {
    if (!mounted) return;
    if (!background) setState(() => _loading = true);
    // اللوحة وإعدادات الموقع مستقلين → بالتوازي بدل بالتسلسل (تحميل أسرع)
    final boardFut =
        Api.loadBoard(widget.driverId, widget.branchId, widget.jwt);
    final locFut = _locSettings == null
        ? Api.getLocationSettings(widget.branchId, widget.jwt)
        : null;
    final board = await boardFut;
    if (locFut != null) _locSettings = await locFut;
    _lateAssigned = board['lateAssigned'] is int ? board['lateAssigned'] : 10;
    _latePicked = board['latePicked'] is int ? board['latePicked'] : 30;
    _showStats = board['showStats'] == true;
    _showOrderRating = board['showOrderRating'] == true;
    _showTripRating = board['showTripRating'] == true;
    final trips = (board['trips'] as List).cast<Map<String, dynamic>>();
    // تنبيهات الرحلة السابقة غير المقفولة على نظام الصيدلية (للرحلة الجارية)
    final activeTrip = trips
        .where((t) => ['active', 'pending_complete'].contains(t['status']))
        .toList();
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _tripOrders = (board['tripOrders'] as Map).map((k, v) =>
          MapEntry('$k', (v as List).cast<Map<String, dynamic>>()));
      _canComplete = board['canComplete'] == true;
      final vis = _visibleTrips;
      if (_selected == null || !vis.any((t) => '${t['id']}' == _selected)) {
        _selected = vis.isNotEmpty ? '${vis.first['id']}' : null;
      }
      _loading = false;
    });
    // إحصائيات الشهر (رحلات/طلبات) لشاشة الرحلات السابقة — بالخلفية
    if (!_isActiveMode) {
      Api.getMonthStats(widget.driverId, widget.jwt).then((ms) {
        if (!mounted) return;
        int toInt(v) => v is int ? v : (int.tryParse('$v') ?? 0);
        setState(() {
          _monthTrips = toInt(ms['trips']);
          _monthOrders = toInt(ms['orders']);
        });
      });
    }
    // تنبيهات الرحلة السابقة على نظام الصيدلية (RPC) ثانوية → بالخلفية
    // عشان اللوحة تظهر فورًا من غير ما تستنى النداء ده
    if (activeTrip.isNotEmpty) {
      final flags =
          await Api.getReviewFlags('${activeTrip.first['id']}', widget.jwt);
      if (!mounted) return;
      setState(() => _reviewFlags = flags);
    } else if (mounted) {
      setState(() => _reviewFlags = []);
    }
  }

  // الرحلات الظاهرة حسب الوضع: الجارية فقط أو المكتملة (آخر 3)
  List<Map<String, dynamic>> get _visibleTrips {
    if (widget.mode == 'previous') {
      return _trips.where((t) => t['status'] == 'completed').toList();
    }
    return _trips
        .where((t) =>
            ['active', 'pending_complete'].contains(t['status']) ||
            '${t['id']}' == 'direct')
        .toList();
  }

  bool get _isActiveMode => widget.mode != 'previous';

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {}
    await load(background: true);
    if (mounted) setState(() => _busy = false);
  }

  // استلام طلب واحد مع فحص موقع الصيدلية
  Future<void> _pickupOne(String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _locSettings ??=
          await Api.getLocationSettings(widget.branchId, widget.jwt);
      final res = await checkPickupLocation(_locSettings);
      _reportLocCheck(res);
      if (!res.ok) {
        // بره النطاق أو الموقع غير متاح → امنع الاستلام تمامًا
        if (mounted) await showLocBlockDialog(context, res, 'تستلم الطلب');
      } else {
        final ord = _findOrder(id);
        if (ord != null && _hasBalance(ord) && mounted) {
          await _showBalanceNotice([ord]);
        }
        await Api.pickupOrder(id, widget.jwt);
        unawaited(Api.logOrder(id, 'order_picked', _buildPickupLog(res),
            widget.driverId, widget.driverName, widget.jwt));
      }
    } catch (_) {}
    await load(background: true);
    if (mounted) setState(() => _busy = false);
  }

  void _reportLocCheck(LocResult res) {
    Api.debug('pickup_loc_check', {
      'driver_id': widget.driverId,
      'ok': res.ok,
      'noLoc': res.noLoc,
      'dist': res.distance,
      'has_settings': _locSettings != null,
      'enabled': _locSettings?['location_check_enabled'],
      'radius': _locSettings?['pickup_radius_meters'],
    });
  }

  // استلام كل الطلبات مع فحص واحد للموقع
  Future<void> _pickupAll(List<String> ids) async {
    if (_busy || ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      _locSettings ??=
          await Api.getLocationSettings(widget.branchId, widget.jwt);
      final res = await checkPickupLocation(_locSettings);
      _reportLocCheck(res);
      if (!res.ok) {
        // بره النطاق أو الموقع غير متاح → امنع الاستلام تمامًا
        if (mounted) await showLocBlockDialog(context, res, 'تستلم الطلبات');
      } else {
        final withBal = ids
            .map(_findOrder)
            .whereType<Map<String, dynamic>>()
            .where(_hasBalance)
            .toList();
        if (withBal.isNotEmpty && mounted) await _showBalanceNotice(withBal);
        await Api.pickupAll(ids, widget.jwt);
        final log = _buildPickupLog(res, bulk: true);
        for (final id in ids) {
          unawaited(Api.logOrder(id, 'order_picked', log, widget.driverId,
              widget.driverName, widget.jwt));
        }
      }
    } catch (_) {}
    await load(background: true);
    if (mounted) setState(() => _busy = false);
  }

  Map<String, dynamic> _buildPickupLog(LocResult res, {bool bulk = false}) {
    final m = <String, dynamic>{};
    if (bulk) m['bulk'] = true;
    if (res.distance != null) m['distance_m'] = res.distance;
    if (res.lat != null) {
      m['pickup_lat'] = res.lat;
      m['pickup_lng'] = res.lng;
    }
    if (res.acc != null) m['gps_accuracy_m'] = res.acc!.round();
    if (!res.ok) {
      m['pickup_violation'] = true;
      if (res.noLoc) m['no_location'] = true;
    }
    return m;
  }


  // يدوّر على بيانات الطلب بالـid جوه طلبات الرحلات المحمّلة
  Map<String, dynamic>? _findOrder(String id) {
    for (final list in _tripOrders.values) {
      for (final o in list) {
        if ('${o['id']}' == id) return o;
      }
    }
    return null;
  }

  num _balOf(Map<String, dynamic> o) =>
      num.tryParse('${o['current_customer_balance'] ?? 0}') ?? 0;
  // يظهر التنبيه لو |الرصيد| ≥ 3ج (مستحق أو رصيد للعميل)
  bool _hasBalance(Map<String, dynamic> o) => _balOf(o).abs() >= 3;
  String _fmtBal(num n) {
    final v = n.abs();
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);
  }

  // تنبيه الرصيد السابق وقت الاستلام — يطلب الرجوع للصيدلية لإضافته على الريسيت
  Future<void> _showBalanceNotice(List<Map<String, dynamic>> withBal) async {
    if (withBal.isEmpty) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ رصيد سابق على العميل'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'برجاء الرجوع للصيدلية لإضافة رصيد العميل على ريسيت الطلب الحالي.',
                style: TextStyle(height: 1.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ...withBal.map((o) {
              final b = _balOf(o);
              final owes = b > 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: owes ? const Color(0xFFFEE2E2) : const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                          child: Text(
                              '${o['customer_name'] ?? o['cust_name'] ?? '—'}',
                              style: const TextStyle(fontWeight: FontWeight.w700))),
                      const SizedBox(width: 8),
                      Text(
                          owes
                              ? '${_fmtBal(b)} ج مستحق'
                              : '${_fmtBal(b)} ج للعميل',
                          style: TextStyle(
                              color: owes
                                  ? const Color(0xFFB91C1C)
                                  : const Color(0xFF0E7490),
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('فهمت')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final vis = _visibleTrips;
    if (vis.isEmpty) {
      return RefreshIndicator(
        onRefresh: load,
        child: ListView(children: [
          if (!_isActiveMode) _monthStatsBar(),
          const SizedBox(height: 120),
          _isActiveMode
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('✅', style: TextStyle(fontSize: 44)),
                      SizedBox(height: 8),
                      Text('تم إنهاء الرحلة',
                          style: TextStyle(
                              color: Color(0xFF15803d),
                              fontSize: 18,
                              fontWeight: FontWeight.w800)),
                      SizedBox(height: 4),
                      Text('جاهز لاستلام رحلات جديدة — في انتظار الطلبات',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Color(0xFF166534), fontSize: 13)),
                    ]),
                  ),
                )
              : const Center(
                  child: Text('📋 لا توجد رحلات سابقة',
                      style: TextStyle(color: Colors.grey, fontSize: 16))),
        ]),
      );
    }
    final trip = vis.firstWhere((t) => '${t['id']}' == _selected,
        orElse: () => vis.first);
    final orders = _tripOrders['${trip['id']}'] ?? [];
    // الطلبات اللي اتوصّلت تنزل تحت، والباقي فوق (مع الحفاظ على ترتيبهم)
    bool _isDone(o) => ['delivered', 'completed'].contains('${o['status']}');
    final displayOrders = [
      ...orders.where((o) => !_isDone(o)),
      ...orders.where((o) => _isDone(o)),
    ];
    return Column(
      children: [
        if (!_isActiveMode) _monthStatsBar(),
        if (_isActiveMode && _showStats) _statsBar(),
        if (_isActiveMode && _reviewFlags.isNotEmpty) _reviewBanner(),
        if (vis.length > 1) _tabs(),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _tripActions(trip, orders),
                ...displayOrders.map((o) => _orderCard(o)),
                _summary(trip, orders),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // بانر طلبات الرحلة السابقة غير المقفولة على نظام الصيدلية
  Widget _reviewBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFfef2f2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFfecaca)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('⚠️ طلبات من رحلتك السابقة لم تُغلق على نظام الصيدلية',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Color(0xFFb91c1c))),
          const SizedBox(height: 6),
          ..._reviewFlags.map((f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '#${f['bill_no'] ?? '—'} · ${f['customer_name'] ?? '—'}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text('${_money(f['amount'])} ج',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    Text('${f['erp_status'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFb45309))),
                  ],
                ),
              )),
          const SizedBox(height: 4),
          const Text('راجع الصيدلية لإغلاق هذه الطلبات',
              style: TextStyle(fontSize: 11, color: Color(0xFF9ca3af))),
        ],
      ),
    );
  }

  // شريط إحصائيات اليوم
  Widget _statsBar() {
    final all = _tripOrders.values.expand((e) => e).toList();
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final assigned = all.where((o) => o['status'] == 'assigned').length;
    final picked = all.where((o) => o['status'] == 'picked').length;
    final delivered = all.where((o) {
      if (!['delivered', 'completed'].contains(o['status'])) return false;
      final d = DateTime.tryParse('${o['delivered_at'] ?? o['created_at']}')
          ?.toLocal();
      return d != null && !d.isBefore(midnight);
    }).toList();
    num cash = 0;
    for (final o in delivered) {
      if (o['payment_method'] == 'cash') {
        cash += _settleAmount(o);
      }
    }
    Widget cell(String label, String value, Color c) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16, color: c)),
              Text(label,
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFe5e7eb)),
      ),
      child: Row(
        children: [
          cell('على رحلة', '$assigned', const Color(0xFFca8a04)),
          cell('استلمت', '$picked', const Color(0xFF0891b2)),
          cell('وصّلت اليوم', '${delivered.length}', const Color(0xFF16a34a)),
          cell('كاش اليوم', _money(cash), AppTheme.primary),
        ],
      ),
    );
  }

  // المبلغ المعتمد للتسوية: لو الكاشير أقرّ مبلغ الطيار = المحصّل، وإلا = قيمة الفاتورة
  num _settleAmount(Map<String, dynamic> o) {
    if (o['collected_approved'] == true && o['collected_amount'] is num) {
      return o['collected_amount'] as num;
    }
    return o['total_bill_net'] is num ? o['total_bill_net'] as num : 0;
  }

  int _dm(dynamic from, [dynamic to]) {
    final f = DateTime.tryParse('$from');
    if (f == null) return 0;
    final t = to != null ? DateTime.tryParse('$to') : DateTime.now().toUtc();
    if (t == null) return 0;
    return t.difference(f).inMinutes;
  }

  String _fmDur(int mins) {
    if (mins < 0) mins = 0;
    if (mins < 60) return '$mins د';
    return '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}';
  }

  bool _isLate(Map<String, dynamic> o) {
    final st = o['status'];
    if (['completed', 'delivered'].contains(st)) return false;
    final base = o['bill_date'] ?? o['created_at'];
    if (st == 'assigned') {
      return _dm(o['assigned_at'] ?? base) > _lateAssigned;
    }
    if (st == 'picked') {
      return _dm(o['picked_at'] ?? base) > _latePicked;
    }
    return false;
  }

  Widget _timerChip(String label, String value, Color c) => Container(
        margin: const EdgeInsets.only(left: 6, top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: c.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8)),
        child: Text('$label $value',
            style: TextStyle(
                fontSize: 11, color: c, fontWeight: FontWeight.w600)),
      );

  // شارة تقييم الطلب (تظهر فقط لو الإعداد مفعّل)
  Widget _ratingChip(Map<String, dynamic> o) {
    final r = '${o['perf_rating']}';
    final c = r == 'ممتاز'
        ? const Color(0xFF16a34a)
        : (r == 'متأخر' ? const Color(0xFFdc2626) : const Color(0xFFca8a04));
    final fa = o['actual_minutes'];
    final ex = o['expected_minutes'];
    final extra = (fa != null && ex != null) ? ' ($fa/$ex د)' : '';
    return Container(
      margin: const EdgeInsets.only(left: 6, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
      child: Text('⭐ $r$extra',
          style:
              TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700)),
    );
  }

  List<Widget> _orderTimers(Map<String, dynamic> o) {
    final chips = <Widget>[];
    final base = o['bill_date'] ?? o['created_at'];
    chips.add(_timerChip('إنشاء منذ', _fmDur(_dm(base)), Colors.grey));
    if (o['assigned_at'] != null) {
      final sinceAssign = o['picked_at'] != null
          ? _dm(o['assigned_at'], o['picked_at'])
          : _dm(o['assigned_at']);
      final late = o['picked_at'] == null && sinceAssign > _lateAssigned;
      chips.add(_timerChip(o['picked_at'] != null ? 'على رحلة' : 'على رحلة منذ',
          _fmDur(sinceAssign),
          late ? const Color(0xFFdc2626) : const Color(0xFFca8a04)));
    }
    if (o['picked_at'] != null) {
      final sincePick = o['delivered_at'] != null
          ? _dm(o['picked_at'], o['delivered_at'])
          : _dm(o['picked_at']);
      final late = o['delivered_at'] == null &&
          o['status'] != 'failed' &&
          sincePick > _latePicked;
      chips.add(_timerChip(o['delivered_at'] != null ? 'استلم' : 'استلم منذ',
          _fmDur(sincePick),
          late ? const Color(0xFFdc2626) : const Color(0xFF0891b2)));
    }
    if (o['status'] == 'failed') {
      chips.add(_timerChip(
          'تعذر منذ', _fmDur(_dm(o['updated_at'])), const Color(0xFFdc2626)));
    }
    if (o['delivered_at'] != null) {
      chips.add(_timerChip('وصّل منذ', _fmDur(_dm(o['delivered_at'])),
          const Color(0xFF16a34a)));
    }
    return chips;
  }

  Widget _tabs() {
    final vis = _visibleTrips;
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: vis.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final t = vis[i];
          final id = '${t['id']}';
          final isActive =
              ['active', 'pending_complete'].contains(t['status']);
          final count = (_tripOrders[id] ?? []).length;
          final sel = id == _selected;
          final label = isActive ? 'الرحلة الجارية' : 'رحلة ${i + 1}';
          return InkWell(
            onTap: () => setState(() => _selected = id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? AppTheme.primary : const Color(0xFFe5e7eb),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('$label ($count)',
                  style: TextStyle(
                      color: sel ? Colors.white : const Color(0xFF374151),
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          );
        },
      ),
    );
  }

  // شريط إجمالي الشهر الحالي (رحلات + طلبات) — يظهر في شاشة الرحلات السابقة
  Widget _monthStatsBar() {
    Widget tile(String label, int val, Color c, IconData ic) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: c.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.withOpacity(0.25)),
            ),
            child: Column(children: [
              Icon(ic, color: c, size: 20),
              const SizedBox(height: 3),
              Text('$val',
                  style: TextStyle(
                      color: c, fontSize: 20, fontWeight: FontWeight.w800)),
              Text(label,
                  style: const TextStyle(
                      color: Color(0xFF64748b),
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      child: Column(children: [
        const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 6, bottom: 6),
            child: Text('📊 إجمالي الشهر الحالي',
                style: TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 13,
                    fontWeight: FontWeight.w800)),
          ),
        ),
        Row(children: [
          tile('رحلات', _monthTrips, const Color(0xFF2563eb),
              Icons.local_shipping),
          tile('طلبات', _monthOrders, const Color(0xFF16a34a),
              Icons.inventory_2),
        ]),
      ]),
    );
  }

  Widget _tripActions(Map<String, dynamic> trip, List<Map<String, dynamic>> orders) {
    final isActive = ['active', 'pending_complete'].contains(trip['status']);
    if (!isActive) return const SizedBox.shrink();
    final assigned = orders.where((o) => o['status'] == 'assigned').toList();
    final blocking =
        orders.where((o) => ['assigned', 'picked'].contains(o['status'])).length;
    final pending = trip['status'] == 'pending_complete';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          if (assigned.isNotEmpty)
            _bigBtn('▶️ استلمت الكل (${assigned.length})',
                const Color(0xFF0891b2),
                () => _pickupAll(
                    assigned.map((o) => '${o['id']}').toList())),
          if (pending)
            _bigBtn('⏳ بانتظار موافقة الإدارة — إلغاء الطلب',
                const Color(0xFFa16207),
                () => _run(() async {
                      await Api.updateTrip(
                          '${trip['id']}', {'status': 'active'}, widget.jwt);
                      await Api.logTrip('${trip['id']}', 'complete_cancelled',
                          {'by': 'driver'}, widget.driverId, widget.driverName,
                          widget.jwt);
                    }))
          else
            _bigBtn(
                blocking > 0
                    ? '⏳ ينتظر $blocking طلب'
                    : (_canComplete ? '🏁 إنهاء الرحلة' : '🏁 طلب إنهاء الرحلة'),
                blocking > 0 ? const Color(0xFF9ca3af) : const Color(0xFF16a34a),
                blocking > 0 ? null : () => _completeTrip(trip, orders)),
        ],
      ),
    );
  }

  Widget _bigBtn(String text, Color color, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
          style: ElevatedButton.styleFrom(
              backgroundColor: color, foregroundColor: Colors.white),
          child: Text(text,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final id = '${o['id']}';
    final status = '${o['status']}';
    final open = _expanded.contains(id);
    // نعرض كود العميل بدل رقم الفاتورة
    final ccRaw = '${o['cust_code'] ?? ''}'.trim();
    final custCode = (ccRaw.isEmpty || ccRaw == 'null') ? '—' : ccRaw;
    final name = o['customer_name'] ?? '—';
    final late = _isLate(o);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: late
            ? const BorderSide(color: Color(0xFFdc2626), width: 1.8)
            : const BorderSide(color: Color(0xFFcbd5e1), width: 1.2),
      ),
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(
                () => open ? _expanded.remove(id) : _expanded.add(id)),
            title: Row(
              children: [
                // السطر الأول: اسم العميل كامل
                Expanded(
                    child: Text('$name',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15))),
                if (late)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('⏰ متأخر',
                        style: TextStyle(
                            color: Color(0xFFdc2626),
                            fontWeight: FontWeight.bold,
                            fontSize: 11)),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: _statusColor(status).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(_stLabel[status] ?? status,
                      style: TextStyle(
                          color: _statusColor(status),
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // السطر الثاني: العنوان
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('📍 ', style: TextStyle(fontSize: 12.5)),
                      Expanded(
                          child: Text('${o['customer_address'] ?? '—'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5, color: Color(0xFF475569)))),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('🆔 كود: $custCode',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF64748b))),
                      ..._orderTimers(o),
                      if (_showOrderRating && o['perf_rating'] != null)
                        _ratingChip(o),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (open) _orderDetail(o),
        ],
      ),
    );
  }

  Widget _orderDetail(Map<String, dynamic> o) {
    final status = '${o['status']}';
    final pm = o['payment_method'];
    final region = o['cust_region'];
    final items = o['count_of_items'];
    final collected = o['collected_amount'];
    final staffNotes = o['staff_notes'];
    final failReason = o['postpone_reason'];
    final urgent = '${o['notes'] ?? ''}'.contains('🚨');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (region != null && '$region'.isNotEmpty) _tag('$region', const Color(0xFF6366f1)),
            _tag(pm != null ? (_payLabel[pm] ?? '$pm') : '💵 كاش',
                const Color(0xFF0891b2)),
            if (items != null) _tag('$items صنف', Colors.grey),
          ]),
          const SizedBox(height: 8),
          Text('${_money(o['total_bill_net'])} ج.م',
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primary)),
          if (collected != null && (collected is num ? collected : 0) != 0)
            Builder(builder: (_) {
              final c = collected is num ? collected : 0;
              final bill =
                  o['total_bill_net'] is num ? o['total_bill_net'] as num : 0;
              final differs = bill > 0 && c != bill;
              final approved = o['collected_approved'] == true;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('✓ محصّل: ${_money(collected)} ج',
                        style: const TextStyle(
                            color: Color(0xFF16a34a),
                            fontWeight: FontWeight.w600)),
                    if (differs)
                      Text(
                          approved
                              ? '✓ الكاشير أقرّ هذا المبلغ (يُحسب عليه)'
                              : '⏳ مختلف عن الفاتورة — بانتظار إقرار الكاشير (يُحسب على الفاتورة حاليًا)',
                          style: TextStyle(
                              fontSize: 11,
                              color: approved
                                  ? const Color(0xFF16a34a)
                                  : const Color(0xFF92400e))),
                  ],
                ),
              );
            }),
          _orderItemsBtn(o),
          if (urgent)
            _note('🚨 طلب عاجل', const Color(0xFFdc2626)),
          if (staffNotes != null && '$staffNotes'.isNotEmpty)
            _note('💼 $staffNotes', const Color(0xFF7c3aed)),
          if (status == 'failed' && failReason != null)
            _note('⚠️ تعذر: $failReason', const Color(0xFFdc2626)),
          _phoneButtons(o),
          const SizedBox(height: 10),
          _orderActions(o),
        ],
      ),
    );
  }

  // قائمة أصناف الطلب (من عمود items — مصفوفة {name, qty})
  // زر عرض أصناف الطلب — يجلبها من ويبهوك n8n ويعرضها في نافذة منبثقة
  Widget _orderItemsBtn(Map<String, dynamic> o) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () => _showItems(o),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.appBar,
            side: const BorderSide(color: AppTheme.appBar),
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('🧾 عرض الأصناف',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        ),
      ),
    );
  }

  void _showItems(Map<String, dynamic> o) {
    final id = '${o['id']}';
    final billNo = '${o['bill_no'] ?? ''}'.trim();
    final branchId = '${o['branch_id'] ?? ''}';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _itemsCache.containsKey(id)
              ? Future.value(_itemsCache[id])
              : Api.getBillItems(billNo, branchId)
                  .then((v) => _itemsCache[id] = v),
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text('❌ تعذّر جلب الأصناف\n${snap.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFdc2626))),
              );
            }
            final items = snap.data ?? [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('🧾 أصناف الفاتورة${billNo.isNotEmpty ? ' #$billNo' : ''}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: AppTheme.appBar)),
                    Text('${items.length} صنف',
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 10),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: Text('لا توجد أصناف في هذه الفاتورة',
                            style: TextStyle(color: Colors.grey))),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                          children:
                              items.map((it) => _itemRow(it)).toList()),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final q = it['qty'];
    final unit = '${it['unit'] ?? ''}';
    final hasQty = q != null && '$q'.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFeef2f7)))),
      child: Row(
        children: [
          Expanded(
            child: Text(
                '${it['name'] ?? '—'}${unit.isNotEmpty ? ' · $unit' : ''}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          if (hasQty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: AppTheme.appBar,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('×$q',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  // أرقام موبايل العميل كأزرار اتصال (تدعم أكتر من رقم مفصولين بفاصلة)
  Widget _phoneButtons(Map<String, dynamic> o) {
    final raw = '${o['customer_phone'] ?? ''}';
    if (raw.isEmpty) return const SizedBox.shrink();
    final nums = raw
        .split(RegExp(r'[,،]'))
        .map((s) => s.replaceAll(RegExp(r'[^0-9+]'), ''))
        .where((s) => s.length >= 5)
        .toList();
    if (nums.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: nums
            .expand((n) => [
                  // زر الاتصال
                  InkWell(
                    onTap: () => launchUrl(Uri.parse('tel:$n'),
                        mode: LaunchMode.externalApplication),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFdcfce7),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFbbf7d0)),
                      ),
                      child: Text('📞 اتصال: $n',
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                              color: Color(0xFF15803d),
                              fontWeight: FontWeight.w800,
                              fontSize: 13)),
                    ),
                  ),
                  // زر واتساب
                  InkWell(
                    onTap: () => launchUrl(
                        Uri.parse('https://wa.me/${_waNumber(n)}'),
                        mode: LaunchMode.externalApplication),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF25D366),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('🟢 واتساب',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 13)),
                    ),
                  ),
                ])
            .toList(),
      ),
    );
  }

  // تحويل الرقم لصيغة دولية لواتساب (مصر): 01xxxxxxxxx → 201xxxxxxxxx
  String _waNumber(String n) {
    var x = n.replaceAll(RegExp(r'[^0-9]'), '');
    if (x.startsWith('00')) x = x.substring(2);
    if (x.startsWith('20')) return x;
    if (x.startsWith('0')) return '20${x.substring(1)}';
    if (x.length == 10 && x.startsWith('1')) return '20$x';
    return x;
  }

  Widget _orderActions(Map<String, dynamic> o) {
    final id = '${o['id']}';
    final status = '${o['status']}';
    final btns = <Widget>[];
    if (status == 'assigned') {
      // مرحلة الاستلام: استلام فقط — التعذّر بيبقى بعد ما يروح للعميل
      btns.add(_smallBtn('▶️ استلمت', const Color(0xFF0891b2),
          () => _pickupOne(id)));
    } else if (status == 'picked') {
      btns.add(_smallBtn('✅ وصّلت', const Color(0xFF16a34a),
          () => _openDeliver(o)));
      btns.add(_smallBtn('⚠️ تعذر', const Color(0xFFdc2626),
          () => _openFail(o)));
    } else if (status == 'failed') {
      btns.add(_smallBtn('🔄 حاول تاني', const Color(0xFF16a34a),
          () => _run(() async {
                await Api.retryOrder(id, widget.jwt);
                unawaited(Api.logOrder(id, 'order_picked', {'retry': true},
                    widget.driverId, widget.driverName, widget.jwt));
              })));
    }
    if (btns.isEmpty) return const SizedBox.shrink();
    return Row(
        children: btns
            .map((b) => Expanded(
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: b)))
            .toList());
  }

  Widget _smallBtn(String t, Color c, VoidCallback onTap) => SizedBox(
        height: 42,
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
          style: ElevatedButton.styleFrom(
              backgroundColor: c,
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero),
          child: Text(t,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      );

  Widget _tag(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
        child: Text(t,
            style: TextStyle(
                color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Widget _note(String t, Color c) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
        child: Text(t, style: TextStyle(color: c, fontSize: 13)),
      );

  Widget _summary(Map<String, dynamic> trip, List<Map<String, dynamic>> orders) {
    num total = 0, cash = 0;
    int done = 0;
    num sumA = 0, sumE = 0, sumDist = 0;
    int rated = 0;
    for (final o in orders) {
      total += (o['total_bill_net'] is num ? o['total_bill_net'] : 0);
      final st = o['status'];
      if (['delivered', 'completed'].contains(st)) {
        done++;
        if (o['payment_method'] == 'cash') {
          cash += _settleAmount(o);
        }
      }
      if (o['perf_rating'] != null &&
          o['actual_minutes'] is num &&
          o['expected_minutes'] is num) {
        rated++;
        sumA += o['actual_minutes'] as num;
        sumE += o['expected_minutes'] as num;
      }
      if (o['distance_meters'] is num) sumDist += o['distance_meters'] as num;
    }
    final box = Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFFf8fafc),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFe5e7eb))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('إجمالي الرحلة',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text('${_money(total)} ج.م',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('إجمالي الكاش',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text('${_money(cash)} ج.م',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF16a34a))),
          ]),
          Text('$done/${orders.length} مكتمل',
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ],
      ),
    );
    if (!_showTripRating || rated == 0) return box;
    final ratio = sumE > 0 ? sumA / sumE : 1;
    final tr = ratio <= 0.90 ? 'ممتاز' : (ratio >= 1.10 ? 'متأخر' : 'جيد');
    final tc = tr == 'ممتاز'
        ? const Color(0xFF16a34a)
        : (tr == 'متأخر' ? const Color(0xFFdc2626) : const Color(0xFFca8a04));
    return Column(children: [
      box,
      Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            color: tc.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tc.withOpacity(0.4))),
        child: Row(children: [
          Icon(Icons.star, color: tc, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text('تقييم الرحلة: $tr',
                style: TextStyle(color: tc, fontWeight: FontWeight.bold)),
          ),
          Text(
              'فعلي ${sumA.toStringAsFixed(0)} / متوقع ${sumE.toStringAsFixed(0)} د'
              '${sumDist > 0 ? ' · ${(sumDist / 1000).toStringAsFixed(1)} كم' : ''}',
              style: TextStyle(fontSize: 11, color: tc)),
        ]),
      ),
    ]);
  }

  // ============ نوافذ الأزرار ============
  Future<void> _openDeliver(Map<String, dynamic> o) async {
    final id = '${o['id']}';
    String pay = '${o['payment_method'] ?? 'cash'}';
    final num billNum = (o['total_bill_net'] is num)
        ? o['total_bill_net'] as num
        : num.tryParse('${o['total_bill_net'] ?? 0}') ?? 0;
    // الرقم الافتراضي = قيمة الفاتورة
    final amtCtrl = TextEditingController(text: billNum == 0 ? '' : '$billNum');
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تأكيد التسليم'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Align(
                  alignment: Alignment.centerRight,
                  child: Text('طريقة الدفع',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: _payOptions
                    .map((p) => ChoiceChip(
                          label: Text(_payLabel[p] ?? p),
                          selected: pay == p,
                          onSelected: (_) => setD(() => pay = p),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amtCtrl,
                keyboardType: TextInputType.number,
                onChanged: (_) => setD(() {}),
                decoration: const InputDecoration(
                    labelText: 'المبلغ المحصّل', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 6),
              Builder(builder: (_) {
                final typed = num.tryParse(amtCtrl.text.trim());
                final changed = pay == 'cash' &&
                    typed != null &&
                    billNum > 0 &&
                    typed != billNum;
                return Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('قيمة الفاتورة: ${_money(billNum)} ج.م',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                      if (changed)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: const Color(0xFFfef3c7),
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: const Color(0xFFfcd34d))),
                          child: const Text(
                              '⚠️ غيّرت المبلغ عن الفاتورة — التسوية هتفضل على قيمة الفاتورة لحد ما الكاشير يقرّ الرقم ده',
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF92400e))),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                    labelText: 'ملاحظة (اختياري)',
                    border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16a34a),
                    foregroundColor: Colors.white),
                child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    if (ok == true) {
      final amt = double.tryParse(amtCtrl.text.trim()) ?? 0;
      final note = noteCtrl.text.trim();
      // موقع التسليم (لحساب زمن الطريق والأداء) — لا يمنع التسليم
      Map<String, double>? dloc = await getCurrentLatLng();
      // لو الموقع مش متاح: نبّه الطيار (تسليم بدون تقييم / تشغيل GPS وإعادة المحاولة)
      while (dloc == null && mounted) {
        final choice = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('⚠️ الموقع غير متاح'),
            content: const Text(
                'الـGPS مقفول أو إذن الموقع غير مفعّل، ولن يتم احتساب تقييم لهذا الطلب.\n\nشغّل الـGPS وحاول تاني، أو سلّم الطلب بدون تقييم.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, 'deliver'),
                  child: const Text('تسليم بدون تقييم')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, 'retry'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white),
                  child: const Text('شغّلت الـGPS — حاول تاني')),
            ],
          ),
        );
        if (choice == 'retry') {
          dloc = await getCurrentLatLng();
          continue;
        }
        break; // تسليم بدون تقييم
      }
      await _run(() async {
        await Api.deliverOrder(
            id, pay, amt, note.isEmpty ? null : note, widget.jwt,
            lat: dloc?['lat'], lng: dloc?['lng']);
        unawaited(Api.logOrder(
            id,
            'order_delivered',
            {
              'payment': pay,
              'amount': amt,
              if (dloc != null) 'delivery_lat': dloc['lat'],
              if (dloc != null) 'delivery_lng': dloc['lng'],
            },
            widget.driverId,
            widget.driverName,
            widget.jwt));
      });
    }
  }

  Future<void> _openFail(Map<String, dynamic> o) async {
    final id = '${o['id']}';
    final attempt = (o['attempt_count'] is int) ? o['attempt_count'] as int : 0;
    String? reason;
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('سبب التعذر'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ..._failReasons.map((r) => RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(r, style: const TextStyle(fontSize: 13)),
                    value: r,
                    groupValue: reason,
                    onChanged: (v) => setD(() => reason = v),
                  )),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                    labelText: 'ملاحظة (اختياري)',
                    border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
                onPressed:
                    reason == null ? null : () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFdc2626),
                    foregroundColor: Colors.white),
                child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    if (ok == true && reason != null) {
      final note = noteCtrl.text.trim();
      await _run(() async {
        await Api.failOrder(
            id, reason!, note.isEmpty ? null : note, attempt, widget.jwt);
        unawaited(Api.logOrder(id, 'order_postponed',
            {'reason': reason, 'kept_in_trip': true},
            widget.driverId, widget.driverName, widget.jwt));
      });
    }
  }

  Future<void> _completeTrip(
      Map<String, dynamic> trip, List<Map<String, dynamic>> orders) async {
    final tid = '${trip['id']}';
    final blocking =
        orders.where((o) => ['assigned', 'picked'].contains(o['status'])).length;
    if (blocking > 0) {
      _snack('لا يمكن إنهاء الرحلة — يوجد $blocking طلب لم يُوصّل أو يُسجّل تعذّره');
      return;
    }
    // فحص الموقع — لازم يكون داخل نطاق الصيدلية عشان ينهي الرحلة
    _locSettings ??= await Api.getLocationSettings(widget.branchId, widget.jwt);
    final locRes = await checkPickupLocation(_locSettings);
    _reportLocCheck(locRes);
    if (!locRes.ok) {
      if (mounted) await showLocBlockDialog(context, locRes, 'تنهي الرحلة');
      return;
    }
    // إذا كان الإنهاء يحتاج موافقة الإدارة
    if (!_canComplete && tid != 'direct') {
      await _run(() async {
        await Api.updateTrip(tid, {'status': 'pending_complete'}, widget.jwt);
        await Api.logTrip(tid, 'complete_requested', {'by': 'driver'},
            widget.driverId, widget.driverName, widget.jwt);
        unawaited(Api.triggerPrevTripCheck(widget.driverId, tid));
      });
      _snack('تم إرسال طلب إنهاء الرحلة للإدارة');
      return;
    }
    final failed =
        orders.where((o) => o['status'] == 'failed').map((o) => '${o['id']}').toList();
    final delivered = orders
        .where((o) => o['status'] == 'delivered')
        .map((o) => '${o['id']}')
        .toList();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنهاء الرحلة'),
        content: Text(failed.isNotEmpty
            ? 'يوجد ${failed.length} طلب متعذّر سيرجع للإدارة لإعادة توزيعه. إنهاء الرحلة؟'
            : 'تأكيد إنهاء الرحلة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إنهاء')),
        ],
      ),
    );
    if (confirm != true) return;
    await _run(() async {
      if (failed.isNotEmpty) {
        await Api.releaseFailed(failed, widget.jwt);
        if (tid != 'direct') {
          for (final oid in failed) {
            await Api.deleteTripOrder(tid, oid, widget.jwt);
          }
        }
        for (final oid in failed) {
          unawaited(Api.logOrder(oid, 'order_postponed',
              {'released_on_trip_complete': true},
              widget.driverId, widget.driverName, widget.jwt));
        }
      }
      await Api.completeDelivered(delivered, widget.jwt);
      if (tid != 'direct') {
        await Api.updateTrip(tid, {'status': 'completed'}, widget.jwt);
      }
      await Api.logTrip(tid, 'trip_completed',
          {'by': 'driver', 'failed_released': failed.length},
          widget.driverId, widget.driverName, widget.jwt);
      unawaited(Api.triggerPrevTripCheck(widget.driverId, tid));
    });
    _snack('✅ تم إنهاء الرحلة — جاهز لاستلام رحلات جديدة');
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }
}
