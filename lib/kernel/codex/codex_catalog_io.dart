import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../agent_kernel.dart';

/// A local index of threads created by BaoCode, separate from Codex's
/// canonical thread data. Deleting an entry only forgets it here.
class CodexCatalog implements SessionCatalog {
  const CodexCatalog({this.directory});

  final String? directory;

  Directory get _directory => Directory(
    directory ?? p.join(DataDirectory.current.stateDir, 'codex-threads'),
  );

  static final _threadId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  File? _file(String id) =>
      _threadId.hasMatch(id) ? File(p.join(_directory.path, '$id.json')) : null;

  /// A separate record for each thread allows multiple project windows to
  /// save independently. Rename publishes only a complete record.
  Future<void> remember(SessionRecord record) async {
    final file = _file(record.id);
    if (file == null || record.cwd.trim().isEmpty) return;
    final dir = await _directory.create(recursive: true);
    final staging = await dir.createTemp('.write-');
    try {
      final pending = File(p.join(staging.path, 'entry.json'));
      await pending.writeAsString(
        jsonEncode({
          'id': record.id,
          'cwd': record.cwd,
          'title': record.title,
          'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  @override
  Future<void> delete(String id) async {
    final file = _file(id);
    if (file == null) return;
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
  }

  Future<List<SessionRecord>> _read() async {
    final dir = _directory;
    if (!await dir.exists()) return [];
    final records = <SessionRecord>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File || p.extension(entry.path) != '.json') continue;
      try {
        final parsed = jsonDecode(await entry.readAsString());
        if (parsed is! Map) continue;
        final id = parsed['id'];
        final cwd = parsed['cwd'];
        final title = parsed['title'];
        final timestamp = parsed['updatedAt'];
        if (id is! String ||
            id != p.basenameWithoutExtension(entry.path) ||
            !_threadId.hasMatch(id) ||
            cwd is! String ||
            cwd.trim().isEmpty ||
            title is! String ||
            timestamp is! String) {
          continue;
        }
        final updated = DateTime.tryParse(timestamp);
        if (updated == null) continue;
        records.add(
          SessionRecord(id: id, title: title, updatedAt: updated, cwd: cwd),
        );
      } on FormatException {
        // A malformed item must not hide other projects or threads.
      } on FileSystemException {
        // Another window may have removed the entry after the listing.
      }
    }
    records.sort((a, b) {
      final order = b.updatedAt.compareTo(a.updatedAt);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return records;
  }

  String _key(String cwd) {
    final path = p.normalize(cwd);
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final groups = <String, List<SessionRecord>>{};
    for (final record in await _read()) {
      groups.putIfAbsent(_key(record.cwd), () => []).add(record);
    }
    return [
      for (final sessions in groups.values)
        ProjectRecord(path: sessions.first.cwd, sessions: sessions),
    ];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final key = _key(cwd);
    return [
      for (final record in await _read())
        if (_key(record.cwd) == key) record,
    ];
  }
}
