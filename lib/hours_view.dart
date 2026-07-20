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

class _DayHours {
  final String date;
  final int work;
  final int brk;
  final int excess;
  final int effective;
  _DayHours(this.date, this.work, this.brk, this.excess, this.effective);
}

class _HoursViewState extends State<HoursView> {
  int _offset = 0; // 0 = الشهر الحالي، 1 = الشهر السابق
  bool _loading = true;
  List<_DayHours> _days = [];
  int _todayEff = 0;
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
    final records = await Api.getAttendance(
        widget.driverId, _fmtDate(first), _fmtDate(last), widget.jwt);

    final byDay = <String, List<Map<String, dynamic>>>{};
    for (final r in records) {
      final d = '${r['date']}';
      byDay.putIfAbsent(d, () => []).add(r);
    }

    int minutesOf(Map<String, dynamic> r) {
      final ap = DateTime.tryParse('${r['approved_at']}');
      if (ap == null) return 0;
      final end = r['ended_at'] != null
          ? (DateTime.tryParse('${r['ended_at']}') ?? DateTime.now())
          : DateTime.now();
      final m = end.difference(ap).inMinutes;
      return m < 0 ? 0 : m;
    }

    final days = <_DayHours>[];
    int monthEff = 0;
    final todayStr = _fmtDate(DateTime.now());
    int todayEff = 0;
    final keys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final date in keys) {
      final recs = byDay[date]!;
      int work = 0, brk = 0;
      for (final r in recs) {
        if (r['approved_at'] == null) continue;
        if (r['status'] == 'online') work += minutesOf(r);
        if (r['status'] == 'break') brk += minutesOf(r);
      }
      final excess = (brk - widget.maxBreak) > 0 ? brk - widget.maxBreak : 0;
      final eff = (work - excess) > 0 ? work - excess : 0;
      days.add(_DayHours(date, work, brk, excess, eff));
      monthEff += eff;
      if (date == todayStr) todayEff = eff;
    }

    if (!mounted) return;
    setState(() {
      _days = days;
      _monthEff = monthEff;
      _todayEff = todayEff;
      _loading = false;
    });
  }

  String _dayLabel(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const wd = [
      '', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس',
      'الجمعة', 'السبت', 'الأحد'
    ];
    return '${wd[d.weekday]} ${d.day} ${_arMonths[d.month]}';
  }

  @override
  Widget build(BuildContext context) {
    final todayStr = _fmtDate(DateTime.now());
    return Column(
      children: [
        // بطاقة اليوم
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
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ساعات عملك اليوم',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  SizedBox(height: 4),
                  Text('العمل الفعلي',
                      style: TextStyle(color: Colors.white60, fontSize: 11)),
                ],
              ),
              Text(_fmTime(_todayEff),
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
            child: Text('${_arMonths[_month.month]} ${_month.year}',
                style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _days.isEmpty
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
                        itemCount: _days.length,
                        itemBuilder: (_, i) {
                          final d = _days[i];
                          final isToday = d.date == todayStr;
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
                                        child: Text(
                                            '${_dayLabel(d.date)}${isToday ? ' (اليوم)' : ''}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5)),
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(_fmTime(d.effective),
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
                                    Text('إجمالي العمل: ${_fmTime(d.work)}',
                                        style: const TextStyle(fontSize: 12)),
                                    Text(
                                        'الاستراحة: ${_fmTime(d.brk)}${d.excess > 0 ? ' (زيادة ${_fmTime(d.excess)})' : ''}',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: d.excess > 0
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
