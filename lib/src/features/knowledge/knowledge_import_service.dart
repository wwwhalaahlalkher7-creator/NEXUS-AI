import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'knowledge_document.dart';
import 'knowledge_repository.dart';
import '../resources/resource_settings.dart';

class KnowledgeImportService {
  KnowledgeImportService({
    FilePicker? filePicker,
    ResourceSettingsRepository? settingsRepository,
    DeviceResourceMonitor? resourceMonitor,
  })  : _filePicker = filePicker ?? FilePicker.platform,
        _settingsRepository = settingsRepository ?? ResourceSettingsRepository(),
        _resourceMonitor = resourceMonitor ?? const DeviceResourceMonitor();

  final FilePicker _filePicker;
  final ResourceSettingsRepository _settingsRepository;
  final DeviceResourceMonitor _resourceMonitor;

  Future<KnowledgeDocument?> pickAndImport(
    KnowledgeRepository repository,
  ) async {
    final selection = await _filePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'md', 'markdown'],
      allowMultiple: false,
      withData: false,
      withReadStream: true,
    );
    if (selection == null || selection.files.isEmpty) {
      return null;
    }

    final file = selection.files.single;
    if (file.size <= 0) {
      throw ArgumentError('The selected file is empty.');
    }
    final settings = await _settingsRepository.load();
    final snapshot = settings.mode == ResourceMode.unrestricted
        ? null
        : await _resourceMonitor.readSnapshot();
    final importBudget = settings.importBudgetBytes(snapshot);
    if (importBudget != null && file.size > importBudget) {
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
    final stream = file.readStream;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (maxBytes != null && builder.length + chunk.length > maxBytes) {
          throw ArgumentError('تجاوز الملف ميزانية الذاكرة التي خُصصت للاستيراد.');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    }
    final bytes = file.bytes;
    if (bytes == null) {
      throw StateError(
        'This Android file provider did not expose a readable stream.',
      );
    }
    if (maxBytes != null && bytes.length > maxBytes) {
      throw ArgumentError('تجاوز الملف ميزانية الذاكرة التي خُصصت للاستيراد.');
    }
    return bytes;
  }
}
