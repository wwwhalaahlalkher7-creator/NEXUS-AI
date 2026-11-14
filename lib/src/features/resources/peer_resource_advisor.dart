import '../devices/device_record.dart';
import '../devices/peer_task_execution.dart';
import '../models/model_fit_estimator.dart';
import '../models/model_record.dart';
import 'peer_model_profile.dart';

const peerResourceProfileVersion = 1;
const peerResourceProfileMaxAge = Duration(minutes: 5);

/// A best-effort, timestamped resource snapshot advertised by a paired peer.
/// Missing or malformed measurements are treated as unknown, never as zero
/// capacity and never as proof that the device is safe to execute a model.
class PeerResourceProfile {
  const PeerResourceProfile({
    required this.availableMemoryBytes,
    required this.totalMemoryBytes,
    required this.cpuLogicalCores,
    required this.activePeerExecutions,
    required this.updatedAtUnixMs,
    this.cpuUtilizationPercent,
    this.batteryLevelPercent,
    this.isCharging,
    this.thermalStatus,
  });

  final int availableMemoryBytes;
  final int? totalMemoryBytes;
  final int cpuLogicalCores;
  final int activePeerExecutions;
  final int updatedAtUnixMs;
  final int? cpuUtilizationPercent;
  final int? batteryLevelPercent;
  final bool? isCharging;
  /// Android PowerManager thermal status (0..6), null when unsupported.
  final int? thermalStatus;

  bool get isBusy => activePeerExecutions > 0;

  bool isFresh({DateTime? now}) {
    final current = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final age = current - updatedAtUnixMs;
    return age >= -const Duration(minutes: 2).inMilliseconds &&
        age <= peerResourceProfileMaxAge.inMilliseconds;
  }

  static PeerResourceProfile? tryParse(Map<String, Object?> capabilities) {
    final version = capabilities['resource_profile_version'];
    // Extended metrics are additive optional fields, so the original v1
    // capability contract remains wire-compatible with earlier NEXUS builds.
    if (version != peerResourceProfileVersion) return null;
    final available = _positiveInt(capabilities['available_memory_bytes']);
    final rawTotal = capabilities['total_memory_bytes'];
    final total = rawTotal == null ? null : _positiveInt(rawTotal);
    final cores = _positiveInt(capabilities['cpu_logical_cores']);
    final active = _nonNegativeInt(capabilities['active_peer_executions']);
    final updated = _positiveInt(
      capabilities['resource_profile_updated_at_unix_ms'],
    );
    final rawCpuLoad = capabilities['cpu_utilization_percent'];
    final cpuLoad = rawCpuLoad == null ? null : _boundedInt(rawCpuLoad, 0, 100);
    final rawBattery = capabilities['battery_level_percent'];
    final battery = rawBattery == null ? null : _boundedInt(rawBattery, 0, 100);
    final rawCharging = capabilities['is_charging'];
    final charging = rawCharging is bool ? rawCharging : null;
    final rawThermal = capabilities['thermal_status'];
    final thermal = rawThermal == null ? null : _boundedInt(rawThermal, 0, 6);
    if (available == null ||
        cores == null ||
        cores > 256 ||
        active == null ||
        updated == null ||
        available > 1 << 60 ||
        (rawTotal != null && total == null) ||
        (rawCpuLoad != null && cpuLoad == null) ||
        (rawBattery != null && battery == null) ||
        (rawCharging != null && rawCharging is! bool) ||
        (rawThermal != null && thermal == null) ||
        (total != null && (available > total || total > 1 << 60))) {
      return null;
    }
    return PeerResourceProfile(
      availableMemoryBytes: available,
      totalMemoryBytes: total,
      cpuLogicalCores: cores,
      activePeerExecutions: active,
      updatedAtUnixMs: updated,
      cpuUtilizationPercent: cpuLoad,
      batteryLevelPercent: battery,
      isCharging: charging,
      thermalStatus: thermal,
    );
  }

  static int? _positiveInt(Object? value) =>
      value is int && value > 0 ? value : null;

  static int? _nonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;

  static int? _boundedInt(Object? value, int minimum, int maximum) =>
      value is int && value >= minimum && value <= maximum ? value : null;
}

enum PeerPlacementStatus {
  recommended,
  eligible,
  busy,
  staleResources,
  unknownResources,
  unsupported,
  offline,
  blocked,
  modelInventoryUnknown,
  modelUnavailable,
  modelFitUnknown,
  modelDoesNotFit,
  modelFitTight,
}

