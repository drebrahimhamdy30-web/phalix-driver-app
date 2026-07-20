import 'package:flutter/material.dart';
import 'api.dart';

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
};
const _payOptions = ['cash', 'visa', 'transfer', 'deferred'];
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
  const TripsView(
      {super.key,
      required this.driverId,
      required this.branchId,
      required this.jwt});

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

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final board =
        await Api.loadBoard(widget.driverId, widget.branchId, widget.jwt);
    if (!mounted) return;
    setState(() {
      _trips = (board['trips'] as List).cast<Map<String, dynamic>>();
      _tripOrders = (board['tripOrders'] as Map).map((k, v) =>
          MapEntry('$k', (v as List).cast<Map<String, dynamic>>()));
      _canComplete = board['canComplete'] == true;
      if (_selected == null || !_trips.any((t) => '${t['id']}' == _selected)) {
        _selected = _trips.isNotEmpty ? '${_trips.first['id']}' : null;
      }
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {}
    await load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: load,
        child: ListView(children: const [
          SizedBox(height: 160),
          Center(
              child: Text('🚗 لا توجد رحلات حالياً',
                  style: TextStyle(color: Colors.grey, fontSize: 16))),
        ]),
      );
    }
    final trip = _trips.firstWhere((t) => '${t['id']}' == _selected,
        orElse: () => _trips.first);
    final orders = _tripOrders['${trip['id']}'] ?? [];
    return Column(
      children: [
        _tabs(),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _tripActions(trip, orders),
                ...orders.map((o) => _orderCard(o)),
                _summary(trip, orders),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabs() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: _trips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final t = _trips[i];
          final id = '${t['id']}';
          final isActive =
              ['active', 'pending_complete'].contains(t['status']);
          final count = (_tripOrders[id] ?? []).length;
          final sel = id == _selected;
          final label = isActive ? 'الرحلة الجارية' : 'رحلة ${i}';
          return InkWell(
            onTap: () => setState(() => _selected = id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? const Color(0xFF1a56db) : const Color(0xFFe5e7eb),
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
                () => _run(() => Api.pickupAll(
                    assigned.map((o) => '${o['id']}').toList(), widget.jwt))),
          if (pending)
            _bigBtn('⏳ بانتظار موافقة الإدارة — إلغاء الطلب',
                const Color(0xFFa16207),
                () => _run(() => Api.updateTrip(
                    '${trip['id']}', {'status': 'active'}, widget.jwt)))
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
    final bill = o['bill_no'] ?? id.substring(0, id.length >= 8 ? 8 : id.length);
    final name = o['customer_name'] ?? '—';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(
                () => open ? _expanded.remove(id) : _expanded.add(id)),
            title: Row(
              children: [
                Text('#$bill',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('$name',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
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
          Row(children: [
            const Text('📍 '),
            Expanded(
                child: Text('${o['customer_address'] ?? '—'}',
                    style: const TextStyle(fontSize: 13))),
          ]),
          const SizedBox(height: 6),
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
                  color: Color(0xFF1a56db))),
          if (collected != null && (collected is num ? collected : 0) != 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('✓ محصّل: ${_money(collected)} ج',
                  style: const TextStyle(
                      color: Color(0xFF16a34a), fontWeight: FontWeight.w600)),
            ),
          if (urgent)
            _note('🚨 طلب عاجل', const Color(0xFFdc2626)),
          if (staffNotes != null && '$staffNotes'.isNotEmpty)
            _note('💼 $staffNotes', const Color(0xFF7c3aed)),
          if (status == 'failed' && failReason != null)
            _note('⚠️ تعذر: $failReason', const Color(0xFFdc2626)),
          if (o['customer_phone'] != null &&
              '${o['customer_phone']}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('📞 ${o['customer_phone']}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ),
          const SizedBox(height: 10),
          _orderActions(o),
        ],
      ),
    );
  }

  Widget _orderActions(Map<String, dynamic> o) {
    final id = '${o['id']}';
    final status = '${o['status']}';
    final btns = <Widget>[];
    if (status == 'assigned') {
      btns.add(_smallBtn('▶️ استلمت', const Color(0xFF0891b2),
          () => _run(() => Api.pickupOrder(id, widget.jwt))));
      btns.add(_smallBtn('⚠️ تعذر', const Color(0xFFdc2626),
          () => _openFail(o)));
    } else if (status == 'picked') {
      btns.add(_smallBtn('✅ وصّلت', const Color(0xFF16a34a),
          () => _openDeliver(o)));
      btns.add(_smallBtn('⚠️ تعذر', const Color(0xFFdc2626),
          () => _openFail(o)));
    } else if (status == 'failed') {
      btns.add(_smallBtn('🔄 حاول تاني', const Color(0xFF16a34a),
          () => _run(() => Api.retryOrder(id, widget.jwt))));
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
    for (final o in orders) {
      total += (o['total_bill_net'] is num ? o['total_bill_net'] : 0);
      final st = o['status'];
      if (['delivered', 'completed'].contains(st)) {
        done++;
        if (o['payment_method'] == 'cash') {
          cash += (o['collected_amount'] is num
              ? o['collected_amount']
              : (o['total_bill_net'] is num ? o['total_bill_net'] : 0));
        }
      }
    }
    return Container(
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
  }

  // ============ نوافذ الأزرار ============
  Future<void> _openDeliver(Map<String, dynamic> o) async {
    final id = '${o['id']}';
    String pay = '${o['payment_method'] ?? 'cash'}';
    final amtCtrl = TextEditingController(
        text: '${o['collected_amount'] ?? o['total_bill_net'] ?? ''}');
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
                decoration: const InputDecoration(
                    labelText: 'المبلغ المحصّل', border: OutlineInputBorder()),
              ),
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
      await _run(() =>
          Api.deliverOrder(id, pay, amt, note.isEmpty ? null : note, widget.jwt));
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
      await _run(() => Api.failOrder(
          id, reason!, note.isEmpty ? null : note, attempt, widget.jwt));
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
    // إذا كان الإنهاء يحتاج موافقة الإدارة
    if (!_canComplete && tid != 'direct') {
      await _run(() =>
          Api.updateTrip(tid, {'status': 'pending_complete'}, widget.jwt));
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
      }
      await Api.completeDelivered(delivered, widget.jwt);
      if (tid != 'direct') {
        await Api.updateTrip(tid, {'status': 'completed'}, widget.jwt);
      }
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }
}
