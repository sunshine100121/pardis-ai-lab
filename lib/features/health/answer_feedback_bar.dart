import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pala_feedback_store.dart';
import 'pala_health_report.dart';
import '../learning/pala_learning_store.dart';

/// Compact response footer; no repeated confirmation and no identity
/// requirements. Only the owner chooses whether to give a reason.
class AnswerFeedbackBar extends ConsumerStatefulWidget {
  final String messageId;
  const AnswerFeedbackBar({super.key, required this.messageId});

  @override
  ConsumerState<AnswerFeedbackBar> createState() => _AnswerFeedbackBarState();
}

class _AnswerFeedbackBarState extends ConsumerState<AnswerFeedbackBar> {
  bool saving = false;

  Future<void> _vote(AnswerVote vote, AnswerFeedback? current) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await ref
          .read(palaFeedbackStoreProvider)
          .write(
            widget.messageId,
            current?.vote == vote ? null : vote,
            reasonCode: current?.vote == vote
                ? null
                : (vote == AnswerVote.disliked ? current?.reasonCode : null),
          );
      ref.invalidate(answerFeedbackProvider(widget.messageId));
      ref.invalidate(palaHealthReportProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ثبت رأی انجام نشد؛ دوباره تلاش کنید.')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _reason(AnswerFeedback current) async {
    if (saving || current.vote != AnswerVote.disliked) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('دلیل نارضایتی (اختیاری)'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, 'none'),
            child: const Text('بدون ثبت دلیل'),
          ),
          for (final item in FeedbackReasons.labels.entries)
            SimpleDialogOption(
              key: Key('feedback-reason-' + item.key),
              onPressed: () => Navigator.pop(dialog, item.key),
              child: Text(item.value),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => saving = true);
    try {
      await ref
          .read(palaFeedbackStoreProvider)
          .write(
            widget.messageId,
            AnswerVote.disliked,
            reasonCode: selected == 'none' ? null : selected,
          );
      ref.invalidate(answerFeedbackProvider(widget.messageId));
      ref.invalidate(palaHealthReportProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('ثبت علت انجام نشد.')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _proposeCorrection() async {
    if (saving) return;
    var draftText = '';
    try {
      final correction = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('پیشنهاد اصلاح پاسخ'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'اصلاح معتبر خود را بنویسید. فقط پس از بررسی '
                'و تأیید شما در «سلامت و عملکرد PALA» فعال می‌شود؛ '
                'نپسندیدن به‌تنهایی باعث یادگیری نمی‌شود.',
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('m19-owner-correction-field'),
                onChanged: (value) => draftText = value,
                maxLines: 4,
                maxLength: 450,
                decoration: const InputDecoration(
                  hintText: 'پاسخ صحیح از دید شما...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('انصراف'),
            ),
            FilledButton(
              key: const Key('m19-submit-correction'),
              onPressed: () => Navigator.pop(dialog, draftText.trim()),
              child: const Text('ثبت پیشنهاد'),
            ),
          ],
        ),
      );
      if (!mounted || correction == null || correction.isEmpty) return;
      setState(() => saving = true);
      await ref
          .read(palaLearningStoreProvider)
          .propose(sourceAnswerId: widget.messageId, correction: correction);
      ref.invalidate(palaLearningListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'پیشنهاد ذخیره شد و هنوز فعال نیست. '
              'از «سلامت و عملکرد PALA ← اصلاح‌های من» آن را '
              'آزمایش و تأیید کنید.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'پیشنهاد ثبت نشد. '
              'فقط اصلاح‌های کم‌خطر برای پاسخ ذخیره‌شده '
              'و نپسندیده قابل پذیرش‌اند.',
            ),
          ),
        );
      }
    } finally {
      // The dialog owns the field lifecycle; no controller to dispose.
      if (mounted && saving) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedback = ref.watch(answerFeedbackProvider(widget.messageId));
    final current = feedback.asData?.value;
    final loading = saving || feedback.isLoading;
    final liked = current?.vote == AnswerVote.liked;
    final disliked = current?.vote == AnswerVote.disliked;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            key: Key('pala-like-' + widget.messageId),
            tooltip: liked ? 'برداشتن پسندیدن' : 'پسندیدن پاسخ',
            visualDensity: VisualDensity.compact,
            iconSize: 19,
            onPressed: loading ? null : () => _vote(AnswerVote.liked, current),
            color: liked ? accent : null,
            icon: Icon(liked ? Icons.thumb_up : Icons.thumb_up_outlined),
          ),
          IconButton(
            key: Key('pala-dislike-' + widget.messageId),
            tooltip: disliked ? 'برداشتن نپسندیدن' : 'نپسندیدن پاسخ',
            visualDensity: VisualDensity.compact,
            iconSize: 19,
            onPressed: loading
                ? null
                : () => _vote(AnswerVote.disliked, current),
            color: disliked ? accent : null,
            icon: Icon(disliked ? Icons.thumb_down : Icons.thumb_down_outlined),
          ),
          if (disliked)
            TextButton(
              key: Key('pala-feedback-reason-' + widget.messageId),
              onPressed: loading || current == null
                  ? null
                  : () => _reason(current),
              child: Text(
                current?.reasonCode == null
                    ? 'دلیل؟ (اختیاری)'
                    : FeedbackReasons.labels[current?.reasonCode] ??
                          'ویرایش دلیل',
              ),
            ),
          if (disliked)
            TextButton(
              key: Key('m19-propose-correction-' + widget.messageId),
              onPressed: loading ? null : _proposeCorrection,
              child: const Text('اصلاح پاسخ'),
            ),
        ],
      ),
    );
  }
}
