import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/devices/device_record.dart';
import 'package:nexus_app/src/features/devices/peer_task_execution.dart';
import 'package:nexus_app/src/features/resources/peer_resource_advisor.dart';
import 'package:nexus_app/src/features/resources/peer_model_profile.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/model_fit_estimator.dart';

PairedDeviceRecord peer({
  required String id,
  required String name,
  required int memory,
  required int cores,
  required int updatedAt,
  int activeExecutions = 0,
  bool blocked = false,
  bool supportsExecution = true,
  int? cpuLoad,
  int? battery,
  bool? charging,
  int? thermal,
}) {
  return PairedDeviceRecord(
    id: id,
    displayName: name,
    platform: 'android',
    lastAddress: '192.168.1.10',
    lastPort: 47831,
    fingerprint: 'fingerprint-$id',
    capabilities: {
      'task_execution': supportsExecution,
      'task_execution_version': peerTaskExecutionVersion,
      'resource_profile_version': peerResourceProfileVersion,
      'resource_profile_updated_at_unix_ms': updatedAt,
      'available_memory_bytes': memory,
      'total_memory_bytes': memory * 2,
      'cpu_logical_cores': cores,
      'active_peer_executions': activeExecutions,
      if (cpuLoad != null) 'cpu_utilization_percent': cpuLoad,
      if (battery != null) 'battery_level_percent': battery,
      if (charging != null) 'is_charging': charging,
      if (thermal != null) 'thermal_status': thermal,
    },
    trustStatus: blocked ? 'blocked' : 'trusted',
    pairedAtUnixMs: updatedAt,
    lastSeenUnixMs: updatedAt,
    createdAtUnixMs: updatedAt,
  );
}

