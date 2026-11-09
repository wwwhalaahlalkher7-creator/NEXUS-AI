enum ModelRuntime { llamaCpp, external }

enum ModelInstallStatus { registered, installed, unavailable }

class ModelRecord {
  const ModelRecord({
    required this.id,
    required this.displayName,
    required this.runtime,
    required this.status,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    this.localPath,
    this.sizeBytes,
    this.architecture,
    this.ggufModelName,
    this.tokenizerModel,
    this.contextLength,
    this.blockCount,
    this.embeddingLength,
    this.fileType,
    this.parameterCount,
  });

  final String id;
  final String displayName;
  final ModelRuntime runtime;
  final ModelInstallStatus status;
  final String? localPath;
  final int? sizeBytes;
  final String? architecture;
  final String? ggufModelName;
  final String? tokenizerModel;
  final int? contextLength;
  final int? blockCount;
  final int? embeddingLength;
  final int? fileType;
  final int? parameterCount;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;

  Map<String, Object?> toMap() => {
        'id': id,
        'display_name': displayName,
        'runtime': runtime.name,
        'local_path': localPath,
        'status': status.name,
        'size_bytes': sizeBytes,
        'architecture': architecture,
        'gguf_model_name': ggufModelName,
        'tokenizer_model': tokenizerModel,
        'context_length': contextLength,
        'block_count': blockCount,
        'embedding_length': embeddingLength,
        'file_type': fileType,
        'parameter_count': parameterCount,
        'created_at_unix_ms': createdAtUnixMs,
        'updated_at_unix_ms': updatedAtUnixMs,
      };

  factory ModelRecord.fromMap(Map<String, Object?> map) {
    return ModelRecord(
      id: map['id']! as String,
      displayName: map['display_name']! as String,
      runtime: ModelRuntime.values.byName(map['runtime']! as String),
      status: ModelInstallStatus.values.byName(map['status']! as String),
      localPath: map['local_path'] as String?,
      sizeBytes: map['size_bytes'] as int?,
      architecture: map['architecture'] as String?,
      ggufModelName: map['gguf_model_name'] as String?,
      tokenizerModel: map['tokenizer_model'] as String?,
      contextLength: map['context_length'] as int?,
      blockCount: map['block_count'] as int?,
      embeddingLength: map['embedding_length'] as int?,
      fileType: map['file_type'] as int?,
      parameterCount: map['parameter_count'] as int?,
      createdAtUnixMs: map['created_at_unix_ms']! as int,
      updatedAtUnixMs: map['updated_at_unix_ms']! as int,
    );
  }
}
