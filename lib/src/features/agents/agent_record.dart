enum AgentRecordStatus { draft, ready, paused }

class AgentRecord {
  const AgentRecord({
    required this.id,
    required this.name,
    required this.description,
    required this.status,
    required this.createdAtUnixMs,
    this.modelId,
    this.systemPrompt = '',
  });

  final String id;
  final String name;
  final String description;
  final AgentRecordStatus status;
  final String? modelId;
  final String systemPrompt;
  final int createdAtUnixMs;

  String get statusValue => status.name;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'status': statusValue,
        'model_id': modelId,
        'system_prompt': systemPrompt,
        'created_at_unix_ms': createdAtUnixMs,
      };

  factory AgentRecord.fromMap(Map<String, Object?> map) {
    return AgentRecord(
      id: map['id']! as String,
      name: map['name']! as String,
      description: map['description']! as String,
      status: AgentRecordStatus.values.byName(map['status']! as String),
      modelId: map['model_id'] as String?,
      systemPrompt: map['system_prompt'] as String? ?? '',
      createdAtUnixMs: map['created_at_unix_ms']! as int,
    );
  }
}
