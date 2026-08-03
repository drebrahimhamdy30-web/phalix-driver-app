import 'package:flutter/material.dart';
import 'api.dart';
import 'config.dart';

const _arMonths = [
  '', 'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
];

String _fmTime(int mins) {
  if (mins < 0) mins = 0;
  if (mins < 60) return '$mins د';
  return '${mins ~/ 60}س ${mins % 60}د';
}

String _d2(int n) => n < 10 ? '0$n' : '$n';
String _fmtDate(DateTime d) => '${d.year}-${_d2(d.month)}-${_d2(d.day)}';

String _fmClock(DateTime d) {
  int h = d.hour;
  final ampm = h < 12 ? 'ص' : 'م';
  h = h % 12;
  if (h == 0) h = 12;
  return '$h:${_d2(d.minute)} $ampm';
}

class HoursView extends StatefulWidget {
  final String driverId;
  final String jwt;
  final int maxBreak;
  const HoursView(
      {super.key,
      required this.driverId,
      required this.jwt,
      required this.maxBreak});

  @override
  State<HoursView> createState() => _HoursViewState();
}

class _Shift {
  final DateTime start;
  final DateTime? end; // null => ما زال مستمر (الطيار أونلاين)
  final int work;
  final int brk;
  final int excess;
  final int effective;
  final bool ongoing;
  _Shift(this.start, this.end, this.work, this.brk, this.excess,
      this.effective, this.ongoing);
}

class _HoursViewState extends State<HoursView> {
  int _offset = 0; // 0 = الشهر الحالي، 1 = الشهر السابق
  bool _loading = true;
  List<_Shift> _shifts = [];
  int _curEff = 0; // ساعات آخر/الشيفت الحالي
  bool _curOngoing = false;
  int _monthEff = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime get _month =>
      DateTime(DateTime.now().year, DateTime.now().month - _offset, 1);

