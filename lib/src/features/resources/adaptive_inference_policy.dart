import '../models/model_fit_estimator.dart';
import '../models/model_record.dart';
import '../models/rust_gguf_inspector.dart';
import 'resource_settings.dart';

/// An explicit, reviewable runtime choice. It is never applied automatically.
class InferenceRuntimeSelection {
  const InferenceRuntimeSelection({
    required this.contextTokens,
    required this.cpuThreads,
  });

  final int contextTokens;
  final int cpuThreads;
}

class AdaptiveInferenceRecommendation {
  const AdaptiveInferenceRecommendation({
    required this.contextOptions,
    required this.contextTokens,
    required this.cpuThreads,
    required this.estimate,
    required this.reasons,
    required this.warnings,
  });

  final List<int> contextOptions;
  final int contextTokens;
  final int cpuThreads;
  final ModelFitEstimate estimate;
  final List<String> reasons;
  final List<String> warnings;
}

/// Produces advisory context/thread settings from a fresh model inspection and
/// current device telemetry. The caller must ask the user before applying them.
class AdaptiveInferencePolicy {
  const AdaptiveInferencePolicy._();

  static const int nativeMaxContextTokens = 4096;
  static const int nativeMaxCpuThreads = 8;
  static const List<int> _contextCandidates = [512, 1024, 2048, 4096];

  static AdaptiveInferenceRecommendation recommend({
    required ModelRecord model,
    required int verifiedModelFileBytes,
    required ResourceSnapshot resources,
    required ResourceSettings settings,
    GgufInspection? freshInspection,
  }) {
    final trainingContext = freshInspection == null
        ? model.contextLength
        : freshInspection.contextLength;
    final effectiveMaxContext = trainingContext != null && trainingContext > 0
        ? trainingContext.clamp(0, nativeMaxContextTokens).toInt()
        : nativeMaxContextTokens;
    final contextOptions = _contextCandidates
        .where((value) => value <= effectiveMaxContext)
        .toList(growable: false);

    final usableOptions = contextOptions.isEmpty
        ? const <int>[512]
        : contextOptions;
    final estimates = <int, ModelFitEstimate>{
      for (final context in usableOptions)
        context: ModelFitEstimator.estimate(
          model: model,
          verifiedModelFileBytes: verifiedModelFileBytes,
          contextTokens: context,
          availableMemoryBytes: resources.availableMemoryBytes,
          freshInspection: freshInspection,
        ),
    };

    final selectedContext = _selectContext(
      options: usableOptions,
      estimates: estimates,
      mode: settings.mode,
      memoryKnown: resources.availableMemoryBytes > 0,
    );
    final selectedEstimate = estimates[selectedContext]!;
    final reasons = <String>[];
    final warnings = <String>[];

    reasons.add('وضع الموارد الحالي: ${settings.label}.');
    reasons.add('عدد الأنوية المنطقية المتاحة للنظام: ${resources.cpuLogicalCores}.');
    reasons.add('اختير سياق $selectedContext رمزاً وفق ملاءمة الذاكرة ونافذة النموذج.');

    if (resources.availableMemoryBytes <= 0) {
      warnings.add('قراءة RAM المتاحة غير متوفرة؛ اختيار السياق محافظ ولا يثبت إمكانية التحميل.');
    } else if (selectedEstimate.status == ModelFitStatus.tight) {
      warnings.add('هامش الذاكرة ضيق؛ قد يفشل التخصيص الفعلي رغم اجتياز التقدير.');
    } else if (selectedEstimate.status == ModelFitStatus.insufficient) {
      warnings.add('حتى الحد الأدنى التقديري يتجاوز RAM المتاحة حالياً.');
    } else if (selectedEstimate.status == ModelFitStatus.unknown) {
      warnings.add(selectedEstimate.reason ?? 'تعذر إصدار حكم موثوق على ملاءمة النموذج.');
    }

    final threads = _selectThreads(resources, settings.mode, reasons, warnings);
    return AdaptiveInferenceRecommendation(
      contextOptions: usableOptions,
      contextTokens: selectedContext,
      cpuThreads: threads,
      estimate: selectedEstimate,
      reasons: List.unmodifiable(reasons),
      warnings: List.unmodifiable(warnings),
    );
  }

