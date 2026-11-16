/// Aggregate *hourly statistics*, not raw observations, into a local-hour
/// profile. All calculations are deterministic; Qwen must only explain them.
/// This file never accesses Home Assistant or external networks.
class HourlyValue {
  final DateTime at;
  final double? mean;
  const HourlyValue(this.at, this.mean);
}

class HourlyProfile {
  final int localHour;
  final int expectedHours;
  final int validHours;
  final double? mean;
  final double? maximumHourlyMean;
  final Set<int> startMinutes, utcOffsetMinutes;
  const HourlyProfile(this.localHour,this.expectedHours,this.validHours,
      this.mean,this.maximumHourlyMean,
      {this.startMinutes = const {}, this.utcOffsetMinutes = const {}});
  double get coverage => expectedHours==0 ? 0 : validHours/expectedHours;
  String? get localInterval {
    if (startMinutes.length != 1) return null;
    final minute = startMinutes.single.toString().padLeft(2, '0');
    final begin = localHour.toString().padLeft(2, '0');
    final end = ((localHour + 1) % 24).toString().padLeft(2, '0');
    return '$begin:$minute–$end:$minute';
  }
}

class HourlyPattern {
  /// Bounds are half-open UTC hours. Missing/invalid values never become 0.
  /// Duplicate buckets are rejected to avoid biased means and fake coverage.
  static List<HourlyProfile> summarize({
    required DateTime fromUtc,
    required DateTime toUtc,
    required Iterable<HourlyValue> samples,
    Duration Function(DateTime utc)? utcOffsetAt,
  }) {
    final start=fromUtc.toUtc(), end=toUtc.toUtc();
    if (!start.isBefore(end) || end.difference(start)>const Duration(days:370)
        || start.minute!=0 || start.second!=0 || start.millisecond!=0
        || end.minute!=0 || end.second!=0 || end.millisecond!=0
        || start.microsecond!=0 || end.microsecond!=0) {
      throw const FormatException('بازه ساعتی معتبر نیست.');
    }
    final expected=List<int>.filled(24,0);
    final minutes=List.generate(24,(_)=><int>{});
    final offsets=List.generate(24,(_)=><int>{});
    DateTime wallTime(DateTime at) {
      final offset=utcOffsetAt?.call(at) ?? at.toLocal().timeZoneOffset;
      if (offset.inMicroseconds % Duration.microsecondsPerMinute != 0 ||
          offset.abs() > const Duration(hours:14)) {
        throw const FormatException('اختلاف ساعت محلی معتبر نیست.');
      }
      return at.add(offset);
    }
    for (var at=start;at.isBefore(end);at=at.add(const Duration(hours:1))) {
      final wall=wallTime(at);
      expected[wall.hour]++;
      minutes[wall.hour].add(wall.minute);
      offsets[wall.hour].add(wall.difference(at).inMinutes);
    }
    final byHour=List<List<double>>.generate(24,(_)=><double>[]);
    final seen=<int>{};
    var sampleCount=0;
    for(final s in samples) {
      if(++sampleCount>10000) throw const FormatException('آمار بیش از سقف مجاز است.');
      final at=s.at.toUtc();
      if(at.isBefore(start) || !at.isBefore(end)) continue;
      if(at.minute!=0 || at.second!=0 || at.millisecond!=0 || at.microsecond!=0) {
        throw const FormatException('آمار ورودی باید در مرز ساعت ثبت شده باشد.');
      }
      if(!seen.add(at.microsecondsSinceEpoch)) {
        throw const FormatException('رکورد آماری ساعتی تکراری است.');
      }
      final value=s.mean;
      if(value!=null && value.isFinite) byHour[wallTime(at).hour].add(value);
    }
    return List.generate(24,(h) {
      final values=byHour[h];
      return HourlyProfile(h,expected[h],values.length,
        values.isEmpty?null:values.reduce((a,b)=>a+b)/values.length,
        values.isEmpty?null:values.reduce((a,b)=>a>b?a:b),
        startMinutes:Set.unmodifiable(minutes[h]),utcOffsetMinutes:Set.unmodifiable(offsets[h]));
    });
  }
}