class PeerPlacementAssessment {
  const PeerPlacementAssessment({
    required this.device,
    required this.status,
    this.profile,
    this.modelFit,
  });

  final PairedDeviceRecord device;
  final PeerPlacementStatus status;
  final PeerResourceProfile? profile;
  final ModelFitEstimate? modelFit;

  bool get canReceiveExecution =>
      status == PeerPlacementStatus.recommended ||
      status == PeerPlacementStatus.eligible ||
      status == PeerPlacementStatus.modelFitTight;

  String get label => switch (status) {
        PeerPlacementStatus.recommended => 'أفضل مورد متاح حالياً',
        PeerPlacementStatus.eligible => 'مناسب للتنفيذ',
        PeerPlacementStatus.busy => 'مشغول بتنفيذ آخر',
        PeerPlacementStatus.staleResources => 'بيانات الموارد قديمة',
        PeerPlacementStatus.unknownResources => 'بيانات الموارد غير متاحة',
        PeerPlacementStatus.unsupported => 'لا يدعم التنفيذ الموزّع',
        PeerPlacementStatus.offline => 'غير متصل',
        PeerPlacementStatus.blocked => 'محظور',
        PeerPlacementStatus.modelInventoryUnknown => 'قائمة النماذج غير متاحة',
        PeerPlacementStatus.modelUnavailable => 'لا يوجد وكيل جاهز بمواصفات نموذج مطابقة',
        PeerPlacementStatus.modelFitUnknown => 'تعذر تقدير ملاءمة النموذج',
        PeerPlacementStatus.modelDoesNotFit => 'الذاكرة غير كافية لهذا النموذج والسياق',
        PeerPlacementStatus.modelFitTight => 'ملاءمة ضيقة — راجع هامش الذاكرة',
      };

  String get resourceSummary {
    final value = profile;
    if (value == null) return 'لا توجد قراءة موارد صالحة';
    final memoryGb =
        value.availableMemoryBytes / (1024 * 1024 * 1024);
    final memory = memoryGb >= 1
        ? '${memoryGb.toStringAsFixed(1)} GB RAM متاحة'
        : '${(value.availableMemoryBytes / (1024 * 1024)).round()} MB RAM متاحة';
    final details = <String>[
      memory,
      '${value.cpuLogicalCores} أنوية منطقية',
      if (value.cpuUtilizationPercent != null)
        'استخدام CPU ${value.cpuUtilizationPercent}%',
      if (value.batteryLevelPercent != null)
        'بطارية ${value.batteryLevelPercent}%',
      if (value.isCharging == true) 'قيد الشحن',
      if (value.isCharging == false) 'غير موصول بالشاحن',
      if (value.thermalStatus != null)
        'الحالة الحرارية: ${_thermalLabel(value.thermalStatus!)}',
    ];
    return details.join(' · ');
  }

  List<String> get explanation {
    final lines = <String>[label];
    final fit = modelFit;
    if (fit != null) {
      lines.add(fit.statusLabel);
      lines.add('الذاكرة المتاحة: ${_formatBytes(fit.availableMemoryBytes)}');
      lines.add('الحد الأدنى التقديري: ${_formatBytes(fit.minimumRequiredBytes)}');
      lines.add('الاحتياج الموصى به: ${_formatBytes(fit.recommendedRequiredBytes)}');
      if (fit.status == ModelFitStatus.tight) {
        lines.add('الذاكرة تكفي الحد الأدنى فقط؛ هامش التشغيل أقل من الموصى به.');
      }
    }
    final value = profile;
    if (value != null) {
      if (value.cpuUtilizationPercent != null && value.cpuUtilizationPercent! >= 80) {
        lines.add('حمل CPU مرتفع حالياً (${value.cpuUtilizationPercent}%).');
      }
      if (value.thermalStatus != null && value.thermalStatus! >= 3) {
        lines.add('الحالة الحرارية تستدعي الحذر (${_thermalLabel(value.thermalStatus!)}).');
      }
      if (value.batteryLevelPercent != null &&
          value.batteryLevelPercent! <= 15 && value.isCharging != true) {
        lines.add('البطارية منخفضة والجهاز غير موصول بالشاحن.');
      }
    }
    lines.add('مطابقة مواصفات GGUF لا تثبت تطابق محتوى الأوزان؛ موافقة الجهاز المستلم تظل إلزامية.');
    return List.unmodifiable(lines);
  }

