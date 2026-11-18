import 'dart:async';
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

  // Two windows in the same desktop process can write one thread. Serialize
  // its mutations without making writes to independent threads wait.
  static final _writes = <String, Future<void>>{};

  Future<void> _mutate(File file, Future<void> Function() action) {
    final key = _key(file.absolute.path);
    final completed = (_writes[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = completed.then<void>((_) {}, onError: (Object _) {});
    _writes[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_writes[key], settled)) _writes.remove(key);
      }),
    );
    return completed;
  }

  /// Separate files per thread keep an interrupted publish from destroying
  /// other projects. The existing record stays readable until replacement.
  Future<void> remember(SessionRecord record) async {
    final file = _file(record.id);
    if (file == null || record.cwd.trim().isEmpty) return;
    await _mutate(file, () async {
      final previous = await _readRecord(file);
      if (previous != null && previous.updatedAt.isAfter(record.updatedAt)) {
        return;
      }
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
        await _replace(pending, file);
      } finally {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // A transient lock on staging must not invalidate a saved entry.
        }
      }
    });
  }

  // Short leases from other readers and security scanners can block a
  // Windows rename. Never delete the old file to work around a failed rename.
  Future<void> _replace(File pending, File destination) async {
    for (var retry = 0; ; retry++) {
      try {
        await pending.rename(destination.path);
        return;
      } on FileSystemException catch (error) {
        const transient = {5, 32, 33};
        if (!Platform.isWindows ||
            retry == 3 ||
            !transient.contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 25 << retry));
      }
    }
  }

  @override
  Future<void> delete(String id) async {
    final file = _file(id);
    if (file == null) return;
    await _mutate(file, () async {
      try {
        await file.delete();
      } on FileSystemException {
        if (await file.exists()) rethrow;
      }
    });
  }

  Future<SessionRecord?> _readRecord(File entry) async {
    try {
      if (await entry.length() > 64 * 1024) return null;
      final parsed = jsonDecode(await entry.readAsString());
      if (parsed is! Map) return null;
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
        return null;
      }
      final updated = DateTime.tryParse(timestamp);
      if (updated == null) return null;
      return SessionRecord(id: id, title: title, updatedAt: updated, cwd: cwd);
    } on FormatException {
      // A malformed item must not hide other projects or threads.
      return null;
    } on FileSystemException {
      // Another window may have removed the entry after the listing.
      return null;
    }
  }

  Future<List<SessionRecord>> _read() async {
    final dir = _directory;
    if (!await dir.exists()) return [];
    final records = <SessionRecord>[];
    final batch = <Future<SessionRecord?>>[];
    Future<void> collect() async {
      records.addAll((await Future.wait(batch)).whereType<SessionRecord>());
      batch.clear();
    }

    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File || p.extension(entry.path) != '.json') continue;
      batch.add(_readRecord(entry));
      if (batch.length == 16) await collect();
    }
    await collect();
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
