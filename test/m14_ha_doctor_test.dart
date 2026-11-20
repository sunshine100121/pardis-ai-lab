import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/knowledge/ha_doctor.dart';
import 'package:ondevice_llm/features/knowledge/ha_read_client.dart';
import 'package:ondevice_llm/features/knowledge/offline_knowledge.dart';

class _TestHttp extends HttpOverrides {}
Future<T> _network<T>(Future<T> Function() action) =>
    HttpOverrides.runWithHttpOverrides(action, _TestHttp());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Recorder fixture: clear evidence, caution, no leaked private log', () {
    final snapshot = HaDoctorSnapshot(
      checkedAtUtc: DateTime.utc(2026, 1, 1),
      configRead: true,
      logRead: true,
      coreVersion: '2026.8.3',
      componentCount: 3,
      transientLog:
          'sqlite3.DatabaseError: database disk image is malformed\n'
          'sqlite3.OperationalError: disk I/O error\n'
          'Bearer FAKE_PRIVATE_CREDENTIAL',
      sensors: const [
        HaDoctorSensor('sensor.fixture', 'unavailable'),
      ],
    );
    final report = HaDoctorDiagnosis.report(
      snapshot,
      labels: const {'sensor.fixture': 'حسگر آزمایشی'},
      documentTitles: const ['راهنمای عمومی Recorder'],
    );
    expect(report, contains('نشانه خطای Recorder'));
    expect(report, contains('درجه اطمینان'));
    expect(report, contains('نسخه Core: 2026.8.3'));
    expect(report, contains('حسگر آزمایشی'));
    expect(report, contains('راهنمای عمومی Recorder'));
    expect(report, contains('نه دانشنامه'));
    expect(report, contains('علت ریشه‌ای'));
    expect(report, isNot(contains('FAKE_PRIVATE_CREDENTIAL')));
    expect(report, isNot(contains('Bearer')));
    expect(report, contains('هیچ Restart'));
  });

  test('unavailable logs never count as healthy', () {
    final report = HaDoctorDiagnosis.report(HaDoctorSnapshot(
      checkedAtUtc: DateTime.utc(2026),
      configRead: false,
      logRead: false,
      coreVersion: null,
      componentCount: null,
      transientLog: null,
      sensors: const [],
    ));
    expect(report, contains('سلامت سیستم نامعلوم'));
    expect(report, contains('لاگ در دسترس نبود'));
    expect(report, contains('OS و Supervisor'));
  });

  test('user intent recognizes Doctor but not ordinary sensor speech', () {
    expect(HaDoctorIntent.matches('چرا Home Assistant کند شده؟'), isTrue);
    expect(HaDoctorIntent.matches('چکاپ سلامت سیستم'), isTrue);
    expect(HaDoctorIntent.matches('مشکل Recorder و خطای دیتابیس'), isTrue);
    expect(HaDoctorIntent.matches('دمای باغ چقدره؟'), isFalse);
    expect(HaDoctorIntent.matches('معنای Home Assistant چیست؟'), isFalse);
  });

  test('old sensor permission alone never permits diagnostic log reading',
      () async {
    await (await SharedPreferences.getInstance()).setString(
      OfflineKnowledge.configKey,
      jsonEncode({
        'enabled': true,
        'base': 'http://127.0.0.1:8899',
        'entities': {'sensor.fixture': 'حسگر آزمایشی'},
        // old settings: no doctorEnabled flag
      }),
    );
    var readTokenCalls = 0;
    final knowledge = OfflineKnowledge(
      FolderLibrary(),
      readToken: () async {
        readTokenCalls++;
        return 'must-not-read';
      },
    );
    final answer = await knowledge.doctorReport('چکاپ سلامت سیستم');
    expect(answer, contains('فعال نیست'));
    expect(readTokenCalls, 0);
  });

  test('fixed GET URLs, bounded sensor selection, private data not exposed',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final visited = <String>[];
    final methods = <String>[];
    server.listen((req) async {
      visited.add(req.uri.path);
      methods.add(req.method);
      if (req.uri.path == '/api/config') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'version': '2026.8.3',
          'components': ['recorder', 'mqtt', 'history'],
          'location_name': 'DO_NOT_LEAK_THIS_FIXTURE',
          'latitude': 51.12345,
          'longitude': -0.12345,
        }));
      } else if (req.uri.path == '/api/error_log') {
        req.response.headers.contentType = ContentType.text;
        req.response.write(
          'sqlite3.DatabaseError: database disk image is malformed\n'
          'Bearer DO_NOT_LEAK_LOG_LINE',
        );
      } else if (req.uri.path == '/api/config/config_entries/entry') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode([
          {'domain': 'mqtt', 'state': 'loaded',
           'title': 'DO_NOT_LEAK_ENTRY_TITLE'},
        ]));
      } else if (req.uri.path == '/api/states') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode([
          {'entity_id': 'sensor.backup_last_successful_automatic_backup',
           'state': '2026-01-01T00:00:00Z'},
          {'entity_id': 'sensor.private_home_address',
           'state': 'DO_NOT_LEAK_PRIVATE_STATE',
           'attributes': {'token': 'DO_NOT_LEAK_STATE_TOKEN'}},
        ]));
      } else if (req.uri.path == '/api/states/sensor.fixture') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'entity_id': 'sensor.fixture',
          'state': 'unknown',
          'last_changed': '2026-01-01T00:00:00Z',
          'last_updated': '2026-01-01T00:00:00Z',
        }));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    final client = HaReadClient(
      base: Uri.parse('http://127.0.0.1:' + server.port.toString()),
      token: 'not-a-real-token',
      entities: {'sensor.fixture'},
      clock: () => DateTime.utc(2026, 1, 1, 1),
    );
    final snapshot = await _network(() => client.doctorSnapshot());
    final report = HaDoctorDiagnosis.report(
      snapshot, labels: const {'sensor.fixture': 'حسگر آزمایشی'},
    );
    expect(methods.every((m) => m == 'GET'), isTrue);
    expect(visited, [
      '/api/config',
      '/api/error_log',
      '/api/states/sensor.fixture',
      '/api/config/config_entries/entry',
      '/api/states',
    ]);
    expect(report, contains('نسخه Core: 2026.8.3'));
    expect(report, contains('خطای Recorder'));
    for (final secret in [
      'DO_NOT_LEAK_THIS_FIXTURE',
      'DO_NOT_LEAK_LOG_LINE',
      '51.12345',
      '-0.12345',
      'not-a-real-token',
      'DO_NOT_LEAK_ENTRY_TITLE',
      'DO_NOT_LEAK_PRIVATE_STATE',
      'DO_NOT_LEAK_STATE_TOKEN',
    ]) {
      expect(report, isNot(contains(secret)));
    }
  });

  test('denied log endpoint is unknown, not interpreted as empty', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      if (req.uri.path == '/api/config') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'version': '2026.8.3'}));
      } else {
        req.response.statusCode = 403;
      }
      await req.response.close();
    });
    final client = HaReadClient(
      base: Uri.parse('http://127.0.0.1:' + server.port.toString()),
      token: 'fixture',
      entities: {'sensor.fixture'},
    );
    final report = HaDoctorDiagnosis.report(
      await _network(() => client.doctorSnapshot()),
    );
    expect(report, contains('لاگ در دسترس نبود'));
    expect(report, isNot(contains('کاملاً سالم است')));
  });
}
