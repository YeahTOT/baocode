import 'dart:convert';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, SessionStore;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;

import 'agy_remote_runtime.dart';
import 'agy_runtime.dart';

/// A remote AGY conversation also has BaoCode's Claude-compatible transcript.
/// Use the remote state directory so the existing catalog and all front ends
/// read the same chat, including after switching to another upstream.
class RemoteAgyHistory {
  RemoteAgyHistory._(this.runtime, this.root, this.path, this._offset);
  final RemoteAgyRuntime runtime;
  final String root;
  final String path;
  int _offset;
  Future<void> _pending = Future.value();
  bool _failed = false;
  bool get failed => _failed;

  static Future<({RemoteAgyHistory history, SessionStore store})> open(
    RemoteAgyRuntime runtime,
    String cwd,
    String id, {
    required bool persist,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid conversation ID');
    }
    final client = await runtime.client;
    final config = await client
        .run('/bin/sh', [
          '-c',
          r'''printf '%s' "${BAOCODE_CLAUDE_DATA_PATH:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"''',
        ])
        .timeout(RemoteAgyRuntime.wait);
    final dir = config.stdout.trim();
    if (config.exitCode != 0 ||
        !p.posix.isAbsolute(dir) ||
        dir == '/' ||
        dir.contains(RegExp(r'[\r\n\x00]'))) {
      throw const AgyUnavailable('Could not locate remote session storage');
    }
    final root = p.posix.join(dir, 'projects', AgentPaths.projectDirName(cwd));
    final path = p.posix.join(root, '$id.jsonl');
    final kind = await client.stat(path).timeout(RemoteAgyRuntime.wait);
    final data = kind == 'file'
        ? await client.readBytes(path).timeout(RemoteAgyRuntime.wait)
        : const <int>[];
    final history = RemoteAgyHistory._(runtime, root, path, data.length);
    if (persist && kind == null) {
      final result = await client
          .run('/bin/sh', [
            '-c',
            r'''umask 077; mkdir -p -- "$1" && (set -C; : > "$2")''',
            'baocode-agy-storage',
            root,
            path,
          ])
          .timeout(RemoteAgyRuntime.wait);
      if (result.exitCode != 0) {
        throw const AgyUnavailable(
          'Could not create remote session transcript',
        );
      }
    } else if (kind != null && kind != 'file') {
      throw const AgyUnavailable('Invalid remote session transcript');
    }
    return (
      history: history,
      store: SessionStore.resumeText(
        sessionId: id,
        cwd: cwd,
        text: utf8.decode(data, allowMalformed: true),
        writeEntry: persist ? history._write : null,
      ),
    );
  }

  void _write(Map<String, Object?> entry) {
    final data = utf8.encode('${jsonEncode(entry)}\n');
    _pending = _pending.then((_) async {
      if (_failed) return;
      try {
        // A screenshot can exceed the transport's single message limit.
        const chunk = 128 * 1024;
        for (var at = 0; at < data.length; at += chunk) {
          final end = at + chunk < data.length ? at + chunk : data.length;
          await _append(data.sublist(at, end));
        }
      } on Object {
        _failed = true;
      }
    });
  }

  Future<void> _append(List<int> data) async {
    final client = await runtime.client;
    try {
      await client
          .appendBytes(root, path, _offset, data)
          .timeout(RemoteAgyRuntime.wait);
    } on Object {
      // A lost acknowledgement must not duplicate an entry or overwrite
      // a transcript changed by another writer.
      final active = await runtime.client;
      final range = await active
          .readRange(path, _offset, data.length)
          .timeout(RemoteAgyRuntime.wait);
      if (range.size == _offset) {
        await active
            .appendBytes(root, path, _offset, data)
            .timeout(RemoteAgyRuntime.wait);
      } else if (range.size != _offset + data.length ||
          !listEquals(range.bytes, data)) {
        rethrow;
      }
    }
    _offset += data.length;
  }

  Future<void> flush() => _pending;
}
