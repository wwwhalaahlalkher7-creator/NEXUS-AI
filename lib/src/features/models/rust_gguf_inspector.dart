import 'dart:io';

import '../../rust/api/simple.dart' as rust_api;
import '../runtime/rust_bridge_initializer.dart';

class GgufInspection {
  const GgufInspection({
    required this.validHeader,
    required this.fileName,
    required this.sizeBytes,
    required this.formatVersion,
    required this.tensorCount,
    required this.metadataCount,
    required this.message,
    this.architecture,
    this.modelName,
    this.tokenizerModel,
    this.contextLength,
    this.blockCount,
    this.embeddingLength,
    this.attentionHeadCount,
    this.attentionHeadCountKv,
    this.attentionKeyLength,
    this.attentionValueLength,
    this.fileType,
    this.parameterCount,
  });

  final bool validHeader;
  final String fileName;
  final int sizeBytes;
  final int formatVersion;
  final int tensorCount;
  final int metadataCount;
  final String? architecture;
  final String? modelName;
  final String? tokenizerModel;
  final int? contextLength;
  final int? blockCount;
  final int? embeddingLength;
  final int? attentionHeadCount;
  final int? attentionHeadCountKv;
  final int? attentionKeyLength;
  final int? attentionValueLength;
  final int? fileType;
  final int? parameterCount;
  final String message;
}

class RustGgufInspector {
  Future<GgufInspection> inspect(String path) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('فحص ملفات GGUF عبر Rust متاح على Android حالياً.');
    }
    await RustBridgeInitializer.ensureInitialized();
    final result = await rust_api.inspectGgufModelFile(path: path);
    return GgufInspection(
      validHeader: result.validHeader,
      fileName: result.fileName,
      sizeBytes: result.sizeBytes,
      formatVersion: result.formatVersion,
      tensorCount: result.tensorCount,
      metadataCount: result.metadataCount,
      architecture: result.architecture,
      modelName: result.modelName,
      tokenizerModel: result.tokenizerModel,
      contextLength: result.contextLength,
      blockCount: result.blockCount,
      embeddingLength: result.embeddingLength,
      attentionHeadCount: result.attentionHeadCount,
      attentionHeadCountKv: result.attentionHeadCountKv,
      attentionKeyLength: result.attentionKeyLength,
      attentionValueLength: result.attentionValueLength,
      fileType: result.fileType,
      parameterCount: result.parameterCount,
      message: result.message,
    );
  }
}
