import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';

// شريط الحضور والانصراف والاستراحة — طلب من الطيار والإدارة توافق من الداش بورد
class AttendanceBar extends StatefulWidget {
  final String driverId;
  final String branchId;
  final String jwt;
  const AttendanceBar(
      {super.key,
      required this.driverId,
      required this.branchId,
      required this.jwt});

  @override
  State<AttendanceBar> createState() => AttendanceBarState();
}

class AttendanceBarState extends State<AttendanceBar> {
  Map<String, dynamic>? _rec; // آخر سجل
  bool _requireApproval = true;
  int _maxBreak = 15;
  int? _rank;
  int _rankTotal = 0;
  bool _loading = true;
  bool _busy = false;
  Timer? _timer;
  Timer? _pollTimer;
  String _timerText = '';

  @override
  void initState() {
    super.initState();
    _init();
    // تحديث دوري لحالة الحضور (تظهر موافقة الإدارة تلقائيًا)
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_busy) refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final s = await Api.getAttendanceSettings(widget.branchId, widget.jwt);
    _requireApproval = s['require_approval'] == true;
    _maxBreak = (s['max_break'] is int) ? s['max_break'] as int : 15;
    await refresh();
  }

  // تُستدعى من الشاشة الأم عند الرجوع للتطبيق أو التحديث
  Future<void> refresh() async {
    final rec = await Api.getLatestAttendance(widget.driverId, widget.jwt);
    Map<String, dynamic>? rank;
    try {
      rank = await Api.getRank(widget.driverId, widget.branchId, widget.jwt);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _rec = rec;
      _rank = rank?['rank'] is int ? rank!['rank'] as int : null;
      _rankTotal = rank?['total'] is int ? rank!['total'] as int : 0;
      _loading = false;
    });
    _setupTimer();
  }

  String _status() => '${_rec?['status'] ?? 'offline'}';

  void _setupTimer() {
    _timer?.cancel();
    _timer = null;
    _timerText = '';
    final st = _status();
    final approvedAt = _rec?['approved_at'];
    if (approvedAt == null) return;
    final start = DateTime.tryParse('$approvedAt')?.toLocal();
    if (start == null) return;

    if (st == 'online') {
      // عدّاد وقت الحضور (تصاعدي)
      _tickOnline(start);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _tickOnline(start);
      });
    } else if (st == 'break') {
      // عدّاد تنازلي للاستراحة + إنهاء تلقائي
      _tickBreak(start);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _tickBreak(start);
      });
    }
  }

  void _tickOnline(DateTime start) {
    final mins = DateTime.now().difference(start).inMinutes;
    setState(() => _timerText = _fmMins(mins));
  }

  void _tickBreak(DateTime start) {
    final maxMs = _maxBreak * 60 * 1000;
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    final remMs = maxMs - elapsed;
    if (remMs <= 0) {
      _timer?.cancel();
      setState(() => _timerText = '00:00');
      _autoEndBreak();
      return;
    }
    final m = remMs ~/ 60000;
    final s = (remMs % 60000) ~/ 1000;
    setState(() => _timerText =
        '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}');
  }

  String _fmMins(int mins) {
    if (mins < 0) mins = 0;
    if (mins < 60) return '$mins د';
    return '${mins ~/ 60}س ${(mins % 60).toString().padLeft(2, '0')}د';
  }

  Future<void> _autoEndBreak() async {
    final id = _rec?['id'];
    if (id == null || _busy) return;
    _busy = true;
    await Api.endBreak('$id', widget.driverId, widget.jwt, auto: true);
    _busy = false;
    await refresh();
  }

  Future<void> _request(String type) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (type == 'offline') {
        final block =
            await Api.offlineBlockReason(widget.driverId, widget.jwt);
        if (block != null) {
          if (mounted) _toast(block);
          setState(() => _busy = false);
          return;
        }
      }
      await Api.requestAttendance(
          widget.driverId, type, _requireApproval, widget.jwt);
    } catch (_) {}
    await refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _endBreakManual() async {
    final id = _rec?['id'];
    if (id == null || _busy) return;
    setState(() => _busy = true);
    await Api.endBreak('$id', widget.driverId, widget.jwt);
    await refresh();
    if (mounted) setState(() => _busy = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final st = _status();
    final isPending = st.endsWith('_request');

    late Color bg, dot;
    late String label;
    List<Widget> actions = [];

    if (isPending) {
      bg = const Color(0xFFfef9c3);
      dot = const Color(0xFFca8a04);
      label = 'بانتظار موافقة الإدارة';
    } else if (st == 'online') {
      bg = const Color(0xFFdcfce7);
      dot = const Color(0xFF16a34a);
      label = 'حاضر — جاهز للعمل';
      actions = [
        _squareBtn(Icons.free_breakfast, const Color(0xFFca8a04), 'استراحة',
            () => _request('break')),
        _squareBtn(Icons.logout, const Color(0xFFdc2626), 'انصراف',
            () => _request('offline')),
      ];
    } else if (st == 'break') {
      bg = const Color(0xFFfef9c3);
      dot = const Color(0xFFca8a04);
      label = 'في استراحة';
      actions = [
        _squareBtn(Icons.play_arrow, const Color(0xFF16a34a),
            'إنهاء الاستراحة', _endBreakManual),
      ];
    } else {
      bg = const Color(0xFFf1f5f9);
      dot = const Color(0xFF94a3b8);
      label = 'غير حاضر — اطلب الحضور';
      actions = [
        _squareBtn(Icons.login, const Color(0xFF16a34a), 'طلب الحضور',
            () => _request('online')),
      ];
    }

    // كله في سطر واحد مرتّب: الحالة يمين — والأزرار المربعة والدور شمال
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      child: Row(
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (_timerText.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(_timerText,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: st == 'break'
                        ? const Color(0xFFb45309)
                        : const Color(0xFF15803d))),
          ],
          for (final a in actions) ...[const SizedBox(width: 6), a],
          if (_rank != null) ...[const SizedBox(width: 6), _rankChip()],
          if (_busy) ...[
            const SizedBox(width: 8),
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ],
      ),
    );
  }

  Widget _rankChip() {
    final r = _rank ?? 0;
    final c = r == 1
        ? const Color(0xFF16a34a)
        : (r == 2 ? const Color(0xFFF97316) : const Color(0xFF475569));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: c.withOpacity(0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withOpacity(0.4))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_rankTotal > 0 ? 'دورك/$_rankTotal' : 'دورك',
              style: TextStyle(fontSize: 9, color: c)),
          Text('#$r',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: c)),
        ],
      ),
    );
  }

  // زر مربّع صغير بأيقونة (مع tooltip للاسم) — يقعد جنب الدور في نفس السطر
  Widget _squareBtn(
      IconData icon, Color color, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: SizedBox(
        width: 38,
        height: 38,
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
          style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: Icon(icon, size: 19),
        ),
      ),
    );
  }
}
