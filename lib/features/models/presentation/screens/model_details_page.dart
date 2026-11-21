import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design/app_design.dart';
import '../../../../core/design/app_dialog.dart';
import '../../../../core/platform/desktop_host.dart';
import '../../../../core/l10n/l10n.dart';
import '../../domain/entities/model_catalog.dart';
import '../../domain/entities/model_info.dart';
import '../../../chat/domain/photo_understanding_policy.dart';
import '../providers/model_manager_provider.dart';
import '../../../settings/domain/setting_specs.dart';
import '../../../settings/presentation/setting_labels.dart';
import '../../../settings/presentation/providers/model_profiles_provider.dart';
import '../widgets/model_brand.dart';
import '../widgets/model_capabilities.dart';
import '../widgets/model_tags.dart';

void openModelDetails(BuildContext context, ModelInfo model) {
  if (DesktopHost.active) {
    showAppDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        key: const Key('desktop-model-details'),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppDesign.radius(AppDesign.rXl),
        ),
        child: SizedBox(
          width: 720,
          height: MediaQuery.sizeOf(dialog).height * 0.8,
          child: ModelDetailsPage(model: model, dialog: true),
        ),
      ),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ModelDetailsPage(model: model)),
  );
}

class ModelDetailsPage extends ConsumerWidget {
  final ModelInfo model;
  final bool dialog;
  const ModelDetailsPage({super.key, required this.model, this.dialog = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final path = model.localPath;
    final facts = path == null
        ? null
        : ref.watch(modelMetadataProvider(path)).asData?.value;
    final profile =
        ref.watch(modelProfilesProvider)[model.id] ?? const <String, dynamic>{};
    final uri = Uri.tryParse(model.downloadUrl ?? '');
    final source =
        uri?.host == 'huggingface.co' && uri!.pathSegments.length >= 2
        ? uri.pathSegments.take(2).join('/')
        : t.modelUnknown;
    // Detail widgets must not force model-database initialization just to
    // display the already-selected model. After pairing, reopening this page
    // reads the updated model catalog normally.
    final current = model;
    final projector = current.projector ?? visionProjectors[current.id];
    final compatibleImported4b =
        current.projector == null &&
        current.isDownloaded &&
        PhotoUnderstandingPolicy.isImportedQwen35FourB(
          architecture: facts?.architecture,
          parameterCount: facts?.parameterCount,
        );
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.text.small),
          SelectableText(value, style: context.text.body),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !dialog,
        title: Text(t.modelDetails),
        actions: dialog
            ? [CloseButton(onPressed: () => Navigator.of(context).pop())]
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              ModelBrandIcon('$source ${model.displayName}'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(model.displayName, style: context.text.title),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ModelCapabilityBadges(model: model),
          const SizedBox(height: 12),
          fact(t.modelSize, model.sizeLabel),
          fact(t.modelQuantization, model.quantLabel),
          fact(t.modelArchitecture, facts?.architecture ?? model.family.name),
          fact(
            t.modelContextLength,
            facts?.contextLength?.toString() ?? t.modelUnknown,
          ),
          if (facts?.parameterCount case final count?)
            fact(t.modelParameters(''), '${(count / 1e9).toStringAsFixed(2)}B')
          else if (paramLabel(model).isNotEmpty)
            fact(t.modelParameters(''), paramLabel(model)),
          fact(t.licenseLabel(''), model.license),
          fact(t.modelSource, source),
          if (model.downloadedAt case final date?)
            fact(
              t.desktopHfDownloaded,
              MaterialLocalizations.of(context)
                  .formatMediumDate(date.toLocal()),
            ),
          const Divider(),
          Text(t.modelFiles, style: context.text.title),
          if (model.parts.isEmpty)
            fact(
              model.fileName,
              '${model.localPath ?? model.fileName} · ${model.sizeLabel}',
            )
          else
            for (final part in model.parts)
              fact(part.fileName, bytesLabel(part.sizeBytes)),
          if (projector != null)
            fact(
              t.hfVisionProjector,
              '${projector.fileName} · ${bytesLabel(projector.sizeBytes)}',
            ),
          if (compatibleImported4b)
            OutlinedButton.icon(
              key: const Key('m17-enable-qwen-vision'),
              icon: const Icon(Icons.image_search_outlined),
              label: const Text('فعال‌سازی بینایی برای Qwen موجود'),
              onPressed: () async {
                final projector = visionProjectors['qwen35-4b-iq4nl'];
                if (projector == null) return;
                final accept = await showDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('فعال‌سازی تحلیل عکس'),
                    content: Text(
                      'مدل Qwen موجود حفظ می‌شود. فقط فایل بینایی '
                      'سازگار با حجم حدود '
                      '${(projector.sizeBytes / 1048576).round()} مگابایت '
                      'از منبع مشخص بارگیری و بررسی می‌شود. '
                      'این کار یک‌باره است؛ بدون موافقت شما دانلود آغاز نمی‌شود. '
                      'بعد از آن مدل باید یک‌بار دوباره بارگذاری شود. '
                      'مصرف RAM روی تبلت هنوز نیازمند آزمون است.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: const Text('انصراف'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: const Text('فعال‌سازی'),
                      ),
                    ],
                  ),
                );
                if (accept != true || !context.mounted) return;
                try {
                  final paired = await ref
                      .read(modelManagerProvider.notifier)
                      .pairKnownQwen35FourBVision(current);
                  await ref
                      .read(modelManagerProvider.notifier)
                      .downloadVision(paired);
                  if (context.mounted) {
                    final ready = ref
                        .read(modelManagerProvider)
                        .vision
                        .contains(current.id);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ready
                              ? 'فایل بینایی تأیید شد. برای تحلیل عکس، '
                                    'مدل را یک بار دوباره بارگذاری کنید.'
                              : 'فایل بینایی هنوز آماده نشده است؛ '
                                    'وضعیت دانلود را در بخش مدل‌ها بررسی کنید.',
                        ),
                      ),
                    );
                  }
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'فایل یا مدل بینایی تأیید نشد؛ '
                          'مدل اصلی و اطلاعات شما محفوظ است.',
                        ),
                      ),
                    );
                  }
                }
              },
            ),
          if (projector != null)
            SwitchListTile(
              key: const Key('model-vision'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.settingLabelVisionEnabled),
              subtitle: Text(t.settingVisionHint),
              value: profile['visionEnabled'] != false,
              onChanged: (on) =>
                  ref.read(modelProfilesProvider.notifier).set(model.id, {
                    for (final e in profile.entries)
                      if (e.key != 'visionEnabled') e.key: e.value,
                    if (!on) 'visionEnabled': false,
                  }),
            ),
          if (model.sha256 case final hash?) fact(t.verifyingSha, hash),
          const Divider(),
          Text(t.modelProfile, style: context.text.title),
          if (profile.isEmpty)
            Text(t.modelProfileDefaults, style: context.text.body)
          else
            for (final spec in SettingSpec.all.where(
              (s) => profile.containsKey(s.key),
            ))
              fact(spec.labelIn(t), '${profile[spec.key]}'),
        ],
      ),
    );
  }
}
