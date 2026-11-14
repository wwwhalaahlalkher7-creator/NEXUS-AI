import 'model_record.dart';
import 'rust_gguf_inspector.dart';

enum ModelFitStatus {
  likelyFits,
  tight,
  insufficient,
  unknown,
}

enum KvCacheEstimateMethod {
  ggufAttentionDimensions,
  fullEmbeddingUpperBound,
}

/// A planning estimate only. The native loader performs its own live memory
/// preflight and remains authoritative; this result never bypasses it.
class ModelFitEstimate {
  const ModelFitEstimate({
    required this.status,
    required this.modelFileBytes,
    required this.contextTokens,
    required this.kvCacheBytes,
    required this.runtimeReserveBytes,
    required this.minimumRequiredBytes,
    required this.recommendedRequiredBytes,
    required this.upperRequiredBytes,
    required this.availableMemoryBytes,
    required this.kvMethod,
    required this.assumptions,
    this.reason,
  });

  final ModelFitStatus status;
  final int modelFileBytes;
  final int contextTokens;
  final int kvCacheBytes;
  final int runtimeReserveBytes;
  final int minimumRequiredBytes;
  final int recommendedRequiredBytes;
  final int upperRequiredBytes;
  final int availableMemoryBytes;
  final KvCacheEstimateMethod kvMethod;
  final List<String> assumptions;
  final String? reason;

  bool get hasKnownAvailability => availableMemoryBytes > 0;

  String get statusLabel => switch (status) {
        ModelFitStatus.likelyFits => 'ملاءمة تقديرية جيدة',
        ModelFitStatus.tight => 'هامش الذاكرة ضيق',
        ModelFitStatus.insufficient => 'الذاكرة المتاحة أقل من الحد التقديري',
        ModelFitStatus.unknown => 'لا يمكن تأكيد الملاءمة',
      };
}

/// Estimates CPU model residency, KV cache and a runtime/workspace reserve.
/// If exact attention dimensions are absent, supported transformer families
/// use full embedding width per K/V tensor as a conservative MHA upper bound.
class ModelFitEstimator {
  const ModelFitEstimator._();

  static const int mib = 1024 * 1024;
  static const int gib = 1024 * mib;
  static const int _baseRuntimeReserveBytes = 384 * mib;
  static const int _contextReservePer2kBytes = 128 * mib;
  static const int _maxNativeContextTokens = 4096;
  static const int _maxSafeBytes = 0x7fffffffffffffff;

  static const Set<String> _attentionArchitectures = {
    'llama',
    'mistral',
    'mixtral',
    'qwen',
    'qwen2',
    'qwen2moe',
    'qwen3',
    'gemma',
    'gemma2',
    'gemma3',
    'phi2',
    'phi3',
    'phi3moe',
    'gptneox',
    'falcon',
    'stablelm',
    'starcoder',
    'internlm2',
    'yi',
    'deepseek',
    'deepseek2',
    'command-r',
    'cohere2',
    'minicpm',
    'granite',
    'olmo',
    'baichuan',
    'bloom',
    'mpt',
    'refact',
    'plamo',
    'jais',
    'exaone',
    'dbrx',
    'arctic',
    'nemotron',
    'smollm',
    'openelm',
    'hunyuan',
    'xverse',
    'solar',
    'glm4',
    'afmoe',
  };