void main() {
  final now = DateTime.utc(2026, 11, 14, 11).millisecondsSinceEpoch;
  final instant = DateTime.fromMillisecondsSinceEpoch(now, isUtc: true);

  test('fresh compatible peers are ranked by available RAM then CPU cores', () {
    final peers = [
      peer(
        id: 'a',
        name: 'Alpha',
        memory: 2 * 1024 * 1024 * 1024,
        cores: 8,
        updatedAt: now,
      ),
      peer(
        id: 'b',
        name: 'Beta',
        memory: 4 * 1024 * 1024 * 1024,
        cores: 4,
        updatedAt: now,
      ),
      peer(
        id: 'c',
        name: 'Gamma',
        memory: 4 * 1024 * 1024 * 1024,
        cores: 8,
        updatedAt: now,
      ),
    ];

    final ranked = PeerExecutionPlacementAdvisor.rank(
      devices: peers,
      connectedDeviceIds: {'a', 'b', 'c'},
      now: instant,
    );

    expect(ranked.map((item) => item.device.id), ['c', 'b', 'a']);
    expect(ranked.first.status, PeerPlacementStatus.recommended);
    expect(ranked.skip(1).every(
      (item) => item.status == PeerPlacementStatus.eligible,
    ), isTrue);
  });

  test('busy peers are not recommended while the single model slot is used', () {
    final busy = peer(
      id: 'busy',
      name: 'Busy',
      memory: 8 * 1024 * 1024 * 1024,
      cores: 8,
      updatedAt: now,
      activeExecutions: 1,
    );
    final free = peer(
      id: 'free',
      name: 'Free',
      memory: 2 * 1024 * 1024 * 1024,
      cores: 4,
      updatedAt: now,
    );

    final ranked = PeerExecutionPlacementAdvisor.rank(
      devices: [busy, free],
      connectedDeviceIds: {'busy', 'free'},
      now: instant,
    );

    expect(ranked.first.device.id, 'free');
    expect(ranked.first.status, PeerPlacementStatus.recommended);
    expect(ranked.last.status, PeerPlacementStatus.busy);
  });

  test('stale and missing resource profiles are never marked eligible', () {
    final stale = peer(
      id: 'stale',
      name: 'Stale',
      memory: 4 * 1024 * 1024 * 1024,
      cores: 8,
      updatedAt: now - const Duration(minutes: 6).inMilliseconds,
    );
    final unknown = PairedDeviceRecord(
      id: 'unknown',
      displayName: 'Unknown',
      platform: 'android',
      lastAddress: '192.168.1.11',
      lastPort: 47831,
      fingerprint: 'fingerprint-unknown',
      capabilities: {
        'task_execution': true,
        'task_execution_version': peerTaskExecutionVersion,
      },
      trustStatus: 'trusted',
      pairedAtUnixMs: now,
      lastSeenUnixMs: now,
      createdAtUnixMs: now,
    );

    final ranked = PeerExecutionPlacementAdvisor.rank(
      devices: [stale, unknown],
      connectedDeviceIds: {'stale', 'unknown'},
      now: instant,
    );

    expect(ranked.map((item) => item.status), contains(PeerPlacementStatus.staleResources));
    expect(ranked.map((item) => item.status), contains(PeerPlacementStatus.unknownResources));
    expect(ranked.any((item) => item.canReceiveExecution), isFalse);
  });

  test('blocked offline and incompatible peers are excluded', () {
    final peers = [
      peer(
        id: 'blocked',
        name: 'Blocked',
        memory: 4,
        cores: 4,
        updatedAt: now,
        blocked: true,
      ),
      peer(
        id: 'offline',
        name: 'Offline',
        memory: 4,
        cores: 4,
        updatedAt: now,
      ),
      peer(
        id: 'unsupported',
        name: 'Unsupported',
        memory: 4,
        cores: 4,
        updatedAt: now,
        supportsExecution: false,
      ),
    ];

    final ranked = PeerExecutionPlacementAdvisor.rank(
      devices: peers,
      connectedDeviceIds: {'blocked', 'unsupported'},
      now: instant,
    );

    final states = {for (final item in ranked) item.device.id: item.status};
    expect(states['blocked'], PeerPlacementStatus.blocked);
    expect(states['offline'], PeerPlacementStatus.offline);
    expect(states['unsupported'], PeerPlacementStatus.unsupported);
    expect(ranked.any((item) => item.canReceiveExecution), isFalse);
  });


  test('legacy resource profile remains valid when extended telemetry is absent', () {
    final legacy = <String, Object?>{
      'resource_profile_version': 1,
      'resource_profile_updated_at_unix_ms': now,
      'available_memory_bytes': 1024,
      'total_memory_bytes': 2048,
      'cpu_logical_cores': 4,
      'active_peer_executions': 0,
    };
    final profile = PeerResourceProfile.tryParse(legacy);
    expect(profile, isNotNull);
    expect(profile!.cpuUtilizationPercent, isNull);
    expect(profile.batteryLevelPercent, isNull);
    expect(profile.isCharging, isNull);
    expect(profile.thermalStatus, isNull);
  });

  test('extended peer telemetry is validated and shown only when present', () {
    final extended = <String, Object?>{
      'resource_profile_version': peerResourceProfileVersion,
      'resource_profile_updated_at_unix_ms': now,
      'available_memory_bytes': 1024,
      'total_memory_bytes': 2048,
      'cpu_logical_cores': 4,
      'active_peer_executions': 0,
      'cpu_utilization_percent': 45,
      'battery_level_percent': 67,
      'is_charging': true,
      'thermal_status': 2,
    };
    final profile = PeerResourceProfile.tryParse(extended);
    expect(profile, isNotNull);
    expect(profile!.cpuUtilizationPercent, 45);
    expect(profile.batteryLevelPercent, 67);
    expect(profile.isCharging, isTrue);
    expect(profile.thermalStatus, 2);

    final invalid = Map<String, Object?>.from(extended)
      ..['cpu_utilization_percent'] = 101;
    expect(PeerResourceProfile.tryParse(invalid), isNull);
  });


  test('resource summary renders only measured telemetry values', () {
    final device = peer(
      id: 'telemetry',
      name: 'Telemetry',
      memory: 1024 * 1024 * 1024,
      cores: 6,
      updatedAt: now,
      cpuLoad: 45,
      battery: 67,
      charging: true,
      thermal: 2,
    );
    final assessment = PeerExecutionPlacementAdvisor.rank(
      devices: [device],
      connectedDeviceIds: {'telemetry'},
      now: instant,
    ).single;
    expect(assessment.resourceSummary, contains('استخدام CPU 45%'));
    expect(assessment.resourceSummary, contains('بطارية 67%'));
    expect(assessment.resourceSummary, contains('قيد الشحن'));
    expect(assessment.resourceSummary, contains('الحالة الحرارية: متوسطة'));
  });

  test('resource profile rejects impossible or malformed measurements', () {
    final invalid = <String, Object?>{
      'resource_profile_version': peerResourceProfileVersion,
      'resource_profile_updated_at_unix_ms': now,
      'available_memory_bytes': 9,
      'total_memory_bytes': 8,
      'cpu_logical_cores': 4,
      'active_peer_executions': 0,
    };
    expect(PeerResourceProfile.tryParse(invalid), isNull);

    final oversizedCores = Map<String, Object?>.from(invalid)
      ..['available_memory_bytes'] = 4
      ..['total_memory_bytes'] = 8
      ..['cpu_logical_cores'] = 257;
    expect(PeerResourceProfile.tryParse(oversizedCores), isNull);

    final oversizedMemory = Map<String, Object?>.from(invalid)
      ..['available_memory_bytes'] = 1 << 61
      ..['total_memory_bytes'] = null;
    expect(PeerResourceProfile.tryParse(oversizedMemory), isNull);

    final malformedTotal = Map<String, Object?>.from(invalid)
      ..['available_memory_bytes'] = 4
      ..['total_memory_bytes'] = 'unknown';
    expect(PeerResourceProfile.tryParse(malformedTotal), isNull);
  });

  final targetModel = ModelRecord(
    id: 'local-model',
    displayName: 'Small Llama',
    runtime: ModelRuntime.llamaCpp,
    status: ModelInstallStatus.installed,
    sizeBytes: 300 * 1024 * 1024,
    architecture: 'llama',
    contextLength: 2048,
    blockCount: 8,
    embeddingLength: 1024,
    attentionHeadCount: 16,
    attentionHeadCountKv: 4,
    attentionKeyLength: 64,
    attentionValueLength: 64,
    fileType: 14,
    parameterCount: 1000000000,
    createdAtUnixMs: now,
    updatedAtUnixMs: now,
  );

  test('model placement ranks only peers advertising a ready matching GGUF profile', () {
    final signature = PeerInstalledModelProfile.fromModel(targetModel)!.signature;
    final best = peer(
      id: 'best-model-peer',
      name: 'Best model peer',
      memory: 2 * 1024 * 1024 * 1024,
      cores: 8,
      updatedAt: now,
      cpuLoad: 20,
      battery: 90,
    );
    final limited = peer(
      id: 'limited-model-peer',
      name: 'Limited model peer',
      memory: 600 * 1024 * 1024,
      cores: 4,
      updatedAt: now,
    );
    final unavailable = peer(
      id: 'no-model-peer',
      name: 'No model peer',
      memory: 8 * 1024 * 1024 * 1024,
      cores: 12,
      updatedAt: now,
    );
    final devices = [best, limited, unavailable].map((device) {
      final capabilities = Map<String, Object?>.from(device.capabilities);
      capabilities['ready_model_profiles_version'] = peerModelProfileInventoryVersion;
      capabilities['ready_model_profile_signatures'] =
          device.id == 'no-model-peer' ? <String>[] : <String>[signature];
      return PairedDeviceRecord(
        id: device.id,
        displayName: device.displayName,
        platform: device.platform,
        lastAddress: device.lastAddress,
        lastPort: device.lastPort,
        fingerprint: device.fingerprint,
        capabilities: capabilities,
        trustStatus: device.trustStatus,
        pairedAtUnixMs: device.pairedAtUnixMs,
        lastSeenUnixMs: device.lastSeenUnixMs,
        createdAtUnixMs: device.createdAtUnixMs,
      );
    }).toList();

    final ranked = PeerExecutionPlacementAdvisor.rankForModel(
      devices: devices,
      connectedDeviceIds: devices.map((item) => item.id).toSet(),
      model: targetModel,
      verifiedModelFileBytes: targetModel.sizeBytes!,
      contextTokens: 1024,
      now: instant,
    );

    expect(ranked.first.device.id, 'best-model-peer');
    expect(ranked.first.status, PeerPlacementStatus.recommended);
    expect(ranked.first.modelFit?.status, ModelFitStatus.likelyFits);
    expect(ranked.first.explanation.join(' '), contains('موافقة الجهاز المستلم'));
    expect(
      ranked.singleWhere((item) => item.device.id == 'limited-model-peer').status,
      PeerPlacementStatus.modelDoesNotFit,
    );
    expect(
      ranked.singleWhere((item) => item.device.id == 'no-model-peer').status,
      PeerPlacementStatus.modelUnavailable,
    );
  });

  test('model placement reports unknown inventory from older peers', () {
    final legacy = peer(
      id: 'legacy-inventory',
      name: 'Legacy inventory',
      memory: 4 * 1024 * 1024 * 1024,
      cores: 8,
      updatedAt: now,
    );
    final ranked = PeerExecutionPlacementAdvisor.rankForModel(
      devices: [legacy],
      connectedDeviceIds: {'legacy-inventory'},
      model: targetModel,
      verifiedModelFileBytes: targetModel.sizeBytes!,
      contextTokens: 1024,
      now: instant,
    );
    expect(ranked.single.status, PeerPlacementStatus.modelInventoryUnknown);
    expect(ranked.single.canReceiveExecution, isFalse);
  });

  test('tight memory fit remains selectable but carries an explicit warning', () {
    final signature = PeerInstalledModelProfile.fromModel(targetModel)!.signature;
    final base = peer(
      id: 'tight-peer',
      name: 'Tight peer',
      memory: 840 * 1024 * 1024,
      cores: 4,
      updatedAt: now,
    );
    final caps = Map<String, Object?>.from(base.capabilities)
      ..['ready_model_profiles_version'] = peerModelProfileInventoryVersion
      ..['ready_model_profile_signatures'] = [signature];
    final device = PairedDeviceRecord(
      id: base.id,
      displayName: base.displayName,
      platform: base.platform,
      lastAddress: base.lastAddress,
      lastPort: base.lastPort,
      fingerprint: base.fingerprint,
      capabilities: caps,
      trustStatus: base.trustStatus,
      pairedAtUnixMs: base.pairedAtUnixMs,
      lastSeenUnixMs: base.lastSeenUnixMs,
      createdAtUnixMs: base.createdAtUnixMs,
    );
    final ranked = PeerExecutionPlacementAdvisor.rankForModel(
      devices: [device],
      connectedDeviceIds: {device.id},
      model: targetModel,
      verifiedModelFileBytes: targetModel.sizeBytes!,
      contextTokens: 1024,
      now: instant,
    );
    expect(ranked.single.status, PeerPlacementStatus.recommended);
    expect(ranked.single.modelFit?.status, ModelFitStatus.tight);
    expect(ranked.single.canReceiveExecution, isTrue);
    expect(ranked.single.explanation.join(' '), contains('هامش التشغيل أقل'));
  });

  test('profile signature is metadata compatibility, not a claimed tensor hash', () {
    final profile = PeerInstalledModelProfile.fromModel(targetModel)!;
    expect(profile.signature, contains('llama'));
    expect(profile.signature, contains(targetModel.sizeBytes.toString()));
    final changed = ModelRecord(
      id: 'other',
      displayName: 'Other',
      runtime: targetModel.runtime,
      status: targetModel.status,
      sizeBytes: targetModel.sizeBytes! + 1,
      architecture: targetModel.architecture,
      contextLength: targetModel.contextLength,
      blockCount: targetModel.blockCount,
      embeddingLength: targetModel.embeddingLength,
      attentionHeadCount: targetModel.attentionHeadCount,
      attentionHeadCountKv: targetModel.attentionHeadCountKv,
      attentionKeyLength: targetModel.attentionKeyLength,
      attentionValueLength: targetModel.attentionValueLength,
      fileType: targetModel.fileType,
      parameterCount: targetModel.parameterCount,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    );
    expect(
      PeerInstalledModelProfile.fromModel(changed)!.signature,
      isNot(profile.signature),
    );
  });

}
