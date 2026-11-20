import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../health/pala_feedback_store.dart';
import 'pala_learning_store.dart';

/// Advanced/optional owner controls, never a daily interaction gate.
/// No model reload, code writes, network call or automatic deployment.
class PalaLearningPage extends ConsumerStatefulWidget {
  const PalaLearningPage({super.key});
  @override
  ConsumerState<PalaLearningPage> createState() => _PalaLearningPageState();
}

class _PalaLearningPageState extends ConsumerState<PalaLearningPage> {
  String? busyId;

  Future<void> _change(OwnerLearningCase item, {required bool enable}) async {
    if (busyId != null) return;
    setState(() => busyId = item.id);
    try {
      final store = ref.read(palaLearningStoreProvider);
      if (enable) {
        await store.approve(item.id);
      } else {
        await store.disable(item.id);
      }
      ref.invalidate(palaLearningListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(enable
              ? 'آزمون قبل و بعد موفق بود؛ اصلاح فقط در همان گفت‌وگوی '
                  'محلی فعال شد.'
              : 'اصلاح غیرفعال شد؛ داده‌های قبلی حفظ شدند.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'آزمون یا ثبت اصلاح تأیید نشد؛ هیچ تغییر نیمه‌کاره اعمال نشد.',
          )),
        );
      }
    } finally {
      if (mounted) setState(() => busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cases = ref.watch(palaLearningListProvider);
    final weaknesses = ref.watch(palaLearningWeaknessesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('اصلاح‌ها و یادگیری کنترل‌شده'),
        actions: [
          IconButton(
            tooltip: 'تازه‌سازی',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(palaLearningListProvider);
              ref.invalidate(palaLearningWeaknessesProvider);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('یادگیری فقط با اصلاح صریح شما',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('نپسندیدن پاسخ به‌تنهایی چیزی را به مدل نمی‌آموزد. '
              'پیشنهادها ابتدا غیرفعال‌اند؛ با انتخاب «آزمایش و فعال‌سازی»، '
              'جست‌وجوی همان سؤال قبل و بعد آزموده و نتیجه ذخیره می‌شود. '
              'هر اصلاح فقط در همان گفت‌وگوی محلیِ غیرموقت استفاده می‌شود. '
              'هیچ فایل مدل یا منبع اصلی بازنویسی نمی‌شود.'),
          const SizedBox(height: 18),
          Text('خطاهای تکرارشونده در ۳۰ روز',
              style: Theme.of(context).textTheme.titleMedium),
          weaknesses.when(
            data: (data) => data.isEmpty
                ? const Text('هنوز الگوی نارضایتی با حداقل سه رأی پیدا نشده است.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in data)
                        Text('• ' +
                            (FeedbackReasons.labels[item.$1] ?? 'سایر') +
                            ': ' + item.$2.toString() +
                            ' مورد — نیازمند بررسی مالک، نه اصلاح خودکار'),
                    ],
                  ),
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const Text('اطلاعات بازخورد فعلاً قابل‌خواندن نیست.'),
          ),
          const Divider(height: 30),
          Text('پیشنهادها و اصلاح‌های من',
              style: Theme.of(context).textTheme.titleMedium),
          cases.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Text('خواندن اصلاح‌ها انجام نشد.'),
            data: (items) => items.isEmpty
                ? const Text('هنوز اصلاحی پیشنهاد نشده است. '
                    'زیر پاسخ نپسندیده‌شده «اصلاح پاسخ» را انتخاب کنید.')
                : Column(
                    children: [
                      for (final item in items)
                        Card(
                          key: Key('m19-case-' + item.id),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.question,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                Text('اصلاح پیشنهادی شما: ' + item.correction),
                                const SizedBox(height: 7),
                                Text(switch (item.state) {
                                  LearningState.proposed =>
                                    'وضعیت: پیشنهادی — هنوز در پاسخ‌ها استفاده نمی‌شود',
                                  LearningState.active =>
                                    'وضعیت: فعال — آزمون پس از اصلاح موفق',
                                  LearningState.disabled =>
                                    'وضعیت: غیرفعال — قابل بازگردانی',
                                }),
                                if (item.testedAt != null)
                                  Text('نتیجه آزمون قبل / بعد: ' +
                                      (item.beforeTestPassed ? 'موفق' : 'بدون اصلاح') +
                                      ' / ' +
                                      (item.afterTestPassed ? 'موفق' : 'ناموفق')),
                                Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: item.state == LearningState.active
                                      ? OutlinedButton(
                                          key: Key('m19-disable-' + item.id),
                                          onPressed: busyId == null
                                              ? () => _change(item, enable: false)
                                              : null,
                                          child: const Text('غیرفعال‌سازی'),
                                        )
                                      : FilledButton(
                                          key: Key('m19-approve-' + item.id),
                                          onPressed: busyId == null
                                              ? () => _change(item, enable: true)
                                              : null,
                                          child: Text(item.state ==
                                                  LearningState.proposed
                                              ? 'آزمایش و فعال‌سازی'
                                              : 'آزمایش و فعال‌سازی دوباره'),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          const Text('این آزمون تنها ثابت می‌کند اصلاح تأییدشده '
              'برای همان پرسش قابل بازیابی است؛ صحت علمی آن، '
              'سرعت Qwen و کیفیت همه پاسخ‌ها را اثبات نمی‌کند. '
              'پرسش‌های حساس، فرمان‌های خانه و داده‌های زنده '
              'از یادگیری مستقیم کنار گذاشته می‌شوند.'),
        ],
      ),
    );
  }
}
