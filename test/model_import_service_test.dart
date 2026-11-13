import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_import_service.dart';

void main() {
  test('accepts a single-file GGUF name', () {
    expect(isSingleFileGgufPath('/models/tiny-model.gguf'), isTrue);
    expect(isSingleFileGgufPath('/models/TINY-MODEL.GGUF'), isTrue);
  });

  test('rejects split GGUF shard names before the importer copies one shard', () {
    expect(isSingleFileGgufPath('/models/model-00001-of-00003.gguf'), isFalse);
    expect(isSingleFileGgufPath('/models/model-00003-of-00003.GGUF'), isFalse);
  });
}
