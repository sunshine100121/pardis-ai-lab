import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/memory_policy.dart';
import 'providers/memory_preferences.dart';
import 'providers/memory_provider.dart';

/// Settings > Memory reuses the existing notes and project workspaces.
class MemoryPolicyControls extends ConsumerWidget {
  const MemoryPolicyControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(memoryPreferencesProvider);
    final n = ref.read(memoryPreferencesProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('یادگیری حافظه', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          DropdownButton<MemoryLearningMode>(
            key: const Key('memory-learning-mode'),
            isExpanded: true,
            value: prefs.learning,
            items: const [
              DropdownMenuItem(
                value: MemoryLearningMode.off,
                child: Text('خاموش — فقط استفاده از خاطرات قبلی'),
              ),
              DropdownMenuItem(
                value: MemoryLearningMode.confirm,
                child: Text('با تأیید من — پیشنهادها را بررسی کنم'),
              ),
              DropdownMenuItem(
                value: MemoryLearningMode.automatic,
                child: Text('خودکار — فقط اطلاعات صریح و کم‌خطر'),
              ),
            ],
            onChanged: (v) {
              if (v != null) n.update(prefs.copyWith(learning: v));
            },
          ),
          const SizedBox(height: 12),
          const Text('مدت نگهداری خاطرات جدید',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          DropdownButton<MemoryRetention>(
            key: const Key('memory-retention'),
            value: prefs.retention,
            isExpanded: true,
            items: [
              for (final period in MemoryRetention.values)
                DropdownMenuItem(value: period, child: Text(period.label)),
            ],
            onChanged: (v) {
              if (v != null) n.update(prefs.copyWith(retention: v));
            },
          ),
          const Text(
            'روی خاطرات قبلی اثری ندارد؛ مدت هر خاطره را نیز می‌توانید تغییر دهید.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Text('سبک پاسخ‌گویی', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          DropdownButton<MemoryResponseStyle>(
            key: const Key('memory-response-style'),
            value: prefs.responseStyle,
            isExpanded: true,
            items: [
              for (final style in MemoryResponseStyle.values)
                DropdownMenuItem(value: style, child: Text(style.label)),
            ],
            onChanged: (v) {
              if (v != null) n.update(prefs.copyWith(responseStyle: v));
            },
          ),
          const SizedBox(height: 12),
          const Text(
            'سه سطح حافظه: عمومی برای گفت‌وگوهای عادی؛ یادداشت‌های هر پروژه '
            'فقط در همان پروژه؛ تاریخچه مکالمه فقط برای همان گفت‌وگو. '
            'پیشنهاد مدل تا تأیید شما واقعیت محسوب نمی‌شود.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Untrusted proposals are never persisted or injected into prompts until
/// individually approved. Approval writes into the EXISTING memory table.
class MemoryPendingSuggestions extends ConsumerWidget {
  const MemoryPendingSuggestions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(memorySuggestionsProvider);
    if (pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('پیشنهادهای تأییدنشده',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final proposal in pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(proposal.content),
                  const Text(
                    'پیشنهاد است، نه واقعیت تأییدشده.',
                    style: TextStyle(fontSize: 12),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        key: Key('memory-proposal-approve-' +
                            proposal.content.hashCode.toString()),
                        onPressed: () async {
                          final retention = ref.read(memoryPreferencesProvider).retention;
                          await ref.read(memoryStoreProvider).add(
                            proposal.content,
                            sourceChatId: proposal.sourceChatId,
                            sourceMessageId: proposal.sourceMessageId,
                            expiresAt: retention.expiresFrom(DateTime.now()),
                          );
                          ref.read(memorySuggestionsProvider.notifier).discard(proposal);
                        },
                        child: const Text('تأیید و ذخیره'),
                      ),
                      TextButton(
                        key: Key('memory-proposal-dismiss-' +
                            proposal.content.hashCode.toString()),
                        onPressed: () =>
                            ref.read(memorySuggestionsProvider.notifier)
                                .discard(proposal),
                        child: const Text('رد کردن'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