  static ModelFitEstimate estimate({
    required ModelRecord model,
    required int verifiedModelFileBytes,
    required int contextTokens,
    required int availableMemoryBytes,
    GgufInspection? freshInspection,
  }) {
    if (model.runtime != ModelRuntime.llamaCpp) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'تقدير الذاكرة متاح لمسار llama.cpp المحلي فقط.',
      );
    }
    if (model.status != ModelInstallStatus.installed ||
        verifiedModelFileBytes <= 0 ||
        verifiedModelFileBytes > _maxSafeBytes) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'يلزم ملف نموذج محلي مثبت بحجم تم التحقق منه.',
      );
    }
    if (contextTokens < 512 || contextTokens > _maxNativeContextTokens) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'السياق خارج النطاق الحالي للمحرك (512–4096 رمزاً).',
      );
    }
    final trainingContext = freshInspection == null
        ? model.contextLength
        : freshInspection.contextLength;
    if (trainingContext != null &&
        trainingContext > 0 &&
        contextTokens > trainingContext) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'السياق المطلوب يتجاوز نافذة السياق المعلنة في GGUF.',
      );
    }

    final architecture = (freshInspection == null
            ? model.architecture
            : freshInspection.architecture)
        ?.trim()
        .toLowerCase();
    if (architecture == null ||
        !_attentionArchitectures.contains(architecture)) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'المعمارية غير مدعومة في نموذج تقدير KV الحالي؛ لم نفترض أنها Transformer.',
      );
    }

    final blocks = freshInspection == null
        ? model.blockCount
        : freshInspection.blockCount;
    final embedding = freshInspection == null
        ? model.embeddingLength
        : freshInspection.embeddingLength;
    if (blocks == null ||
        embedding == null ||
        blocks < 1 ||
        blocks > 1024 ||
        embedding < 1 ||
        embedding > 65536) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'بيانات عدد الطبقات أو أبعاد التضمين ناقصة أو خارج النطاق.',
      );
    }

    final kv = _estimateKvBytes(
      model,
      contextTokens,
      blocks,
      embedding,
      freshInspection: freshInspection,
    );
    if (kv == null || kv <= 0 || kv > _maxSafeBytes) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'تعذر اشتقاق أبعاد KV Cache متسقة من بيانات GGUF.',
      );
    }

    final contextUnits = (contextTokens + 2047) ~/ 2048;
    final runtimeReserve = _baseRuntimeReserveBytes +
        contextUnits * _contextReservePer2kBytes;
    final fileBytes = BigInt.from(verifiedModelFileBytes);
    final kvBytes = BigInt.from(kv);
    final reserveBytes = BigInt.from(runtimeReserve);

    // Planning envelope: disk size is the baseline for mapped weights; the
    // 12.5% / 25% weight margins and 25% / 50% KV margins expose uncertainty.
    final minimum = fileBytes + kvBytes + reserveBytes;
    final recommended = _ceilRatio(fileBytes, 9, 8) +
        _ceilRatio(kvBytes, 5, 4) +
        reserveBytes;
    final upper = _ceilRatio(fileBytes, 5, 4) +
        _ceilRatio(kvBytes, 3, 2) +
        reserveBytes;

    if ([minimum, recommended, upper].any((value) => value > BigInt.from(_maxSafeBytes))) {
      return _unknown(
        model,
        contextTokens,
        availableMemoryBytes,
        'حساب الذاكرة تجاوز النطاق العددي الآمن.',
      );
    }

    final minimumInt = minimum.toInt();
    final recommendedInt = recommended.toInt();
    final upperInt = upper.toInt();
    final available = availableMemoryBytes > 0 ? availableMemoryBytes : 0;
    final status = available == 0
        ? ModelFitStatus.unknown
        : available < minimumInt
            ? ModelFitStatus.insufficient
            : available < recommendedInt
                ? ModelFitStatus.tight
                : ModelFitStatus.likelyFits;

    return ModelFitEstimate(
      status: status,
      modelFileBytes: verifiedModelFileBytes,
      contextTokens: contextTokens,
      kvCacheBytes: kv,
      runtimeReserveBytes: runtimeReserve,
      minimumRequiredBytes: minimumInt,
      recommendedRequiredBytes: recommendedInt,
      upperRequiredBytes: upperInt,
      availableMemoryBytes: available,
      kvMethod: _hasCompleteAttentionDimensions(model, freshInspection)
          ? KvCacheEstimateMethod.ggufAttentionDimensions
          : KvCacheEstimateMethod.fullEmbeddingUpperBound,
      assumptions: [
        'حجم ملف GGUF المتحقق منه هو خط أساس لذاكرة الأوزان المقيمة؛ نمط mmap قد يغيّر RSS الفعلي.',
        _hasCompleteAttentionDimensions(model, freshInspection)
            ? 'استُخدمت أبعاد رؤوس K/V المسجلة في GGUF.'
            : 'لم تكتمل أبعاد رؤوس K/V؛ استُخدم عرض embedding الكامل لكل من K وV كحد أعلى محافظ متعدد الرؤوس.',
        'حساب KV يفترض نوع F16 لكل من K وV (بايتان لكل عنصر).',
        'الهامش المقترح يضيف 12.5% للأوزان و25% لذاكرة KV؛ الحد الأعلى يضيف 25% و50% على الترتيب.',
        'حجز التشغيل الأساسي 384 MiB، مع 128 MiB إضافية لكل شريحة سياق مقدارها 2048 رمزاً، لمواءمة فحص المحرك الحالي.',
        'هذا تقدير تخطيطي وليس قياس RSS أو ضمان تحميل؛ فحص الذاكرة داخل محرك llama.cpp يظل إلزامياً.',
      ],
    );
  }

  static int? _estimateKvBytes(
    ModelRecord model,
    int context,
    int blocks,
    int embedding, {
    GgufInspection? freshInspection,
  }) {
    final keyLength = freshInspection == null
        ? model.attentionKeyLength
        : freshInspection.attentionKeyLength;
    final valueLength = freshInspection == null
        ? model.attentionValueLength
        : freshInspection.attentionValueLength;
    final kvHeads = freshInspection == null
        ? model.attentionHeadCountKv
        : freshInspection.attentionHeadCountKv;
    final attentionHeads = freshInspection == null
        ? model.attentionHeadCount
        : freshInspection.attentionHeadCount;

    BigInt aggregateKvWidth;
    if (keyLength != null || valueLength != null || kvHeads != null) {
      if ((keyLength == null) != (valueLength == null)) {
        return null;
      }
      if (keyLength == null || valueLength == null) {
        if (attentionHeads == null ||
            attentionHeads < 1 ||
            attentionHeads > 512 ||
            embedding % attentionHeads != 0) {
          return null;
        }
        final headDimension = embedding ~/ attentionHeads;
        final effectiveKvHeads = kvHeads ?? attentionHeads;
        if (effectiveKvHeads < 1 ||
            effectiveKvHeads > attentionHeads ||
            effectiveKvHeads > 512) {
          return null;
        }
        aggregateKvWidth = BigInt.from(effectiveKvHeads) *
            BigInt.from(headDimension) *
            BigInt.from(2);
      } else {
        final effectiveKvHeads = kvHeads ?? attentionHeads;
        if (effectiveKvHeads == null ||
            effectiveKvHeads < 1 ||
            effectiveKvHeads > 512 ||
            (attentionHeads != null &&
                (attentionHeads < 1 || attentionHeads > 512 || effectiveKvHeads > attentionHeads)) ||
            keyLength < 1 ||
            valueLength < 1 ||
            keyLength > 65536 ||
            valueLength > 65536) {
          return null;
        }
        aggregateKvWidth = BigInt.from(effectiveKvHeads) *
            BigInt.from(keyLength + valueLength);
      }
    } else {
      // Conservative full-width multi-head attention fallback: the aggregate
      // K width and V width are each assumed to equal model embedding width.
      aggregateKvWidth = BigInt.from(embedding) * BigInt.from(2);
    }

    final total = BigInt.from(context) *
        BigInt.from(blocks) *
        aggregateKvWidth *
        BigInt.from(2); // F16 bytes per K/V element.
    if (total <= BigInt.zero || total > BigInt.from(_maxSafeBytes)) {
      return null;
    }
    return total.toInt();
  }

  static bool _hasCompleteAttentionDimensions(
    ModelRecord model,
    GgufInspection? freshInspection,
  ) {
    final heads = freshInspection == null
        ? model.attentionHeadCount
        : freshInspection.attentionHeadCount;
    final kvHeads = freshInspection == null
        ? model.attentionHeadCountKv
        : freshInspection.attentionHeadCountKv;
    final keyLength = freshInspection == null
        ? model.attentionKeyLength
        : freshInspection.attentionKeyLength;
    final valueLength = freshInspection == null
        ? model.attentionValueLength
        : freshInspection.attentionValueLength;
    return keyLength != null &&
        valueLength != null &&
        (kvHeads != null || heads != null);
  }

  static BigInt _ceilRatio(BigInt value, int numerator, int denominator) =>
      (value * BigInt.from(numerator) + BigInt.from(denominator - 1)) ~/
      BigInt.from(denominator);

  static ModelFitEstimate _unknown(
    ModelRecord model,
    int contextTokens,
    int availableMemoryBytes,
    String reason,
  ) =>
      ModelFitEstimate(
        status: ModelFitStatus.unknown,
        modelFileBytes: model.sizeBytes ?? 0,
        contextTokens: contextTokens,
        kvCacheBytes: 0,
        runtimeReserveBytes: 0,
        minimumRequiredBytes: 0,
        recommendedRequiredBytes: 0,
        upperRequiredBytes: 0,
        availableMemoryBytes: availableMemoryBytes > 0 ? availableMemoryBytes : 0,
        kvMethod: KvCacheEstimateMethod.fullEmbeddingUpperBound,
        assumptions: const [],
        reason: reason,
      );
}

String formatModelMemoryBytes(int bytes) {
  if (bytes >= ModelFitEstimator.gib) {
    return '${(bytes / ModelFitEstimator.gib).toStringAsFixed(2)} GiB';
  }
  if (bytes >= ModelFitEstimator.mib) {
    return '${(bytes / ModelFitEstimator.mib).toStringAsFixed(0)} MiB';
  }
  return '${bytes.toString()} B';
}
