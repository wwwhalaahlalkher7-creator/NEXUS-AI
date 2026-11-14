import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/resources/resource_settings.dart';

void main() {
  test('samples bounded CPU utilization and accepts valid power telemetry', () async {
    final samples = <List<String>>[
      ['cpu 100 0 50 800 50 0 0 0'],
      ['cpu 150 0 70 850 60 0 0 0'],
    ];
    final monitor = DeviceResourceMonitor(
      cpuStatReader: () async => samples.removeAt(0),
      powerThermalReader: () async => {
        'battery_level_percent': 72,
        'is_charging': true,
        'thermal_status': 2,
      },
      delay: (_) async {},
    );

    final snapshot = await monitor.readSnapshot(includeExtendedTelemetry: true);

    expect(snapshot, isNotNull);
    expect(snapshot!.cpuUtilizationPercent, 54);
    expect(snapshot.batteryLevelPercent, 72);
    expect(snapshot.isCharging, isTrue);
    expect(snapshot.thermalStatus, 2);
    expect(snapshot.cpuLogicalCores, inInclusiveRange(1, 256));
  });

  test('invalid CPU counters and unsupported power values remain unknown', () async {
    final samples = <List<String>>[
      ['cpu 100 0 50 800 50 0 0 0'],
      ['cpu 90 0 40 790 40 0 0 0'],
    ];
    final monitor = DeviceResourceMonitor(
      cpuStatReader: () async => samples.removeAt(0),
      powerThermalReader: () async => {
        'battery_level_percent': 140,
        'is_charging': 'yes',
        'thermal_status': 9,
      },
      delay: (_) async {},
    );

    final snapshot = await monitor.readSnapshot(includeExtendedTelemetry: true);

    expect(snapshot, isNotNull);
    expect(snapshot!.cpuUtilizationPercent, isNull);
    expect(snapshot.batteryLevelPercent, isNull);
    expect(snapshot.isCharging, isNull);
    expect(snapshot.thermalStatus, isNull);
  });

  test('CPU sample parser does not accept malformed or empty procfs data', () async {
    for (final sample in <List<String>>[
      const [],
      ['cpu'],
      ['cpu x 0 0 0'],
      ['cpu -1 0 0 0'],
    ]) {
      final calls = <List<String>>[sample, sample];
      final monitor = DeviceResourceMonitor(
        cpuStatReader: () async => calls.removeAt(0),
        powerThermalReader: () async => null,
        delay: (_) async {},
      );
      final snapshot = await monitor.readSnapshot(includeExtendedTelemetry: true);
      expect(snapshot?.cpuUtilizationPercent, isNull);
    }
  });
}
