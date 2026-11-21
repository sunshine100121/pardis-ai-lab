import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/ha_doctor.dart';
import 'package:ondevice_llm/features/knowledge/ha_doctor_readouts.dart';

void main() {
  test(
    'official Core config-entry states are counted without private data',
    () {
      final rows = [
        {
          'domain': 'mqtt',
          'state': 'loaded',
          'title': 'OWNER_HOME_NAME',
          'entry_id': 'PRIVATE_ID',
        },
        {'domain': 'esphome', 'state': 'setup_retry'},
        {'domain': 'fixture', 'state': 'setup_error', 'title': 'PRIVATE_HOST'},
        {'domain': 'test', 'state': 'not_loaded'},
        {'domain': 'disabled', 'state': 'setup_error', 'disabled_by': 'user'},
        {'domain': 'ignored', 'state': 'not_loaded', 'source': 'ignore'},
      ];
      final result = HaDoctorReadouts.integrations(rows)!;
      expect(result.configured, 4);
      expect(result.loaded, 1);
      expect(result.retrying, 1);
      expect(result.problems, 1);
      expect(result.other, 1);
      expect(result.disabled, 2);
      final report = HaDoctorDiagnosis.report(
        HaDoctorSnapshot(
          checkedAtUtc: DateTime.utc(2026, 11, 20),
          configRead: true,
          logRead: false,
          coreVersion: '2026.8.3',
          transientLog: null,
          componentCount: 10,
          sensors: const [],
          integrations: result,
        ),
      );
      expect(report, contains('Integration'));
      expect(report, contains('خطای راه‌اندازی'));
      expect(report, contains('عمداً غیرفعال'));
      expect(report, isNot(contains('OWNER_HOME_NAME')));
      expect(report, isNot(contains('PRIVATE_HOST')));
      expect(report, isNot(contains('PRIVATE_ID')));
      expect(report, contains('درجه اطمینان'));
      expect(report, contains('هیچ Restart'));
    },
  );

  test('system and backup metrics use only known official entity IDs', () {
    final now = DateTime.utc(2026, 11, 20, 12);
    final rows = [
      {
        'entity_id': 'update.home_assistant_supervisor_update',
        'state': 'off',
        'attributes': {'installed_version': '2026.11.2'},
      },
      {
        'entity_id': 'update.home_assistant_operating_system_update',
        'state': 'off',
        'attributes': {'installed_version': '18.1'},
      },
      {
        'entity_id': 'sensor.system_monitor_processor_use',
        'state': '34.5',
        'attributes': {'unit_of_measurement': '%'},
      },
      {
        'entity_id': 'sensor.system_monitor_memory_use_percent',
        'state': '51.0',
        'attributes': {'unit_of_measurement': '%'},
      },
      {
        'entity_id': 'sensor.home_assistant_host_disk_free',
        'state': '170.0',
        'attributes': {'unit_of_measurement': 'GB'},
      },
      {
        'entity_id': 'sensor.backup_last_successful_automatic_backup',
        'state': '2026-11-18T03:00:00Z',
      },
      {
        'entity_id': 'sensor.backup_last_attempted_automatic_backup',
        'state': '2026-11-19T03:00:00Z',
      },
      {'entity_id': 'sensor.backup_backup_manager_state', 'state': 'idle'},
      {
        'entity_id': 'sensor.private_camera_location',
        'state': 'DO_NOT_LEAK',
        'attributes': {
          'token': 'PRIVATE_TOKEN',
          'friendly_name': 'PRIVATE_LOCATION_NAME',
        },
      },
    ];
    final read = HaDoctorReadouts.system(rows, now)!;
    expect(read.supervisorVersion, '2026.11.2');
    expect(read.osVersion, '18.1');
    expect(read.processorPercent, 34.5);
    expect(read.memoryPercent, 51);
    expect(read.diskFreeGb, 170);
    expect(read.backupManagerState, 'idle');
    expect(read.lastAutomaticBackupUtc, DateTime.utc(2026, 11, 18, 3));
    final report = HaDoctorDiagnosis.report(
      HaDoctorSnapshot(
        checkedAtUtc: now,
        configRead: true,
        logRead: false,
        coreVersion: '2026.8.3',
        transientLog: null,
        componentCount: 5,
        sensors: const [],
        system: read,
      ),
    );
    expect(report, contains('نسخه OS و Supervisor'));
    expect(report, contains('2026.11.2'));
    expect(report, contains('34.5 %'));
    expect(report, contains('آخرین بکاپ خودکار موفق'));
    expect(report, contains('بکاپ‌های دستی'));
    for (final value in [
      'DO_NOT_LEAK',
      'PRIVATE_TOKEN',
      'PRIVATE_LOCATION_NAME',
      'private_camera_location',
    ]) {
      expect(report, isNot(contains(value)));
    }
  });

  test('missing or disabled system sensors remain unknown, not zero', () {
    final result = HaDoctorReadouts.system([
      {
        'entity_id': 'sensor.system_monitor_processor_use',
        'state': 'unavailable',
        'attributes': {'unit_of_measurement': '%'},
      },
      {
        'entity_id': 'sensor.home_assistant_host_disk_free',
        'state': '-20',
        'attributes': {'unit_of_measurement': 'GB'},
      },
      {
        'entity_id': 'sensor.backup_last_successful_automatic_backup',
        'state': 'unavailable',
      },
      {
        'entity_id': 'sensor.some_other_processor',
        'state': '90',
        'attributes': {'unit_of_measurement': '%'},
      },
    ], DateTime.utc(2026, 11, 20))!;
    expect(result.processorPercent, isNull);
    expect(result.memoryPercent, isNull);
    expect(result.diskFreeGb, isNull);
    expect(result.lastAutomaticBackupUtc, isNull);
    final report = HaDoctorDiagnosis.report(
      HaDoctorSnapshot(
        checkedAtUtc: DateTime.utc(2026, 11, 20),
        configRead: true,
        logRead: false,
        coreVersion: '2026.8.3',
        transientLog: null,
        componentCount: null,
        sensors: const [],
        system: result,
      ),
    );
    expect(report, contains('نامعلوم یا حسگر غیرفعال'));
    expect(report, contains('بکاپ‌های دستی'));
    expect(report, isNot(contains('90.0 %')));
  });

  test('out of range numbers and future timestamps are never trusted', () {
    final parsed = HaDoctorReadouts.system([
      {
        'entity_id': 'sensor.system_monitor_memory_use_percent',
        'state': '130',
        'attributes': {'unit_of_measurement': '%'},
      },
      {
        'entity_id': 'sensor.backup_last_attempted_automatic_backup',
        'state': '2026-12-11T00:00:00Z',
      },
      {
        'entity_id': 'sensor.backup_last_successful_automatic_backup',
        'state': '2026-11-19T03:00:00',
      },
      {
        'entity_id': 'sensor.home_assistant_supervisor_version',
        'state': 'unavailable',
      },
    ], DateTime.utc(2026, 11, 20))!;
    expect(parsed.memoryPercent, isNull);
    expect(parsed.lastAttemptedBackupUtc, isNull);
    expect(parsed.lastAutomaticBackupUtc, isNull);
    expect(parsed.supervisorVersion, isNull);
  });

  test('unreadable or malformed data cannot become healthy', () {
    expect(HaDoctorReadouts.integrations(null), isNull);
    expect(HaDoctorReadouts.integrations({'state': 'loaded'}), isNull);
    expect(
      HaDoctorReadouts.integrations([
        {'state': 'loaded'},
      ]),
      isNull,
    );
    expect(HaDoctorReadouts.system('bad', DateTime.utc(2026)), isNull);
    expect(
      HaDoctorReadouts.system(
        List.generate(4001, (i) => {'entity_id': 'sensor.fixture_$i'}),
        DateTime.utc(2026),
      ),
      isNull,
    );
  });
}
