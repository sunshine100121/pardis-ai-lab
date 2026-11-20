/// M14 extension: summarize verified Home Assistant Core REST data locally.
/// Only numerical statistics and fixed, documented system entities survive.
/// Titles, locations, tokens, entry IDs and unrelated states are discarded.
class HaDoctorIntegrationReadout {
  final int configured, loaded, problems, retrying, disabled, other;
  const HaDoctorIntegrationReadout({
    required this.configured,
    required this.loaded,
    required this.problems,
    required this.retrying,
    required this.disabled,
    required this.other,
  });
}

class HaDoctorSystemReadout {
  final String? osVersion, supervisorVersion;
  final double? processorPercent, memoryPercent, diskFreeGb;
  final DateTime? lastAutomaticBackupUtc, lastAttemptedBackupUtc;
  final String? backupManagerState;
  const HaDoctorSystemReadout({
    this.osVersion,
    this.supervisorVersion,
    this.processorPercent,
    this.memoryPercent,
    this.diskFreeGb,
    this.lastAutomaticBackupUtc,
    this.lastAttemptedBackupUtc,
    this.backupManagerState,
  });
}

abstract final class HaDoctorReadouts {
  /// Official Core endpoint: GET /api/config/config_entries/entry.
  /// 'Loaded' describes the config-entry state, not end-to-end device health.
  static HaDoctorIntegrationReadout? integrations(Object? raw) {
    if (raw is! List || raw.length > 1500) return null;
    var configured = 0, loaded = 0, problems = 0;
    var retrying = 0, disabled = 0, other = 0;
    for (final item in raw) {
      if (item is! Map || item['state'] is! String ||
          item['domain'] is! String) {
        return null;
      }
      final state = (item['state'] as String).toLowerCase();
      final disabledBy = item['disabled_by'];
      if (item['source'] == 'ignore' ||
          (disabledBy != null && disabledBy.toString().isNotEmpty)) {
        disabled++;
        continue;
      }
      configured++;
      if (state == 'loaded') {
        loaded++;
      } else if (state == 'setup_error' ||
          state == 'migration_error' ||
          state == 'failed_unload') {
        problems++;
      } else if (state == 'setup_retry') {
        retrying++;
      } else {
        // 'not_loaded' or setup_in_progress are not necessarily failures.
        other++;
      }
    }
    return HaDoctorIntegrationReadout(
      configured: configured, loaded: loaded, problems: problems,
      retrying: retrying, disabled: disabled, other: other,
    );
  }

  static final _version = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,39}$');
  static final _isoZone = RegExp(
    r'(?:Z|[+-][0-9]{2}:[0-9]{2})$',
    caseSensitive: false,
  );
  static String? _validVersion(Object? input) {
    if (input is! String || !_version.hasMatch(input.trim())) return null;
    if (input.trim().toLowerCase() == 'unknown' ||
        input.trim().toLowerCase() == 'unavailable') return null;
    return input.trim();
  }

  static double? _amount(Object? input, double min, double max) {
    final value = input is num
        ? input.toDouble()
        : double.tryParse(input?.toString() ?? '');
    return value != null && value.isFinite && value >= min && value <= max
        ? value : null;
  }

  static DateTime? _timestamp(Object? input, DateTime now) {
    if (input is! String || !_isoZone.hasMatch(input)) return null;
    final date = DateTime.tryParse(input)?.toUtc();
    if (date == null ||
        date.isAfter(now.toUtc().add(const Duration(minutes: 5))) ||
        date.isBefore(DateTime.utc(2020))) return null;
    return date;
  }

  /// One temporary Core GET /api/states list (never stored). Only known
  /// system/backup IDs are interpreted; all other entity payloads are ignored.
  /// A renamed or disabled sensor yields "unknown", never a fabricated value.
  static HaDoctorSystemReadout? system(Object? raw, DateTime now) {
    if (raw is! List || raw.length > 4000) return null;
    String? osVersion, supervisorVersion;
    double? cpu, memory, disk;
    DateTime? backupOk, backupTry;
    String? backupState;
    for (final item in raw) {
      if (item is! Map || item['entity_id'] is! String) continue;
      final id = item['entity_id'] as String;
      final state = item['state'];
      final attrs = item['attributes'] is Map
          ? item['attributes'] as Map
          : const {};
      // These IDs refer to Home Assistant's standard update and
      // optional Supervisor version entities, not to arbitrary versions.
      if (id == 'update.home_assistant_supervisor_update') {
        supervisorVersion ??= _validVersion(attrs['installed_version']);
      } else if (id == 'update.home_assistant_operating_system_update') {
        osVersion ??= _validVersion(attrs['installed_version']);
      } else if (id == 'sensor.home_assistant_supervisor_version') {
        supervisorVersion ??= _validVersion(state);
      } else if (id == 'sensor.home_assistant_operating_system_version') {
        osVersion ??= _validVersion(state);
      } else if (id == 'sensor.system_monitor_processor_use' &&
          attrs['unit_of_measurement'] == '%') {
        cpu ??= _amount(state, 0, 100);
      } else if (id == 'sensor.system_monitor_memory_use_percent' &&
          attrs['unit_of_measurement'] == '%') {
        memory ??= _amount(state, 0, 100);
      } else if (id == 'sensor.system_monitor_disk_free' &&
          (attrs['unit_of_measurement'] == 'GiB' ||
              attrs['unit_of_measurement'] == 'GB')) {
        disk ??= _amount(state, 0, 100000);
      } else if (id == 'sensor.home_assistant_host_disk_free' &&
          (attrs['unit_of_measurement'] == 'GB' ||
              attrs['unit_of_measurement'] == 'GiB')) {
        disk ??= _amount(state, 0, 100000);
      } else if (id == 'sensor.backup_last_successful_automatic_backup') {
        backupOk ??= _timestamp(state, now);
      } else if (id == 'sensor.backup_last_attempted_automatic_backup') {
        backupTry ??= _timestamp(state, now);
      } else if (id == 'sensor.backup_backup_manager_state') {
        final value = state?.toString().trim().toLowerCase();
        if (const {'idle', 'creating', 'receiving', 'restoring', 'blocked'}
            .contains(value)) backupState ??= value;
      }
    }
    return HaDoctorSystemReadout(
      osVersion: osVersion, supervisorVersion: supervisorVersion,
      processorPercent: cpu, memoryPercent: memory, diskFreeGb: disk,
      lastAutomaticBackupUtc: backupOk,
      lastAttemptedBackupUtc: backupTry,
      backupManagerState: backupState,
    );
  }
}
