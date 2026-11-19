import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/data/network/web_search/search_models.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/knowledge/knowledge_read_report.dart';
import 'package:ondevice_llm/features/knowledge/offline_knowledge.dart';

class UnrelatedLibrary extends FolderLibrary {
  @override
  Future<KnowledgeReadReport> searchDetailed(
    String question, {
    Set<String>? sourceIds,
  }) async => sourceIds != null
      ? const KnowledgeReadReport([], [])
      : const KnowledgeReadReport([
          SearchResult(
            title: 'Fixture encyclopedia',
            url: 'zim://fixture/article',
            snippet: '',
            rank: 1,
            pageText: 'Unrelated article text',
          ),
        ], []);
}

class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() action) =>
    HttpOverrides.runWithHttpOverrides(action, _RealHttpOverrides());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> config(int port, Map<String, String> entities) async {
    await (await SharedPreferences.getInstance()).setString(
      OfflineKnowledge.configKey,
      jsonEncode({
        'enabled': true,
        'base': 'http://${InternetAddress.loopbackIPv4.address}:$port',
        'entities': entities,
      }),
    );
  }


  test('over eight approved sensors: Persian garden and rosemary use one GET each', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((req) async {
      expect(req.method, 'GET');
      paths.add(req.uri.path);
      final garden = req.uri.path.endsWith('sensor.garden_temperature');
      final rosemary = req.uri.path.endsWith('sensor.rosemary_soil_moisture');
      expect(garden || rosemary, isTrue);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'entity_id': garden
            ? 'sensor.garden_temperature'
            : 'sensor.rosemary_soil_moisture',
        'state': garden ? '18.5' : '31',
        'last_changed': '2026-11-19T11:45:00Z',
        'last_updated': '2026-11-19T11:50:00Z',
        'last_reported': '2026-11-19T11:55:00Z',
        'attributes': {
          'unit_of_measurement': garden ? '°C' : '%',
        },
      }));
      await req.response.close();
    });
    final allowed = <String, String>{
      for (var n = 0; n < 90; n++)
        'sensor.fixture_$n': 'حسگر آزمایشی شماره $n',
      'sensor.garden_temperature': 'دمای باغ',
      'sensor.rosemary_soil_moisture': 'رطوبت خاک رزماری',
    };
    await config(server.port, allowed);
    final knowledge = OfflineKnowledge(
      UnrelatedLibrary(),
      readToken: () async => 'test-only-token',
      clock: () => DateTime.utc(2026, 11, 19, 12),
    );
    final garden = await _withRealHttp(
      () => knowledge.sensorCurrentValue('دمای باغ چقدره؟'),
    );
    final rosemary = await _withRealHttp(
      () => knowledge.sensorCurrentValue('رطوبت خاک رزماری چطوره؟'),
    );
    expect(garden, contains('18.5 °C'));
    expect(garden, contains('Home Assistant'));
    expect(garden, isNot(contains('Fixture encyclopedia')));
    expect(rosemary, contains('31 %'));
    expect(rosemary, isNot(contains('Fixture encyclopedia')));
    expect(paths, [
      '/api/states/sensor.garden_temperature',
      '/api/states/sensor.rosemary_soil_moisture',
    ]);
  });

  test('ambiguous garden sensors: no token or GET and names stay Persian', () async {
    await config(9999, {
      'sensor.east_temperature': 'دمای محوطه شرقی باغ',
      'sensor.west_temperature': 'دمای محوطه غربی باغ',
    });
    var tokenReads = 0;
    final knowledge = OfflineKnowledge(
      UnrelatedLibrary(),
      readToken: () async {
        tokenReads++;
        return 'must-not-be-read';
      },
    );
    final answer = await knowledge.sensorCurrentValue('دمای باغ چقدره؟');
    expect(answer, contains('دمای محوطه شرقی باغ'));
    expect(answer, contains('دمای محوطه غربی باغ'));
    expect(answer, contains('برای جلوگیری از اشتباه'));
    expect(answer, isNot(contains('sensor.east_temperature')));
    expect(tokenReads, 0);
  });

  test(
    'timestamp question reads one approved sensor, not a wiki article',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((req) async {
        requests++;
        expect(req.method, 'GET');
        expect(req.uri.path, '/api/states/sensor.fixture_pm25');
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'entity_id': 'sensor.fixture_pm25',
            'state': '13',
            'last_changed': '2026-11-19T11:40:00Z',
            'last_updated': '2026-11-19T11:50:00Z',
            'last_reported': '2026-11-19T11:55:00Z',
          }),
        );
        await req.response.close();
      });
      await config(server.port, {'sensor.fixture_pm25': 'PM2.5 باغ'});
      final knowledge = OfflineKnowledge(
        UnrelatedLibrary(),
        readToken: () async => 'test-only-token',
        clock: () => DateTime.utc(2026, 11, 19, 12),
      );
      final answer = await _withRealHttp(
        () => knowledge.sensorLastUpdate(
          'آخرین به‌روزرسانی حسگر PM2.5 باغ چه زمانی بوده؟',
        ),
      );
      expect(answer, contains('منبع: Home Assistant'));
      expect(answer, contains('PM2.5 باغ'));
      expect(answer, contains('زمان دریافت اطلاعات توسط پالا'));
      expect(answer, contains('آخرین تغییر مقدار حسگر'));
      expect(answer, contains('آخرین گزارش ثبت‌شده'));
      expect(answer, contains('5 دقیقه'));
      expect(answer, isNot(contains('Fixture encyclopedia')));
      expect(requests, 1);
    },
  );

  test(
    'ambiguous sensor does not read credentials or guess timestamps',
    () async {
      await config(9999, {'sensor.one': 'رطوبت باغ', 'sensor.two': 'دما باغ'});
      var tokenReads = 0;
      final knowledge = OfflineKnowledge(
        UnrelatedLibrary(),
        readToken: () async {
          tokenReads++;
          return 'not-read';
        },
      );
      final ambiguous = await knowledge.sensorLastUpdate(
        'آخرین به‌روزرسانی حسگر چه زمانی بوده؟',
      );
      expect(ambiguous, contains('نام حسگر مشخص نیست'));
      expect(tokenReads, 0);
      final denied = await knowledge.sensorLastUpdate(
        'آخرین گزارش سنسور دما باغ',
        permitted: false,
      );
      expect(denied, contains('مجاز نشده'));
      expect(tokenReads, 0);
    },
  );

  test(
    'garden and pollutant conflicts fail before any credential or network use',
    () async {
      await config(1, {
        'sensor.fixture_inside': 'آلودگی داخل ساختمان',
        'sensor.fixture_co2': 'آلودگی CO2 باغ',
      });
      var credentialReads = 0;
      final knowledge = OfflineKnowledge(
        UnrelatedLibrary(),
        readToken: () async {
          credentialReads++;
          throw StateError('must not read credential');
        },
      );
      for (final query in [
        'آلودگی داخل ساختمان در باغ طی شش ماه',
        'PM2.5 باغ در شش ماه',
        'آلودگی CO2 باغ برای PM2.5 چقدر است؟',
      ]) {
        final result = await knowledge.searchDetailed(query);
        expect(result.sources.where((s) => s.url.startsWith('zim:')), isEmpty);
        expect(
          result.checks.single['code'],
          anyOf('ha_ambiguous', 'ha_unavailable'),
        );
      }
      expect(credentialReads, 0);
    },
  );
  test(
    'current pollution question without configured HA cannot use a ZIM guess',
    () async {
      final result = await OfflineKnowledge(
        UnrelatedLibrary(),
        readToken: () async => throw StateError('must not read credential'),
      ).searchDetailed('آلودگی باغ چقدر است؟');
      expect(result.sources, isEmpty);
      expect(result.checks.single['code'], 'ha_unavailable');
    },
  );
  test('insufficient hourly coverage survives integration and cannot become success', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({'type': 'auth_required'}));
      await for (final frame in ws) {
        final data = jsonDecode(frame as String) as Map;
        seen.add(data['type'] as String);
        if (data['type'] == 'auth') {
          ws.add(jsonEncode({'type': 'auth_ok'}));
        } else {
          expect(data['type'], 'recorder/statistics_during_period');
          expect(data['statistic_ids'], ['sensor.fixture_pm25']);
          ws.add(
            jsonEncode({
              'id': data['id'],
              'type': 'result',
              'success': true,
              'result': {'sensor.fixture_pm25': []},
            }),
          );
        }
      }
    });
    await config(server.port, {'sensor.fixture_pm25': 'PM2.5 باغ'});
    final knowledge = OfflineKnowledge(
      UnrelatedLibrary(),
      readToken: () async => 'synthetic-test-only',
      clock: () => DateTime.utc(2026, 11, 16, 12, 34),
    );
    await _withRealHttp(() async {
      final result = await knowledge.searchDetailed('PM2.5 باغ در شش ماه');
      expect(result.checks.single['code'], 'ha_insufficient');
      expect(
        result.sources.where((s) => s.url.startsWith('pala-ha:')),
        isEmpty,
      );
      expect(seen, ['auth', 'recorder/statistics_during_period']);
    });
  });
  test(
    'successful current sensor supersedes unrelated encyclopedia evidence',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        expect(req.method, 'GET');
        req.response.write(
          jsonEncode({
            'entity_id': 'sensor.fixture_pm25',
            'state': '12',
            'last_updated': '2026-11-16T10:00:00Z',
            'attributes': {'unit_of_measurement': 'µg/m³'},
          }),
        );
        await req.response.close();
      });
      await config(server.port, {'sensor.fixture_pm25': 'PM2.5 باغ'});
      await _withRealHttp(() async {
        final result = await OfflineKnowledge(
          UnrelatedLibrary(),
          readToken: () async => 'synthetic-test-only',
        ).searchDetailed('آلودگی باغ چقدر است؟');
        expect(result.sources, hasLength(1));
        expect(result.sources.single.url, startsWith('pala-ha://sensor'));
        expect(
          result.sources.single.pageText,
          contains('"freshness":"unverified"'),
        );
        expect(result.checks, isEmpty);
      });
    },
  );
}
