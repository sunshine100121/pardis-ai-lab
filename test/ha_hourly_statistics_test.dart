import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/ha_hourly_statistics.dart';
import 'package:ondevice_llm/features/knowledge/hourly_pattern.dart';

void main() {
  test('only private LAN connections and allow-listed sensor names', () {
    final reader = HaHourlyStatistics(
      base: Uri.parse('http://${InternetAddress.loopbackIPv4.address}:8123'),
      token: 'fake-test-token',
      entities: {'sensor.example'},
    );
    expect(HaHourlyStatistics.wsUri(reader.base).scheme, 'ws');
    expect(HaHourlyStatistics.wsUri(reader.base).path, '/api/websocket');
    expect(
      () => HaHourlyStatistics(
        base: Uri.parse('https://example.org'),
        token: 'fake-test-token',
        entities: {'sensor.example'},
      ),
      throwsFormatException,
    );
  });

  test('parse hourly statistics: missing means stay missing', () {
    final from = DateTime.utc(2026, 1, 1);
    final end = from.add(const Duration(hours: 3));
    final rows = HaHourlyStatistics.parseStatistics(
      {
        'sensor.example': [
          {'start': from.millisecondsSinceEpoch, 'mean': 13.0},
          {'start': from.add(const Duration(hours: 1)).millisecondsSinceEpoch},
        ],
      },
      'sensor.example',
      from,
      end,
    );
    expect(rows.length, 2);
    expect(rows[0].mean, 13);
    expect(rows[1].mean, isNull);
    expect(
      HaHourlyStatistics.parseStatistics({}, 'sensor.example', from, end),
      isEmpty,
    );
    expect(
      () => HaHourlyStatistics.parseStatistics(
        {'sensor.other': []},
        'sensor.example',
        from,
        end,
      ),
      throwsFormatException,
    );
  });

  test(
    'local WebSocket mock only receives auth and read-only statistics request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final from = DateTime.utc(2026, 1, 1);
      final until = from.add(const Duration(hours: 2));
      final kinds = <String>[];
      server.transform(WebSocketTransformer()).listen((socket) {
        socket.add(jsonEncode({'type': 'auth_required'}));
        socket.listen((message) {
          final request = jsonDecode(message as String) as Map<String, dynamic>;
          kinds.add(request['type'] as String);
          if (request['type'] == 'auth') {
            expect(request['access_token'], 'fake-test-token');
            socket.add(jsonEncode({'type': 'auth_ok'}));
          } else if (request['type'] == 'recorder/statistics_during_period') {
            expect(request['period'], 'hour');
            expect(request['types'], ['mean', 'min', 'max']);
            expect(request['statistic_ids'], ['sensor.example']);
            socket.add(
              jsonEncode({
                'type': 'result',
                'id': 1,
                'success': true,
                'result': {
                  'sensor.example': [
                    {
                      'start': from.millisecondsSinceEpoch,
                      'mean': 7.5,
                      'min': 5,
                      'max': 9,
                    },
                  ],
                },
              }),
            );
          }
        });
      });
      final reader = HaHourlyStatistics(
        base: Uri.parse(
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
        ),
        token: 'fake-test-token',
        entities: {'sensor.example'},
      );
      final data = await reader.read(
        entityId: 'sensor.example',
        fromUtc: from,
        toUtc: until,
      );
      expect(data.length, 1);
      expect(data.single.mean, 7.5);
      expect(data.single.minimum, 5);
      expect(data.single.maximum, 9);
      expect(kinds, ['auth', 'recorder/statistics_during_period']);
    },
  );

  test('unaligned request bounds fail before any network call', () async {
    final reader = HaHourlyStatistics(
      base: Uri.parse('http://127.0.0.1:8123'),
      token: 'fake-test-token',
      entities: {'sensor.example'},
    );
    final from = DateTime.utc(2026, 1, 1, 0, 30);
    final until = DateTime.utc(2026, 1, 2);
    await expectLater(
      reader.read(entityId: 'sensor.example', fromUtc: from, toUtc: until),
      throwsFormatException,
    );
  });

  test('insufficient coverage never invents a routine pollution peak', () {
    final start = DateTime.utc(2026, 1, 1);
    final end = start.add(const Duration(days: 10));
    final report = HaHourlyStatistics.report(
      entityId: 'sensor.example',
      fromUtc: start,
      toUtc: end,
      samples: [HourlyValue(start, 99)],
    );
    expect(report['recurring_peak_supported'], isFalse);
    expect(report['peak_hour_local'], isNull);
    expect(report['valid_hours'], 1);
  });
  test('redirected handshake never contacts another origin or sends auth', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    addTearDown(() => source.close(force: true));
    var targetRequests = 0;
    target.listen((request) {
      targetRequests++;
      request.response.close();
    });
    source.listen((request) {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://${InternetAddress.loopbackIPv4.address}:${target.port}/api/websocket',
      );
      request.response.close();
    });
    final reader = HaHourlyStatistics(
      base: Uri.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${source.port}',
      ),
      token: 'fake-test-token',
      entities: {'sensor.example'},
    );
    await expectLater(
      reader.read(
        entityId: 'sensor.example',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ),
      throwsA(isA<WebSocketException>()),
    );
    expect(targetRequests, 0);
  });

  test('one total deadline covers all handshake and statistics messages and closes socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final closed = Completer<void>();
    server.transform(WebSocketTransformer()).listen((socket) {
      void later(Map<String, dynamic> frame) {
        Timer(const Duration(milliseconds: 60), () {
          if (socket.readyState == WebSocket.open)
            socket.add(jsonEncode(frame));
        });
      }

      later({'type': 'auth_required'});
      socket.listen(
        (message) {
          final frame = jsonDecode(message as String) as Map;
          if (frame['type'] == 'auth') {
            later({'type': 'auth_ok'});
          } else {
            later({
              'id': 1,
              'type': 'result',
              'success': true,
              'result': {'sensor.example': []},
            });
          }
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object error) {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final reader = HaHourlyStatistics(
      base: Uri.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
      ),
      token: 'fake-test-token',
      entities: {'sensor.example'},
      timeLimit: const Duration(milliseconds: 140),
    );
    await expectLater(
      reader.read(
        entityId: 'sensor.example',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test('oversized websocket message fails before parsing statistics', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.transform(WebSocketTransformer()).listen((socket) {
      socket.add(jsonEncode({'type': 'auth_required'}));
      socket.listen((message) {
        final frame = jsonDecode(message as String) as Map;
        if (frame['type'] == 'auth') {
          socket.add(jsonEncode({'type': 'auth_ok'}));
        } else {
          socket.add('x'.padRight(6 * 1024 * 1024 + 1, 'x'));
        }
      }, onError: (Object error) {});
    });
    final reader = HaHourlyStatistics(
      base: Uri.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
      ),
      token: 'fake-test-token',
      entities: {'sensor.example'},
    );
    await expectLater(
      reader.read(
        entityId: 'sensor.example',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ),
      throwsA(anyOf(isA<WebSocketException>(), isA<FormatException>())),
    );
  });

  test(
    'invalid timestamps, duplicate buckets and nonfinite means fail closed',
    () {
      final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 1, 2);
      for (final stamp in [
        double.nan,
        double.infinity,
        start.millisecondsSinceEpoch + 0.5,
      ]) {
        expect(
          () => HaHourlyStatistics.parseStatistics(
            {
              'sensor.example': [
                {'start': stamp, 'mean': 2},
              ],
            },
            'sensor.example',
            start,
            end,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => HaHourlyStatistics.parseStatistics(
          {
            'sensor.example': [
              {'start': start.millisecondsSinceEpoch, 'mean': 2},
              {'start': start.millisecondsSinceEpoch, 'mean': 3},
            ],
          },
          'sensor.example',
          start,
          end,
        ),
        throwsFormatException,
      );
      expect(
        () => HaHourlyStatistics.parseStatistics(
          {
            'sensor.example': [
              {'start': start.millisecondsSinceEpoch, 'mean': double.infinity},
            ],
          },
          'sensor.example',
          start,
          end,
        ),
        throwsFormatException,
      );
      expect(
        () => HaHourlyStatistics.parseStatistics(
          {'sensor.example': List.filled(10001, {})},
          'sensor.example',
          start,
          end,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'constructor retains an immutable allow-list and rejects unbounded timeout',
    () async {
      final entities = {'sensor.example'};
      final reader = HaHourlyStatistics(
        base: Uri.parse('http://${InternetAddress.loopbackIPv4.address}:8123'),
        token: 'fake-test-token',
        entities: entities,
      );
      entities.add('sensor.other');
      await expectLater(
        reader.read(
          entityId: 'sensor.other',
          fromUtc: DateTime.utc(2026, 1, 1),
          toUtc: DateTime.utc(2026, 1, 2),
        ),
        throwsFormatException,
      );
      expect(
        () => HaHourlyStatistics(
          base: reader.base,
          token: 'fake-test-token',
          entities: entities,
          timeLimit: const Duration(minutes: 5),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'a complete six-month mock reports explicit half-hour local intervals',
    () {
      final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 7, 1);
      final samples = <HourlyValue>[];
      for (
        var at = start;
        at.isBefore(end);
        at = at.add(const Duration(hours: 1))
      ) {
        samples.add(HourlyValue(at, at.hour == 0 ? 80 : 10));
      }
      final report = HaHourlyStatistics.report(
        entityId: 'sensor.example',
        fromUtc: start,
        toUtc: end,
        samples: samples,
        utcOffsetAt: (_) => const Duration(hours: 3, minutes: 30),
      );
      expect(report['recurring_peak_supported'], true);
      expect(report['coverage'], 1);
      expect(report['peak_interval_local'], '03:30–04:30');
      expect(
        (report['hours'] as List).every((h) => h['start_minutes'].single == 30),
        true,
      );
      expect(jsonEncode(report), isNot(contains('fake-test-token')));
    },
  );

  test('flat complete data has no unique habitual peak', () {
    final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 1, 3);
    final report = HaHourlyStatistics.report(
      entityId: 'sensor.example',
      fromUtc: start,
      toUtc: end,
      samples: [
        for (var i = 0; i < 48; i++)
          HourlyValue(start.add(Duration(hours: i)), 7),
      ],
      utcOffsetAt: (_) => Duration.zero,
    );
    expect(report['coverage_adequate'], true);
    expect(report['recurring_peak_supported'], false);
    expect(report['peak_hour_local'], isNull);
  });
}
