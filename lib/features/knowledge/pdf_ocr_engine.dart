import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_ocr_models.dart';

typedef PdfOcrReading = ({String text, int confidence});

/// Opt-in local Persian/English page recognition. Render and OCR one page
/// at a time with bounded dimensions; never send documents to web services.
class PdfOcrEngine {
  static const MethodChannel channel = MethodChannel('pala/pdf_ocr');

  static Future<PdfOcrReading?> recognize(PdfPage page) async {
    if (!await PdfOcrModels.ready()) {
      throw StateError('مدل‌های OCR فارسی و انگلیسی هنوز آماده نشده‌اند');
    }
    final maxDimension = math.max(page.width, page.height);
    if (maxDimension <= 0) throw StateError('ابعاد PDF نامعتبر است');
    final scale = math.min(2.2, 1800.0 / maxDimension);
    final image = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
    if (image == null) return null;
    Uint8List? png;
    try {
      final uiImage = await image.createImage();
      try {
        final bytes = await uiImage.toByteData(format: ui.ImageByteFormat.png);
        png = bytes?.buffer.asUint8List();
      } finally {
        uiImage.dispose();
      }
    } finally {
      image.dispose();
    }
    if (png == null || png.isEmpty || png.length > 12 * 1024 * 1024) {
      throw StateError('تصویر صفحه برای OCR بیش از حد بزرگ است');
    }
    final dataPath = (await PdfOcrModels.dataDirectory()).path;
    final answer = await channel.invokeMapMethod<String, dynamic>(
      'recognize',
      {
        'png': png,
        'dataPath': dataPath,
        'language': 'fas+eng',
      },
    );
    final text = answer?['text'] as String? ?? '';
    final confidence = (answer?['confidence'] as num?)?.toInt() ?? 0;
    // Below threshold, treat uncertain OCR as missing evidence, never as
    // an authoritative quotation to be cited by Qwen.
    if (text.trim().isEmpty || confidence < 35) return null;
    return (
      text: text.length > 65536 ? text.substring(0, 65536) : text,
      confidence: confidence,
    );
  }
}
