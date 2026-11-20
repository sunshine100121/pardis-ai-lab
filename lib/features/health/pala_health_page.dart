import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pala_feedback_store.dart';
import 'pala_health_report.dart';

/// Local, honest operational report: a sample index is never a measurement
/// of intelligence, correctness of every answer, or medical/home safety.
class PalaHealthPage extends ConsumerStatefulWidget {
  const PalaHealthPage({super.key});
  @override
  ConsumerState<PalaHealthPage> createState() => _PalaHealthPageState();
}

class _PalaHealthPageState extends ConsumerState<PalaHealthPage> {
  int days = 7;
  bool checking = false;

  Future<void> _check() async {
    if (checking) return;
    setState(() => checking = true);
    try {
      await ref.read(palaFeedbackStoreProvider).runQuickChecks();
      ref.invalidate(palaHealthReportProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('دو آزمون سبک محلی ثبت شدند؛ نتیجه را در گزارش ببینید.'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('آزمون یا ذخیره نتیجه انجام نشد؛ نتیجه نامعلوم است.'),
        ));
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(palaHealthReportProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('سلامت و عملکرد PALA'),
        actions: [
          IconButton(
            tooltip: 'تازه‌سازی گزارش',
            icon: const Icon(Icons.refresh_outlined),
            onPressed: () => ref.invalidate(palaHealthReportProvider),
          ),
        ],
      ),
      body: report.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('خواندن داده‌های محلی ممکن نشد. '
                'هیچ درصد سلامت یا نتیجه ساختگی نمایش داده نمی‌شود.'),
          ),
        ),
        data: (data) {
          final w = days == 7 ? data.week : data.month;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('آمار واقعی ذخیره‌شده در همین دستگاه',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                key: const Key('pala-health-window'),
                segments: const [
                  ButtonSegment(value: 7, label: Text('۷ روز')),
                  ButtonSegment(value: 30, label: Text('۳۰ روز')),
                ],
                selected: {days},
                onSelectionChanged: (v) =>
                    setState(() => days = v.first),
              ),
              const SizedBox(height: 18),
              Text('شاخص سلامت عملیاتیِ نمونه',
                  style: theme.textTheme.titleMedium),
              Text(
                w.index == null ? 'داده کافی نیست'
                    : palaPersianDigits(w.index.toString()) + ' از ۱۰۰',
                key: const Key('pala-health-index'),
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'این عدد شاخص نمونه‌ای رضایت و پایداری است؛ '
                'معیار قطعی هوشمندی، صحت همه پاسخ‌ها یا سلامت تجهیزات نیست.',
              ),
              const SizedBox(height: 10),
              if (w.index == null) ...[
                Text('برای محاسبه معتبر هنوز لازم است:',
                    style: theme.textTheme.titleSmall),
                for (final reason in w.missing)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('• ' + reason),
                  ),
              ],
              const Divider(height: 32),
              Text('کیفیت پاسخ‌ها', style: theme.textTheme.titleMedium),
              _Stat('پاسخ‌های ثبت‌شده', w.answers.toString()),
              _Stat('پسندیدن / نپسندیدن',
                  w.liked.toString() + ' / ' + w.disliked.toString()),
              _Stat('رضایت از میان رأی‌های داده‌شده',
                  _percent(w.positiveRate),
                  note: 'پاسخ بدون رأی، رأی منفی محسوب نمی‌شود.'),
              _Stat('پوشش بازخورد',
                  w.answers == 0 ? 'نامعلوم'
                      : _percent(w.rated / w.answers)),
              const Divider(height: 32),
              Text('عملکرد و خطاها', style: theme.textTheme.titleMedium),
              _Stat('پاسخ با خطای اجرا / همه پاسخ‌ها',
                  w.failures.toString() + ' / ' + w.answers.toString()),
              _Stat('درخواست‌های متوقف‌شده', w.stopped.toString(),
                  note: 'توقف عمدی کاربر، خطای مدل تلقی نمی‌شود.'),
              _Stat('خطاهای صریح در گزارش‌های بازیابی',
                  w.retrievalObserved == 0 ? 'بدون داده'
                  : w.retrievalErrors.toString() + ' از ' +
                      w.retrievalObserved.toString(),
                  note: 'فقط پاسخ‌هایی که گزارش ساختاریافته خواندن منبع دارند؛ '
                      'نبود گزارش به معنی موفقیت نیست.'),
              _Stat('میانه زمان اولین توکن',
                  _ms(w.medianFirstTokenMs),
                  note: 'بر اساس ' + w.measuredLatency.toString() +
                      ' پاسخ دارای زمان‌سنجی'),
              _Stat('میانگین سرعت تولید',
                  w.meanTokensPerSecond == null ? 'بدون داده'
                  : w.meanTokensPerSecond!.toStringAsFixed(1) + ' توکن/ثانیه'),
              _Stat('میانگین زمان بازیابی ثبت‌شده',
                  _ms(w.meanRecallMs),
                  note: 'فقط مراحل دارای سنجه recallMs؛ '
                      'زمان کل بازیابی نیست.'),
              const Divider(height: 32),
              Text('آزمون‌های سبک محلی',
                  style: theme.textTheme.titleMedium),
              _Stat('نتیجه آزمون در این بازه',
                  w.testCount == 0 ? 'هنوز ثبت نشده'
                  : w.testPasses.toString() + ' موفق از ' +
                      w.testCount.toString()),
              const Text('این آزمون‌ها فقط خواندن پایگاه‌داده و سازگاری '
                  'ثبت بازخورد را بررسی می‌کنند؛ جایگزین آزمون Qwen '
                  'یا GitHub Actions نیستند.'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('pala-run-health-checks'),
                onPressed: checking ? null : _check,
                icon: checking
                    ? const SizedBox.square(dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fact_check_outlined),
                label: Text(checking ? 'در حال بررسی...' :
                    'اجرای دو آزمون سبک محلی'),
              ),
              const Divider(height: 32),
              Text('روند روزانه ' + days.toString() + ' روز اخیر',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('ارتفاع ستون = تعداد پاسخ؛ قسمت پررنگ = '
                  'پاسخ‌های پسندیده‌شده. روزهای بدون پاسخ، صفرند.'),
              const SizedBox(height: 14),
              _DailyBars(days: w.daily),
              const SizedBox(height: 12),
              const Divider(height: 32),
              Text('فرمول شفاف شاخص', style: theme.textTheme.titleMedium),
              const Text(
                '۴۰٪ × نسبت پسندیدن میان رأی‌های ثبت‌شده + '
                '۳۰٪ × نسبت پاسخ‌های بدون خطای اجرا + '
                '۱۵٪ × نسبت گزارش‌های بازیابی بدون خطای صریح + '
                '۱۵٪ × نسبت آزمون‌های محلی موفق.',
              ),
              const SizedBox(height: 8),
              const Text(
                'حداقل داده: ۲۰ پاسخ، ۱۰ رأی، ۵ گزارش بازیابی، '
                '۴ نتیجه آزمون محلی، و فعالیت در ۳ روز (۷ روزه) '
                'یا ۷ روز (۳۰ روزه). وقتی یک شرط برقرار نباشد '
                'یا سقف خواندن داده پر شود، درصد نمایش داده نمی‌شود. '
                'سرعت مستقلاً گزارش می‌شود و بدون خط مبنای معتبر '
                'وارد فرمول نمی‌شود.',
              ),
              if (data.limited)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('بیش از ۵۰۰۰ پاسخ در بازه است؛ '
                      'این گزارش نمونه ناقص است و شاخص سلامت محاسبه نمی‌شود.'),
                ),
              const SizedBox(height: 28),
            ],
          );
        },
      ),
    );
  }

  static String _percent(double? n) =>
      n == null ? 'بدون داده' : (100 * n).toStringAsFixed(0) + '٪';
  static String _ms(double? n) =>
      n == null ? 'بدون داده' : n.round().toString() + ' میلی‌ثانیه';
}

