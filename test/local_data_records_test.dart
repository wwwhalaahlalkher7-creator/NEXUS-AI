import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/conversations/conversation_record.dart';
import 'package:nexus_app/src/features/models/model_record.dart';

void main() {
  group('Conversation records', () {
    test('conversation round-trips through SQLite map format', () {
      const record = ConversationRecord(
        id: 'conversation-1',
        title: 'محادثة اختبار',
        createdAtUnixMs: 100,
        updatedAtUnixMs: 200,
        lastMessagePreview: 'رسالة أخيرة',
      );

      final restored = ConversationRecord.fromMap(record.toMap());

      expect(restored.id, record.id);
      expect(restored.title, record.title);
      expect(restored.updatedAtUnixMs, 200);
      expect(restored.lastMessagePreview, 'رسالة أخيرة');
    });

    test('message preserves role and delivery status', () {
      const record = MessageRecord(
        id: 'message-1',
        conversationId: 'conversation-1',
        role: MessageRole.assistant,
        content: 'رد محفوظ',
        status: MessageStatus.complete,
        createdAtUnixMs: 300,
      );

      final restored = MessageRecord.fromMap(record.toMap());

      expect(restored.role, MessageRole.assistant);
      expect(restored.status, MessageStatus.complete);
      expect(restored.content, 'رد محفوظ');
    });
  });

  test('model record preserves runtime and installation metadata', () {
    const record = ModelRecord(
      id: 'model-1',
      displayName: 'Local model',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.registered,
      createdAtUnixMs: 10,
      updatedAtUnixMs: 20,
    );

    final restored = ModelRecord.fromMap(record.toMap());

    expect(restored.runtime, ModelRuntime.llamaCpp);
    expect(restored.status, ModelInstallStatus.registered);
    expect(restored.localPath, isNull);
  });
}
