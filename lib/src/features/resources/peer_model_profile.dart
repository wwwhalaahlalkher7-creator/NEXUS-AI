import '../models/model_record.dart';

const peerModelProfileInventoryVersion = 1;

/// A privacy-minimized descriptor for a GGUF profile assigned to a ready
/// local agent. The signature describes public model metadata only; it is not
/// a cryptographic hash of tensor contents and must never be used as identity
/// or integrity proof for model bytes.
class PeerInstalledModelProfile {
  const PeerInstalledModelProfile({
    required this.fileBytes,
    required this.architecture,
    required this.contextLength,
    required this.blockCount,
    required this.embeddingLength,
    required this.attentionHeadCount,
    required this.attentionHeadCountKv,
    required this.attentionKeyLength,
    required this.attentionValueLength,
    required this.fileType,
    required this.parameterCount,
  });

  final int fileBytes;
  final String architecture;
  final int? contextLength;
  final int blockCount;
  final int embeddingLength;
  final int? attentionHeadCount;
  final int? attentionHeadCountKv;
  final int? attentionKeyLength;
  final int? attentionValueLength;
  final int? fileType;
  final int? parameterCount;

  static PeerInstalledModelProfile? fromModel(ModelRecord model) {
    final size = model.sizeBytes;
    final architecture = model.architecture?.trim().toLowerCase();
    final blocks = model.blockCount;
    final embedding = model.embeddingLength;
    if (model.runtime != ModelRuntime.llamaCpp ||
        model.status != ModelInstallStatus.installed ||
        size == null || size <= 0 || size > (1 << 60) ||
        architecture == null || architecture.isEmpty ||
        architecture.length > 64 ||
        blocks == null || blocks < 1 || blocks > 1024 ||
        embedding == null || embedding < 1 || embedding > 65536 ||
        !_optionalRange(model.contextLength, 1, 1 << 20) ||
        !_optionalRange(model.attentionHeadCount, 1, 512) ||
        !_optionalRange(model.attentionHeadCountKv, 1, 512) ||
        !_optionalRange(model.attentionKeyLength, 1, 4096) ||
        !_optionalRange(model.attentionValueLength, 1, 4096) ||
        !_optionalRange(model.fileType, 0, 1 << 16) ||
        !_optionalRange(model.parameterCount, 1, 1 << 50)) {
      return null;
    }
    return PeerInstalledModelProfile(
      fileBytes: size,
      architecture: architecture,
      contextLength: model.contextLength,
      blockCount: blocks,
      embeddingLength: embedding,
      attentionHeadCount: model.attentionHeadCount,
      attentionHeadCountKv: model.attentionHeadCountKv,
      attentionKeyLength: model.attentionKeyLength,
      attentionValueLength: model.attentionValueLength,
      fileType: model.fileType,
      parameterCount: model.parameterCount,
    );
  }

  /// Stable metadata key shared by devices. This is deliberately not called a
  /// file hash: two different weight files can share the same GGUF metadata.
  String get signature => [
        architecture,
        fileBytes,
        contextLength ?? '-',
        blockCount,
        embeddingLength,
        attentionHeadCount ?? '-',
        attentionHeadCountKv ?? '-',
        attentionKeyLength ?? '-',
        attentionValueLength ?? '-',
        fileType ?? '-',
        parameterCount ?? '-',
      ].join('|');

  static bool _optionalRange(int? value, int minimum, int maximum) =>
      value == null || (value >= minimum && value <= maximum);
}
