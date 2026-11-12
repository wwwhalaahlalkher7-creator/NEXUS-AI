import 'dart:io';

import 'model_record.dart';
import 'rust_gguf_inspector.dart';

class ModelFileVerification {
  const ModelFileVerification({
    required this.isValid,
    required this.message,
    this.actualSizeBytes,
  });

  final bool isValid;
  final String message;
  final int? actualSizeBytes;
}

abstract interface class ModelFileVerifier {
  Future<ModelFileVerification> verify(ModelRecord model);
}

/// Performs a bounded local-file audit. It does not hash tensor payloads,
/// validate tensor offsets, or prove that the model can run on this device.
class LocalModelFileVerifier implements ModelFileVerifier {
  LocalModelFileVerifier({RustGgufInspector? inspector})
      : _inspector = inspector ?? RustGgufInspector();

  final RustGgufInspector _inspector;

  @override
  Future<ModelFileVerification> verify(ModelRecord model) async {
    if (model.status != ModelInstallStatus.installed ||
        model.localPath == null ||
        model.localPath!.isEmpty) {
      return const ModelFileVerification(
        isValid: false,
        message: 'لا يوجد مسار محلي مسجل لهذا النموذج.',
      );
    }

    final file = File(model.localPath!);
    if (!await file.exists()) {
      return const ModelFileVerification(
        isValid: false,
        message: 'ملف النموذج غير موجود في مساره المحلي.',
      );
    }

    final actualSize = await file.length();
    if (model.sizeBytes != null && actualSize != model.sizeBytes) {
      return ModelFileVerification(
        isValid: false,
        actualSizeBytes: actualSize,
        message: 'حجم الملف الحالي لا يطابق الحجم المحفوظ في المكتبة.',
      );
    }

    final inspection = await _inspector.inspect(file.path);
    if (!inspection.validHeader) {
      return ModelFileVerification(
        isValid: false,
        actualSizeBytes: actualSize,
        message: 'فشل فحص GGUF: ${inspection.message}',
      );
    }

    return ModelFileVerification(
      isValid: true,
      actualSizeBytes: actualSize,
      message: 'الملف موجود، والحجم مطابق، واجتاز فحص الترويسة والبيانات الوصفية. لم يتم فحص أوزان الموترات أو اختبار تشغيل النموذج.',
    );
  }
}