  static int _selectContext({
    required List<int> options,
    required Map<int, ModelFitEstimate> estimates,
    required ResourceMode mode,
    required bool memoryKnown,
  }) {
    // Unrestricted mode intentionally keeps the largest model-supported
    // context even when the estimate warns that current RAM may be insufficient.
    if (mode == ResourceMode.unrestricted) return options.last;

    if (!memoryKnown) {
      final conservative = options.where((value) => value <= 2048).toList();
      return conservative.isEmpty ? options.first : conservative.last;
    }

    final candidates = mode == ResourceMode.balanced
        ? options.where((value) => value <= 2048).toList()
        : options;
    final considered = candidates.isEmpty ? options : candidates;
    final likely = considered
        .where((value) => estimates[value]!.status == ModelFitStatus.likelyFits)
        .toList();
    if (likely.isNotEmpty) return likely.last;

    final tight = considered
        .where((value) => estimates[value]!.status == ModelFitStatus.tight)
        .toList();
    if (tight.isNotEmpty) {
      return mode == ResourceMode.performance || mode == ResourceMode.unrestricted
          ? tight.last
          : tight.first;
    }

    // When none fits, pick the smallest context for an honest, low-footprint
    // recommendation; the estimate remains insufficient and is not hidden.
    return considered.first;
  }

  static int _selectThreads(
    ResourceSnapshot resources,
    ResourceMode mode,
    List<String> reasons,
    List<String> warnings,
  ) {
    final cores = resources.cpuLogicalCores.clamp(1, 256).toInt();
    final engineThreads = cores.clamp(1, nativeMaxCpuThreads).toInt();
    var threads = mode == ResourceMode.balanced
        ? ((cores + 1) ~/ 2).clamp(1, 4).toInt()
        : engineThreads;
    reasons.add('عدد خيوط CPU المقترح قبل مراعاة الحمل: $threads من حد المحرك 8.');

    if (mode == ResourceMode.unrestricted) {
      warnings.add('الوضع المفتوح لا يخفض الخيوط تلقائياً؛ حد واجهة المحرك الحالية 8 خيوط.');
      if ((resources.thermalStatus ?? 0) >= 3 ||
          (resources.cpuUtilizationPercent ?? 0) >= 90 ||
          (resources.batteryLevelPercent != null &&
              resources.batteryLevelPercent! <= 15 &&
              resources.isCharging == false)) {
        warnings.add('توجد إشارة حمل/حرارة/بطارية تستحق الانتباه قبل اعتماد الوضع المفتوح.');
      }
      return threads;
    }

    final thermal = resources.thermalStatus;
    if (thermal != null && thermal >= 4) {
      threads = 1;
      reasons.add('الحالة الحرارية حرجة أو أعلى؛ خُفّضت الخيوط إلى 1.');
    } else if (thermal == 3) {
      threads = (threads ~/ 2).clamp(1, threads).toInt();
      reasons.add('الحالة الحرارية شديدة؛ خُفّض عدد الخيوط للنصف تقريباً.');
    } else if (thermal == 2) {
      threads = ((threads * 3) ~/ 4).clamp(1, threads).toInt();
      reasons.add('الحالة الحرارية متوسطة؛ خُفّض عدد الخيوط احترازياً.');
    }

    final cpu = resources.cpuUtilizationPercent;
    if (cpu != null && cpu >= 90) {
      threads = (threads ~/ 2).clamp(1, threads).toInt();
      reasons.add('استخدام CPU مرتفع ($cpu%)؛ خُفّض عدد الخيوط.');
    } else if (cpu != null && cpu >= 80) {
      threads = (threads - 1).clamp(1, threads).toInt();
      reasons.add('استخدام CPU مرتفع نسبياً ($cpu%)؛ خُفّض خيط واحد.');
    }

    if (resources.batteryLevelPercent != null &&
        resources.batteryLevelPercent! <= 15 &&
        resources.isCharging == false) {
      threads = threads.clamp(1, 2).toInt();
      reasons.add('البطارية منخفضة والجهاز غير موصول بالشحن؛ حُددت الخيوط بحد أقصى 2.');
    }
    return threads;
  }
}
