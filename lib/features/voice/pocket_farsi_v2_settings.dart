import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'pocket_farsi_v2_audio.dart';
import 'pocket_farsi_v2_pack.dart';
import 'pocket_farsi_v2_probe.dart';

/// Collapsed ADVANCED panel only, never part of everyday voice selection.
/// Import and test are explicit; Gyro/Qwen/HA choices are never changed.
class PocketFarsiExperimentalSettings extends StatefulWidget {
  const PocketFarsiExperimentalSettings({super.key});

  @override
  State<PocketFarsiExperimentalSettings> createState() =>
      _PocketFarsiExperimentalSettingsState();
}

class _PocketFarsiExperimentalSettingsState
    extends State<PocketFarsiExperimentalSettings> {
  bool _busy = false;
  bool _ready = false;
  String? _status;

  Future<void> _inspect() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final present = await PocketFarsiPack.isPresent();
      if (!present) {
        if (mounted) {
          setState(() {
            _ready = false;
            _status = 'بسته کامل Pocket در برنامه وجود ندارد.';
          });
        }
        return;
      }
      final native = await PocketFarsiV2Probe.inspect();
      final ready = native['ready'] == true;
      if (mounted) {
        setState(() {
          _ready = ready;
          _status = ready
              ? 'بسته مدل شناسایی شد؛ تولید صدا هنوز تأیید نشده است.'
              : 'بررسی بومی Pocket آماده نیست؛ بسته یا manifest را بررسی کنید.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = false;
          _status = 'بررسی بسته Pocket در این دستگاه ناموفق بود.';
        });
      }
    } finally {
      try {
        // Free model memory before resuming Qwen/other speaking engines.
        await PocketFarsiV2Audio.release();
      } catch (_) { /* This remains an experimental Android channel. */ }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (picked == null) return;
      if (picked.path == null) {
        throw const FormatException('فایل انتخاب‌شده در دسترس نیست.');
      }
      await PocketFarsiPack.importZip(File(picked.path!));
      final status = await PocketFarsiV2Probe.inspect();
      if (mounted) {
        setState(() {
          _ready = status['ready'] == true;
          _status = _ready
              ? 'بسته Pocket وارد شد؛ صدای اصلی پالا تغییر نکرده است.'
              : 'بسته وارد شد اما آزمایش بومی هنوز آماده نیست.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'ورود مدل انجام نشد؛ اطلاعات قبلی محفوظ است. $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trySpeech() async {
    if (_busy || !_ready) return;
    setState(() {
      _busy = true;
      _status = 'در حال آزمایش نمونه صدای محلی…';
    });
    try {
      final result = await PocketFarsiV2Audio.synthesizeAndPlay(
        'سلام، امروز هوا در باغ خوب است.',
      );
      final generated = result['generationMs'] ?? 0;
      final audioMs = result['audioMs'] ?? 0;
      final rtf = audioMs > 0 ? (generated / audioMs).toStringAsFixed(2) : 'نامعلوم';
      if (mounted) {
        setState(() {
          _status = 'نمونه Pocket پخش شد؛ تولید: $generated میلی‌ثانیه؛ '
              'مدت صدا: $audioMs میلی‌ثانیه؛ RTF: $rtf. '
              'کیفیت باید با Gyro مقایسه شود.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'آزمایش صدا ناموفق بود؛ صدای Gyro همچنان محفوظ است.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const Key('pocket-experimental-advanced'),
    initiallyExpanded: false,
    title: const Text('Pocket Farsi v2 · آزمایشی و پیشرفته'),
    subtitle: const Text('بررسی موتور آفلاین؛ بدون تغییر صدای اصلی'),
    childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    children: [
      const Text(
        'تنها برای آزمایش؛ بسته ZIP باید شامل گراف‌های ONNX، '
        'فایل‌های کمکی، توکنایزر و صدای مرجع مجاز باشد. '
        'هیچ فایل یا تنظیمات قدیمی جایگزین نمی‌شود.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('pocket-import-zip'),
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.folder_zip_outlined),
            label: const Text('افزودن بسته ZIP'),
          ),
          OutlinedButton.icon(
            key: const Key('pocket-inspect'),
            onPressed: _busy ? null : _inspect,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('بررسی بسته'),
          ),
          OutlinedButton.icon(
            key: const Key('pocket-test-voice'),
            onPressed: _busy || !_ready ? null : _trySpeech,
            icon: const Icon(Icons.play_arrow),
            label: const Text('شنیدن نمونه'),
          ),
        ],
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_status != null) Text(_status!),
      const Text(
        'قبولی این نمونه به معنی تأیید خواندن بلند، مصرف حافظه '
        'یا کیفیت مکالمه نیست. Gyro تا انتخاب و تأیید شما باقی می‌ماند.',
      ),
    ],
  );
}