  String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(2)} GiB';
    return '${(bytes / mib).toStringAsFixed(0)} MiB';
  }

  String _thermalLabel(int status) => switch (status) {
        0 => 'طبيعية',
        1 => 'خفيفة',
        2 => 'متوسطة',
        3 => 'مرتفعة',
        4 => 'حرجة',
        5 => 'طارئة',
        6 => 'إيقاف حراري',
        _ => 'غير معروفة',
      };
}

/// The generic rank() method uses only fresh measurements actually reported
/// by each peer. rankForModel() adds GGUF metadata-profile matching and the
/// local model-fit estimator. Neither path dispatches tasks automatically.
class PeerExecutionPlacementAdvisor {
  const PeerExecutionPlacementAdvisor._();

  static List<PeerPlacementAssessment> rank({
    required List<PairedDeviceRecord> devices,
    required Set<String> connectedDeviceIds,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final assessed = devices.map((device) {
      final status = _statusFor(
        device,
        connected: connectedDeviceIds.contains(device.id),
        now: current,
      );
      return PeerPlacementAssessment(
        device: device,
        status: status,
        profile: PeerResourceProfile.tryParse(device.capabilities),
      );
    }).toList();

    assessed.sort((left, right) {
      final leftEligible = left.canReceiveExecution;
      final rightEligible = right.canReceiveExecution;
      if (leftEligible != rightEligible) return leftEligible ? -1 : 1;
      if (leftEligible && rightEligible) {
        final memoryOrder = right.profile!.availableMemoryBytes
            .compareTo(left.profile!.availableMemoryBytes);
        if (memoryOrder != 0) return memoryOrder;
        final coreOrder = right.profile!.cpuLogicalCores
            .compareTo(left.profile!.cpuLogicalCores);
        if (coreOrder != 0) return coreOrder;
      }
      return left.device.displayName.compareTo(right.device.displayName);
    });

    final firstEligible = assessed.indexWhere((item) =>
        item.status == PeerPlacementStatus.eligible);
    if (firstEligible >= 0) {
      final best = assessed[firstEligible];
      assessed[firstEligible] = PeerPlacementAssessment(
        device: best.device,
        status: PeerPlacementStatus.recommended,
        profile: best.profile,
      );
    }
    return List.unmodifiable(assessed);
  }

  /// Ranks peers for a concrete GGUF metadata profile and context. A peer
  /// must advertise a ready local agent assigned to a matching profile before
  /// it can be considered. The estimator uses that peer's fresh available RAM.
  /// This is advisory only: no task is dispatched and the receiver still
  /// chooses/approves its local agent.
  static List<PeerPlacementAssessment> rankForModel({
    required List<PairedDeviceRecord> devices,
    required Set<String> connectedDeviceIds,
    required ModelRecord model,
    required int verifiedModelFileBytes,
    required int contextTokens,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final targetProfile = PeerInstalledModelProfile.fromModel(model);

    final assessed = <PeerPlacementAssessment>[];
    for (final device in devices) {
      final baseStatus = _statusFor(
        device,
        connected: connectedDeviceIds.contains(device.id),
        now: current,
      );
      final profile = PeerResourceProfile.tryParse(device.capabilities);
      if (baseStatus != PeerPlacementStatus.eligible || profile == null) {
        assessed.add(PeerPlacementAssessment(
          device: device,
          status: baseStatus,
          profile: profile,
        ));
        continue;
      }
      if (targetProfile == null) {
        assessed.add(PeerPlacementAssessment(
          device: device,
          status: PeerPlacementStatus.modelFitUnknown,
          profile: profile,
        ));
        continue;
      }

      final inventoryVersion = device.capabilities['ready_model_profiles_version'];
      final rawProfiles = device.capabilities['ready_model_profile_signatures'];
      if (inventoryVersion != peerModelProfileInventoryVersion || rawProfiles is! List ||
          rawProfiles.any((value) => value is! String || value.length > 4096)) {
        assessed.add(PeerPlacementAssessment(
          device: device,
          status: PeerPlacementStatus.modelInventoryUnknown,
          profile: profile,
        ));
        continue;
      }
      final signatures = rawProfiles.cast<String>().toSet();
      if (!signatures.contains(targetProfile.signature)) {
        assessed.add(PeerPlacementAssessment(
          device: device,
          status: PeerPlacementStatus.modelUnavailable,
          profile: profile,
        ));
        continue;
      }

      final fit = ModelFitEstimator.estimate(
        model: model,
        verifiedModelFileBytes: verifiedModelFileBytes,
        contextTokens: contextTokens,
        availableMemoryBytes: profile.availableMemoryBytes,
      );
      final status = switch (fit.status) {
        ModelFitStatus.likelyFits => PeerPlacementStatus.eligible,
        ModelFitStatus.tight => PeerPlacementStatus.modelFitTight,
        ModelFitStatus.insufficient => PeerPlacementStatus.modelDoesNotFit,
        ModelFitStatus.unknown => PeerPlacementStatus.modelFitUnknown,
      };
      assessed.add(PeerPlacementAssessment(
        device: device,
        status: status,
        profile: profile,
        modelFit: fit,
      ));
    }

    int fitPriority(PeerPlacementAssessment item) => switch (item.status) {
          PeerPlacementStatus.eligible => 0,
          PeerPlacementStatus.modelFitTight => 1,
          PeerPlacementStatus.modelDoesNotFit => 2,
          PeerPlacementStatus.modelUnavailable => 3,
          PeerPlacementStatus.modelFitUnknown => 4,
          PeerPlacementStatus.modelInventoryUnknown => 5,
          _ => 6,
        };
    assessed.sort((left, right) {
      final priorityOrder = fitPriority(left).compareTo(fitPriority(right));
      if (priorityOrder != 0) return priorityOrder;
      final leftFit = left.modelFit;
      final rightFit = right.modelFit;
      if (leftFit != null && rightFit != null) {
        final leftMargin = leftFit.availableMemoryBytes -
            leftFit.recommendedRequiredBytes;
        final rightMargin = rightFit.availableMemoryBytes -
            rightFit.recommendedRequiredBytes;
        final marginOrder = rightMargin.compareTo(leftMargin);
        if (marginOrder != 0) return marginOrder;
      }
      final leftProfile = left.profile;
      final rightProfile = right.profile;
      if (leftProfile != null && rightProfile != null) {
        final leftLoad = leftProfile.cpuUtilizationPercent ?? 100;
        final rightLoad = rightProfile.cpuUtilizationPercent ?? 100;
        final loadOrder = leftLoad.compareTo(rightLoad);
        if (loadOrder != 0) return loadOrder;
        final leftThermal = leftProfile.thermalStatus ?? 6;
        final rightThermal = rightProfile.thermalStatus ?? 6;
        final thermalOrder = leftThermal.compareTo(rightThermal);
        if (thermalOrder != 0) return thermalOrder;
        final leftBattery = leftProfile.batteryLevelPercent ?? 0;
        final rightBattery = rightProfile.batteryLevelPercent ?? 0;
        final batteryOrder = rightBattery.compareTo(leftBattery);
        if (batteryOrder != 0) return batteryOrder;
        final coreOrder = rightProfile.cpuLogicalCores
            .compareTo(leftProfile.cpuLogicalCores);
        if (coreOrder != 0) return coreOrder;
      }
      return left.device.displayName.compareTo(right.device.displayName);
    });

    final firstFit = assessed.indexWhere((item) =>
        item.status == PeerPlacementStatus.eligible ||
        item.status == PeerPlacementStatus.modelFitTight);
    if (firstFit >= 0) {
      final best = assessed[firstFit];
      assessed[firstFit] = PeerPlacementAssessment(
        device: best.device,
        status: PeerPlacementStatus.recommended,
        profile: best.profile,
        modelFit: best.modelFit,
      );
    }
    return List.unmodifiable(assessed);
  }

  static PeerPlacementStatus _statusFor(
    PairedDeviceRecord device, {
    required bool connected,
    required DateTime now,
  }) {
    if (device.isBlocked) return PeerPlacementStatus.blocked;
    if (!connected) return PeerPlacementStatus.offline;
    if (device.capabilities['task_execution'] != true ||
        device.capabilities['task_execution_version'] !=
            peerTaskExecutionVersion) {
      return PeerPlacementStatus.unsupported;
    }
    final profile = PeerResourceProfile.tryParse(device.capabilities);
    if (profile == null) return PeerPlacementStatus.unknownResources;
    if (!profile.isFresh(now: now)) {
      return PeerPlacementStatus.staleResources;
    }
    if (profile.isBusy) return PeerPlacementStatus.busy;
    return PeerPlacementStatus.eligible;
  }
}
