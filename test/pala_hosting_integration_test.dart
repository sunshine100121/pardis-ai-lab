import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/hosting/device_model_server.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/zim/zim_grounding.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';
import 'device_model_server_test.dart' show FakeEngine;

void main() {
  test(
    'refused peer cannot release another request wake lease; stop during lookup never generates',
    () async {
      final engine = FakeEngine();
      final entered = Completer<void>();
      final resume = Completer<void>();
      final work = <bool>[];
      final finished = Completer<void>();
      final server = DeviceModelServer(
        engine: engine,
        settings: () => const InferenceSettings(),
        modelId: 'test',
        fallbackTemplate: 'chatml',
        accessToken: 'a' * 32,
        onWork: (v) async {
          work.add(v);
        },
        onServed: (r) {
          if (r.completion && !finished.isCompleted) finished.complete();
        },
        groundMessages: (m) async {
          entered.complete();
          await resume.future;
          return (messages: m, footer: '');
        },
      );
      await server.start();
      addTearDown(server.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<void> send(bool auth) async {
        final r = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
        );
        if (auth) r.headers.set('Authorization', 'Bearer ${'a' * 32}');
        r.write(
          jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'Paris'},
            ],
          }),
        );
        try {
          await (await r.close()).drain<void>();
        } on HttpException {
          /* Server stop closes peer. */
        }
      }

      final pending = send(true);
      await entered.future.timeout(const Duration(seconds: 5));
      await send(false);
      expect(work, [true]);
      await server.stop();
      resume.complete();
      await pending;
      await finished.future.timeout(const Duration(seconds: 5));
      expect(work, [true, false]);
      expect(engine.received, isEmpty);
    },
  );
  test(
    'authenticated LAN completion retrieves tablet evidence and balances work lease',
    () async {
      final engine = FakeEngine();
      final work = <bool>[];
      final wiki = ZimWikipedia('test/fixtures/zim/mini.zim');
      addTearDown(wiki.close);
      final server = DeviceModelServer(
        engine: engine,
        settings: () => const InferenceSettings(),
        modelId: 'test',
        fallbackTemplate: 'chatml',
        accessToken: 'a' * 32,
        onWork: (v) async {
          work.add(v);
        },
        groundMessages: (m) => ZimGrounding.prepare(m, wiki),
      );
      await server.start();
      addTearDown(server.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<HttpClientResponse> send(bool auth) async {
        final r = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
        );
        if (auth) r.headers.set('Authorization', 'Bearer ${'a' * 32}');
        r.write(
          jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'Paris'},
            ],
          }),
        );
        return r.close();
      }

      final refused = await send(false);
      await refused.drain<void>();
      expect(refused.statusCode, 401);
      expect(work, isEmpty);
      final response = await send(true);
      final responseText = await utf8.decoder.bind(response).join();
      expect(responseText, contains('منابع بازیابی'));
      expect(responseText, contains('Wikipedia test'));
      expect(response.statusCode, 200);
      expect(engine.lastMessages.first['content'], contains('Wikipedia test'));
      expect(engine.lastMessages.first['content'], contains('Paris'));
      expect(work, [true, false]);
    },
  );
}
