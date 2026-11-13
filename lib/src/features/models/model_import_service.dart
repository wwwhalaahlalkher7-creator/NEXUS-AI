import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_record.dart';
import 'rust_gguf_inspector.dart';

class ImportedModelFile {
  const ImportedModelFile({
    required this.path,
    required this.sizeBytes,
    required this.inspection,
  });

  final String path;
  final int sizeBytes;
  final GgufInspection inspection;
}

abstract interface class ModelImportService {
  Future<ImportedModelFile?> importGguf(ModelRecord model);
}

/// NEXUS Alpha 1.6 supports single-file GGUF imports only. llama.cpp can load
/// split GGUF sets, but the current importer intentionally copies one file.
bool isSingleFileGgufPath(String path) => !RegExp(
      r'-\d{5}-of-\d{5}\.gguf$',
      caseSensitive: false,
    ).hasMatch(p.basename(path));

class LocalGgufModelImportService implements ModelImportService {
  LocalGgufModelImportService({RustGgufInspector? inspector})
      : _inspector = inspector ?? RustGgufInspector();

  final RustGgufInspector _inspector;

  @override
  Future<ImportedModelFile?> importGguf(ModelRecord model) async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gguf'],
      allowMultiple: false,
      withData: false,
    );
    if (selected == null || selected.files.isEmpty) return null;

    final sourcePath = selected.files.single.path;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw StateError('تعذر الحصول على مسار الملف من منتقي الملفات.');
    }

    if (!isSingleFileGgufPath(sourcePath)) {
      throw UnsupportedError(
        'النماذج المقسّمة إلى عدة ملفات GGUF غير مدعومة حالياً. '
        'استورد نموذجاً بملف GGUF واحد.',
      );
    }

    final sourceInspection = await _inspector.inspect(sourcePath);
    if (!sourceInspection.validHeader) {
      throw FormatException(sourceInspection.message);
    }

    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(model.id)) {
      throw StateError('معرّف النموذج غير صالح لمسار التخزين.');
    }

    final supportDirectory = await getApplicationSupportDirectory();
    final modelDirectory = Directory(p.join(supportDirectory.path, 'models'));
    await modelDirectory.create(recursive: true);
    final destinationPath = p.join(modelDirectory.path, '${model.id}.gguf');

    final source = File(sourcePath);
    final destination = File(destinationPath);
    if (p.equals(source.absolute.path, destination.absolute.path)) {
      return ImportedModelFile(
        path: destinationPath,
        sizeBytes: sourceInspection.sizeBytes,
        inspection: sourceInspection,
      );
    }

    final staging = File('$destinationPath.importing.gguf');
    final backup = File('$destinationPath.previous');
    // Recover an interrupted previous replacement before starting a new one.
    if (await backup.exists()) {
      if (await destination.exists()) {
        await backup.delete();
      } else {
        await backup.rename(destinationPath);
      }
    }
    var previousMoved = false;
    try {
      await source.copy(staging.path);
      final copiedSize = await staging.length();
      if (copiedSize != sourceInspection.sizeBytes) {
        throw FileSystemException('حجم الملف المنسوخ لا يطابق الملف الذي تم فحصه.');
      }

      // Inspect the staged copy as well, so the metadata stored in SQLite
      // describes the exact bytes that will be retained in app-private storage.
      final stagedInspection = await _inspector.inspect(staging.path);
      if (!stagedInspection.validHeader) {
        throw FormatException(stagedInspection.message);
      }

      if (await backup.exists()) {
        await backup.delete();
      }
      if (await destination.exists()) {
        await destination.rename(backup.path);
        previousMoved = true;
      }
      await staging.rename(destinationPath);

      if (previousMoved && await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The new model is already installed; a stale backup is safer than
          // reporting a failed import after the destination has been replaced.
        }
      }

      return ImportedModelFile(
        path: destinationPath,
        sizeBytes: stagedInspection.sizeBytes,
        inspection: stagedInspection,
      );
    } catch (_) {
      if (await staging.exists()) {
        try {
          await staging.delete();
        } on FileSystemException {
          // Keep the original failure as the primary error.
        }
      }
      if (previousMoved && await backup.exists() && !(await destination.exists())) {
        await backup.rename(destinationPath);
      }
      rethrow;
    }
  }
}