  Future<void> _load() async {
    setState(() => _loading = true);
    final first = DateTime(_month.year, _month.month, 1);
    final last = DateTime(_month.year, _month.month + 1, 0);
    // نوسّع نافذة الاستعلام يوم قبل ويوم بعد حتى لا تنكسر الشيفتات العابرة لمنتصف الليل
    final qFrom = first.subtract(const Duration(days: 1));
    final qTo = last.add(const Duration(days: 1));
    final records = await Api.getAttendance(
        widget.driverId, _fmtDate(qFrom), _fmtDate(qTo), widget.jwt);

    final all = _buildShifts(records);
    // احتفظ فقط بالشيفتات التي بدأت داخل الشهر المختار
    final shifts = all
        .where((s) => s.start.year == _month.year && s.start.month == _month.month)
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));

    int monthEff = 0;
    for (final s in shifts) {
      monthEff += s.effective;
    }

    if (!mounted) return;
    setState(() {
      _shifts = shifts;
      _monthEff = monthEff;
      _curEff = shifts.isNotEmpty ? shifts.first.effective : 0;
      _curOngoing = shifts.isNotEmpty && shifts.first.ongoing;
      _loading = false;
    });
  }

  // يجمّع سجلات الحضور إلى شيفتات: من الحضور حتى الانصراف (سجل offline)
  List<_Shift> _buildShifts(List<Map<String, dynamic>> records) {
    // رتّب تصاعديًا حسب approved_at
    final recs = records
        .where((r) => r['approved_at'] != null)
        .map((r) => {
              'status': '${r['status']}',
              'ap': DateTime.tryParse('${r['approved_at']}'),
              'end': r['ended_at'] != null
                  ? DateTime.tryParse('${r['ended_at']}')
                  : null,
            })
        .where((r) => r['ap'] != null)
        .toList()
      ..sort((a, b) =>
          (a['ap'] as DateTime).compareTo(b['ap'] as DateTime));

    const gap = Duration(minutes: 40); // فجوة كبيرة = انصراف ضمني
    final now = DateTime.now();
    final shifts = <_Shift>[];

    DateTime? sStart;
    DateTime? lastEnd;
    int work = 0, brk = 0;
    bool open = false;
    bool ongoing = false;

    void close(DateTime end, bool stillOpen) {
      if (sStart == null) {
        open = false;
        return;
      }
      final excess =
          (brk - widget.maxBreak) > 0 ? brk - widget.maxBreak : 0;
      final eff = (work - excess) > 0 ? work - excess : 0;
      shifts.add(_Shift(
          sStart!, stillOpen ? null : end, work, brk, excess, eff, stillOpen));
      sStart = null;
      lastEnd = null;
      work = 0;
      brk = 0;
      open = false;
      ongoing = false;
    }

    for (final r in recs) {
      final st = r['status'] as String;
      final ap = r['ap'] as DateTime;

      if (st == 'offline') {
        // انصراف — يُنهي الشيفت الحالي عند هذه اللحظة
        close(ap, false);
        continue;
      }

      // online / break / break_ended
      final end = (r['end'] as DateTime?) ?? now;
      final recOngoing = r['end'] == null;

      // فجوة كبيرة بين نهاية آخر سجل وبداية هذا السجل => انصراف مفقود
      if (open && lastEnd != null && ap.difference(lastEnd!) > gap) {
        close(lastEnd!, false);
      }
      if (!open) {
        sStart = ap;
        open = true;
      }

      final mins = end.difference(ap).inMinutes;
      final m = mins < 0 ? 0 : mins;
      if (st == 'online') {
        work += m;
      } else {
        // break / break_ended
        brk += m;
      }
      if (lastEnd == null || end.isAfter(lastEnd!)) lastEnd = end;
      if (recOngoing) ongoing = true;
    }
    // شيفت مفتوح في النهاية
    if (open) close(lastEnd ?? now, ongoing);

    return shifts;
  }

  String _shiftLabel(_Shift s) {
    const wd = [
      '', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس',
      'الجمعة', 'السبت', 'الأحد'
    ];
    final start = s.start;
    final dayPart =
        '${wd[start.weekday]} ${start.day} ${_arMonths[start.month]}';
    final startClock = _fmClock(start);
    if (s.end == null) {
      return '$dayPart · $startClock ← الآن';
    }
    final end = s.end!;
    final endClock = _fmClock(end);
    final crossed = end.year != start.year ||
        end.month != start.month ||
        end.day != start.day;
    return '$dayPart · $startClock ← $endClock${crossed ? ' (+1)' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // بطاقة الشيفت الحالي / آخر شيفت
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [AppTheme.appBar, Color(0xFF334155)]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_curOngoing ? 'الشيفت الحالي' : 'آخر شيفت',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  const Text('العمل الفعلي',
                      style: TextStyle(color: Colors.white60, fontSize: 11)),
                ],
              ),
              Text(_fmTime(_curEff),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        // اختيار الشهر
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              _monthChip('الشهر الحالي', 0),
              const SizedBox(width: 8),
              _monthChip('الشهر السابق', 1),
              const Spacer(),
              Text('إجمالي: ${_fmTime(_monthEff)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: AppTheme.primary)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
                '${_arMonths[_month.month]} ${_month.year} · ${_shifts.length} شيفت',
                style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _shifts.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(children: const [
                        SizedBox(height: 120),
                        Center(
                            child: Text('لا يوجد سجل حضور لهذا الشهر',
                                style: TextStyle(color: Colors.grey))),
                      ]),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _shifts.length,
                        itemBuilder: (_, i) {
                          final s = _shifts[i];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            if (s.ongoing)
                                              Container(
                                                margin:
                                                    const EdgeInsets.only(
                                                        left: 6),
                                                width: 9,
                                                height: 9,
                                                decoration:
                                                    const BoxDecoration(
                                                  color: Color(0xFF16a34a),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(_shiftLabel(s),
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 13)),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(_fmTime(s.effective),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15,
                                                  color: AppTheme.primary)),
                                          const Text('عمل فعلي',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey)),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(spacing: 14, children: [
                                    Text('إجمالي العمل: ${_fmTime(s.work)}',
                                        style: const TextStyle(fontSize: 12)),
                                    Text(
                                        'الاستراحة: ${_fmTime(s.brk)}${s.excess > 0 ? ' (زيادة ${_fmTime(s.excess)})' : ''}',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: s.excess > 0
                                                ? const Color(0xFFdc2626)
                                                : null)),
                                  ]),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _monthChip(String label, int off) {
    final sel = _offset == off;
    return InkWell(
      onTap: () {
        setState(() => _offset = off);
        _load();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? AppTheme.primary : const Color(0xFFe5e7eb),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(label,
            style: TextStyle(
                color: sel ? Colors.white : const Color(0xFF374151),
                fontWeight: FontWeight.w700,
                fontSize: 12.5)),
      ),
    );
  }
}