// Keep numerical summaries readable in the Persian owner interface.
String palaPersianDigits(String value) => value.replaceAllMapped(
  RegExp(r'[0-9]'),
  (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m.group(0)!)],
);

class _Stat extends StatelessWidget {
  final String name, value;
  final String? note;
  const _Stat(this.name, this.value, {this.note});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(name)),
          const SizedBox(width: 12),
          Flexible(child: Text(palaPersianDigits(value), textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
        if (note != null)
          Padding(padding: const EdgeInsets.only(top: 3),
            child: Text(note!, style: Theme.of(context).textTheme.bodySmall)),
      ],
    ),
  );
}

class _DailyBars extends StatelessWidget {
  final List<PalaDailyHealth> days;
  const _DailyBars({required this.days});
  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const Text('بدون داده');
    final maxValue = days.fold<int>(1, (max, d) =>
        d.answers > max ? d.answers : max);
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      SizedBox(
        height: 66,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final day in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Tooltip(
                    message: day.day.day.toString() + '/' +
                        day.day.month.toString() + ': ' +
                        day.answers.toString() + ' پاسخ، ' +
                        day.liked.toString() + ' پسندیده',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: 48.0 * day.answers / maxValue,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: day.answers == 0 ? 0 :
                                  day.liked / day.answers,
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(days.first.day.day.toString() + '/' +
            days.first.day.month.toString()),
        Text(days.last.day.day.toString() + '/' +
            days.last.day.month.toString()),
      ]),
    ]);
  }
}
