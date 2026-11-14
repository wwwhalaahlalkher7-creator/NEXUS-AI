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
        agentId: 'agent-1',
      );

      final restored = ConversationRecord.fromMap(record.toMap());

      expect(restored.id, record.id);
      expect(restored.title, record.title);
      expect(restored.updatedAtUnixMs, 200);
      expect(restored.lastMessagePreview, 'رسالة أخيرة');
      expect(restored.agentId, 'agent-1');
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

    test('message preserves the explicit cancelled state', () {
      const record = MessageRecord(
        id: 'message-2',
        conversationId: 'conversation-1',
        role: MessageRole.assistant,
        content: 'نص جزئي',
        status: MessageStatus.cancelled,
        createdAtUnixMs: 400,
      );

      final restored = MessageRecord.fromMap(record.toMap());

      expect(restored.status, MessageStatus.cancelled);
      expect(restored.content, 'نص جزئي');
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
      architecture: 'llama',
      ggufModelName: 'Test model metadata',
      contextLength: 4096,
      blockCount: 32,
      embeddingLength: 2048,
      attentionHeadCount: 32,
      attentionHeadCountKv: 8,
      attentionKeyLength: 64,
      attentionValueLength: 64,
      fileType: 15,
      parameterCount: 3000000000,
    );

    final restored = ModelRecord.fromMap(record.toMap());

    expect(restored.runtime, ModelRuntime.llamaCpp);
    expect(restored.status, ModelInstallStatus.registered);
    expect(restored.localPath, isNull);
    expect(restored.architecture, 'llama');
    expect(restored.contextLength, 4096);
    expect(restored.blockCount, 32);
    expect(restored.embeddingLength, 2048);
    expect(restored.attentionHeadCount, 32);
    expect(restored.attentionHeadCountKv, 8);
    expect(restored.attentionKeyLength, 64);
    expect(restored.attentionValueLength, 64);
    expect(restored.parameterCount, 3000000000);
  });
}
