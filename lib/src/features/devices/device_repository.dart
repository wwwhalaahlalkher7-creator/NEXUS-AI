import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'device_record.dart';

class PairedDeviceRepository {
  PairedDeviceRepository({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<PairedDeviceRecord>> list() async {
    final db = await _database.database;
    final rows = await db.query(
      'paired_devices',
      orderBy: 'last_seen_unix_ms DESC, display_name COLLATE NOCASE ASC',
    );
    return rows.map(PairedDeviceRecord.fromMap).toList(growable: false);
  }

  Future<PairedDeviceRecord?> get(String id) async {
    final db = await _database.database;
    final rows = await db.query(
      'paired_devices',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : PairedDeviceRecord.fromMap(rows.single);
  }

  Future<void> upsert({
    required String id,
    required String displayName,
    required String platform,
    required String address,
    required int port,
    required String fingerprint,
    required Map<String, Object?> capabilities,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await get(id);
    await db.insert(
      'paired_devices',
      {
        'id': id,
        'display_name': displayName,
        'platform': platform,
        'last_address': address,
        'last_port': port,
        'fingerprint': fingerprint,
        'capabilities_json': jsonEncode(capabilities),
        'trust_status': 'paired',
        'paired_at_unix_ms': existing?.pairedAtUnixMs ?? now,
        'last_seen_unix_ms': now,
        'created_at_unix_ms': existing?.createdAtUnixMs ?? now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _appendEvent(
      id,
      existing == null ? 'paired' : 'connected',
      existing == null ? 'تم إقران جهاز جديد.' : 'تم الاتصال بالجهاز.',
    );
  }

  Future<void> updateCapabilities(
    String id,
    Map<String, Object?> capabilities,
  ) async {
    final db = await _database.database;
    await db.update(
      'paired_devices',
      {
        'capabilities_json': jsonEncode(capabilities),
        'last_seen_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ? AND trust_status = ?',
      whereArgs: [id, 'paired'],
    );
  }

  Future<void> updateLastSeen(String id) async {
    final db = await _database.database;
    await db.update(
      'paired_devices',
      {'last_seen_unix_ms': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setBlocked(String id, bool blocked) async {
    final db = await _database.database;
    await db.update(
      'paired_devices',
      {'trust_status': blocked ? 'blocked' : 'paired'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _appendEvent(
      id,
      blocked ? 'blocked' : 'unblocked',
      blocked ? 'تم حظر الجهاز.' : 'تم رفع الحظر عن الجهاز.',
    );
  }

  Future<void> remove(String id) async {
    final db = await _database.database;
    await db.delete('paired_devices', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _appendEvent(String deviceId, String type, String message) async {
    final db = await _database.database;
    await db.insert('device_events', {
      'id': 'device-event-${DateTime.now().microsecondsSinceEpoch}',
      'device_id': deviceId,
      'event_type': type,
      'message': message,
      'created_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
