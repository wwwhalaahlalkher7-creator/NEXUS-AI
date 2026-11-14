import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'knowledge_document.dart';
import 'knowledge_repository.dart';
import '../resources/resource_settings.dart';

typedef KnowledgeFilePicker = Future<PlatformFile?> Function({
  required FileType type,
  List<String>? allowedExtensions,
});

class KnowledgeImportService {
  KnowledgeImportService({
    KnowledgeFilePicker? filePicker,
    ResourceSettingsRepository? settingsRepository,
    DeviceResourceMonitor? resourceMonitor,
  })  : _filePicker = filePicker ?? _pickPlatformFile,
        _settingsRepository = settingsRepository ?? ResourceSettingsRepository(),
        _resourceMonitor = resourceMonitor ?? DeviceResourceMonitor();

  final KnowledgeFilePicker _filePicker;
  final ResourceSettingsRepository _settingsRepository;
  final DeviceResourceMonitor _resourceMonitor;

  static Future<PlatformFile?> _pickPlatformFile({
    required FileType type,
    List<String>? allowedExtensions,
  }) =>
      FilePicker.pickFile(type: type, allowedExtensions: allowedExtensions);

  Future<KnowledgeDocument?> pickAndImport(
    KnowledgeRepository repository,
  ) async {
    final file = await _filePicker(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'md', 'markdown'],
    );
    if (file == null) {
      return null;
    }

    final fileSize = file.lengthSync() ?? await file.length();
    if (fileSize <= 0) {
      throw ArgumentError('The selected file is empty.');
    }
    final settings = await _settingsRepository.load();
    final snapshot = settings.mode == ResourceMode.unrestricted
        ? null
        : await _resourceMonitor.readSnapshot();
    final importBudget = settings.importBudgetBytes(snapshot);
    if (importBudget != null && fileSize > importBudget) {
      throw ArgumentError(
        'حجم الملف أكبر من ميزانية الذاكرة المتاحة حالياً. '
        'اختر وضع الأداء أو المفتوح، أو حرّر الذاكرة ثم أعد المحاولة.',
      );
    }
    final bytes = await _readBoundedBytes(file, importBudget);
    final text = utf8.decode(bytes, allowMalformed: false);
    final title = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return repository.importText(
      fileName: file.name,
      title: title,
      text: text,
    );
  }

  Future<Uint8List> _readBoundedBytes(PlatformFile file, int? maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (maxBytes != null && builder.length + chunk.length > maxBytes) {
        throw ArgumentError('تجاوز الملف ميزانية الذاكرة التي خُصصت للاستيراد.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
