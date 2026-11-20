import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/attachments/domain/attachment.dart';
import 'package:ondevice_llm/features/chat/domain/entities/chat_message.dart';
import 'package:ondevice_llm/features/chat/domain/photo_understanding_policy.dart';
import 'package:ondevice_llm/features/chat/domain/turn_prompts.dart';

Attachment imageFixture(String path, int bytes, {String mime = 'image/png'}) =>
    Attachment(
      id: 'photo-fixture',
      kind: AttachmentKind.image,
      name: 'leaf.png',
      mime: mime,
      path: path,
      sizeBytes: bytes,
    );

void main() {
  test('only the imported Qwen3.5 4B GGUF family pairs automatically', () {
    expect(PhotoUnderstandingPolicy.isImportedQwen35FourB(
      architecture: 'qwen35', parameterCount: 4020000000,
    ), isTrue);
    expect(PhotoUnderstandingPolicy.isImportedQwen35FourB(
      architecture: 'qwen3_5', parameterCount: 4100000000,
    ), isTrue);
    for (final pair in [
      ('qwen3', 4000000000),
      ('gemma', 4000000000),
      ('qwen35', 9000000000),
      ('qwen35', 2000000000),
    ]) {
      expect(PhotoUnderstandingPolicy.isImportedQwen35FourB(
        architecture: pair.$1, parameterCount: pair.$2,
      ), isFalse);
    }
    expect(PhotoUnderstandingPolicy.isImportedQwen35FourB(
      architecture: 'qwen35', parameterCount: null,
    ), isFalse);
  });

  test('projector presence is not proof the live model can see', () {
    expect(PhotoUnderstandingPolicy.hasActiveVision(
      locallyLoaded: true,
      engineReportsVision: false,
      projectorReadyOnDisk: true,
    ), isFalse);
    expect(PhotoUnderstandingPolicy.hasActiveVision(
      locallyLoaded: true,
      engineReportsVision: true,
      projectorReadyOnDisk: false,
    ), isFalse);
    expect(PhotoUnderstandingPolicy.hasActiveVision(
      locallyLoaded: false,
      engineReportsVision: true,
      projectorReadyOnDisk: true,
    ), isFalse);
    expect(PhotoUnderstandingPolicy.hasActiveVision(
      locallyLoaded: true,
      engineReportsVision: true,
      projectorReadyOnDisk: true,
    ), isTrue);
  });

  test('a text-only model never pretends to analyze a leaf', () {
    final a = imageFixture('/test/attachments/leaf.png', 9000);
    final response = PhotoUnderstandingPolicy.refusal(
      attachments: [a], visionAvailable: false,
    )!;
    expect(response, contains('تصویر را نمی‌بیند'));
    expect(response, contains('OCR'));
    expect(response, contains('تشخیص'));
    expect(response, isNot(contains(a.path)));
  });

  test('private photo never goes to an external provider by default', () {
    final a = imageFixture('/tmp/attachments/leaf.png', 40000);
    final answer = PhotoUnderstandingPolicy.refusal(
      attachments: [a], visionAvailable: false, remoteOutsideLan: true,
    )!;
    expect(answer, contains('سرور بیرونی'));
    expect(answer, contains('فرستاده نشد'));
  });

  test('image RAM evidence includes only measured numeric OS readings', () {
    const unit = 1024 * 1024;
    final known = PhotoUnderstandingPolicy.numericResourceEvidence(
      photoCount: 1,
      visionActive: true,
      ramFreeBeforeBytes: 1800 * unit,
      ramFreeAfterBytes: 1400 * unit,
    );
    expect(known['visionPhotoCount'], 1);
    expect(known['visionActive'], true);
    expect(known['visionRamFreeBeforeMb'], 1800.0);
    expect(known['visionRamFreeAfterMb'], 1400.0);
    expect(known.toString(), isNot(contains('leaf.png')));
    final absent = PhotoUnderstandingPolicy.numericResourceEvidence(
      photoCount: 1,
      visionActive: false,
      ramFreeBeforeBytes: 0,
      ramFreeAfterBytes: null,
    );
    expect(absent.containsKey('visionRamFreeBeforeMb'), false);
    expect(absent.containsKey('visionRamFreeAfterMb'), false);
  });

  test('bounded photo allowed; excessive photos, bytes and low RAM refused',
      () {
    final a = imageFixture('/tmp/attachments/leaf.png', 40000);
    expect(PhotoUnderstandingPolicy.refusal(
      attachments: [a], visionAvailable: true,
      availableRamBytes: 2 * 1024 * 1024 * 1024,
    ), isNull);
    expect(PhotoUnderstandingPolicy.refusal(
      attachments: List.filled(3, a), visionAvailable: true,
    ), contains('دو عکس'));
    expect(PhotoUnderstandingPolicy.refusal(
      attachments: [imageFixture('/tmp/attachments/leaf.png',
        9 * 1024 * 1024)], visionAvailable: true,
    ), contains('حجم'));
    expect(PhotoUnderstandingPolicy.refusal(
      attachments: [a], visionAvailable: true,
      availableRamBytes: 700 * 1024 * 1024,
    ), contains('حافظه'));
    expect(PhotoUnderstandingPolicy.refusal(
      attachments: [imageFixture('/tmp/attachments/leaf.jpg', 40000,
        mime: 'image/jpeg')], visionAvailable: true,
    ), contains('قالب'));
  });

  test('only intact app-owned photo may be used, and no file is changed',
      () async {
    final root = await Directory.systemTemp.createTemp('pala-m17-');
    addTearDown(() => root.delete(recursive: true));
    final approved = Directory(root.path + '/attachments')..createSync();
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/R2UAAAAASUVORK5CYII=',
    );
    final f = File(approved.path + '/leaf.png')..writeAsBytesSync(bytes);
    final original = await f.readAsBytes();
    expect(await PhotoUnderstandingPolicy.verifyLocalFiles(
      [imageFixture(f.path, bytes.length)], attachmentDirectory: approved,
    ), isNull);
    expect(await PhotoUnderstandingPolicy.verifyLocalFiles(
      [imageFixture(f.path, bytes.length + 1)], attachmentDirectory: approved,
    ), contains('تطابق'));
    final outsider = File(root.path + '/other.png')..writeAsBytesSync(bytes);
    expect(await PhotoUnderstandingPolicy.verifyLocalFiles(
      [imageFixture(outsider.path, bytes.length)],
      attachmentDirectory: approved,
    ), contains('تطابق'));
    expect(await f.readAsBytes(), orderedEquals(original));
  });

  test('Persian visual instructions distinguish photo, OCR, and evidence',
      () {
    for (final phrase in [
      'فارسی', 'مشاهده', 'احتمال', 'OCR', 'دانشنامه', 'تأیید نیست',
    ]) {
      expect(PhotoUnderstandingPolicy.instruction, contains(phrase));
    }
    const a = Attachment(
      id: 'p',
      kind: AttachmentKind.image,
      name: 'leaf.png',
      mime: 'image/png',
      path: '/approved/attachments/leaf.png',
      sizeBytes: 123,
      text: 'درصد ۴۲',
      ocrConfidence: 0.4,
    );
    final msg = ChatMessage(
      id: 'fixture', role: ChatRole.user,
      timestamp: DateTime.utc(2026, 11, 20),
      content: 'برگ این درخت چه مشکلی دارد؟',
      attachments: const [a],
    );
    final visible = TurnPrompts.renderTurn(msg, vision: true);
    expect(visible['images'], ['/approved/attachments/leaf.png']);
    expect(visible['content'].toString(), contains('برگ این درخت'));
    final hidden = TurnPrompts.renderTurn(msg, vision: false);
    expect(hidden.containsKey('images'), isFalse);
    expect(hidden['content'].toString(), contains('not visible'));
  });
}
