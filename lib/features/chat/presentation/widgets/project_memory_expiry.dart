import 'package:flutter/material.dart';

import '../../../memory/domain/memory_policy.dart';
import '../../domain/conversation_workspace.dart';

/// Per-note retention in the EXISTING project editor.
/// Changes are drafts until the owner taps the editor's Save button.
class ProjectMemoryExpiryEditor extends StatelessWidget {
  final TextEditingController notes;
  const ProjectMemoryExpiryEditor({required this.notes, super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: notes,
      builder: (context, value, _) {
        final approved = ProjectMemoryEntry.approvedLines(value.text);
        if (approved.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'مدت نگهداری یادداشت‌های تأییدشده',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Text(
              'برای هر یادداشت انتخاب کنید؛ با ذخیره پروژه نهایی می‌شود.',
              style: TextStyle(fontSize: 12),
            ),
            for (var i = 0; i < approved.length; i++)
              ListTile(
                key: Key('project-memory-expiry-note-' + i.toString()),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  ProjectMemoryEntry.contentOf(approved[i]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  ProjectMemoryEntry.expiresAtOf(approved[i]) == null
                      ? (approved[i].contains('؛ انقضا: ')
                          ? 'تاریخ انقضا نامعتبر؛ یادداشت غیرفعال است'
                          : 'تا حذف دستی')
                      : 'تا ' +
                          ProjectMemoryEntry.expiresAtOf(approved[i])!
                              .toLocal()
                              .toString()
                              .substring(0, 10),
                ),
                trailing: PopupMenuButton<MemoryRetention>(
                  key: Key('project-memory-expiry-menu-' + i.toString()),
                  tooltip: 'تغییر مدت نگهداری',
                  onSelected: (retention) {
                    final changed = ProjectMemoryEntry.changeExpiry(
                      notes.text,
                      line: approved[i],
                      expiresAt: retention.expiresFrom(DateTime.now()),
                    );
                    if (changed.length > 6000) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'فضای یادداشت‌های پروژه پر است؛ ابتدا متن را کوتاه کنید.',
                          ),
                        ),
                      );
                      return;
                    }
                    notes.value = notes.value.copyWith(
                      text: changed,
                      selection: TextSelection.collapsed(offset: changed.length),
                      composing: TextRange.empty,
                    );
                  },
                  itemBuilder: (_) => [
                    for (final retention in MemoryRetention.values)
                      PopupMenuItem(
                        value: retention,
                        child: Text(retention.label),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
