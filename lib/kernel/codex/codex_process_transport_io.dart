import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'codex_transport.dart';

CodexTransport createCodexProcessTransport({required String cwd}) =>
    _CodexProcessTransport(cwd);

/// One app-server connection. Start only when the first RPC is sent, and
/// return an error followed by EOF if the connection can no longer carry RPCs.
final class _CodexProcessTransport implements ManagedCodexTransport {
  _CodexProcessTransport(this._cwd);

  final String _cwd;
  final _messages = StreamController<Map<String, Object?>>();
  final _pending = <String>[];
  final _stopped = Completer<void>();
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  bool _starting = false;
  bool _closed = false;
  bool _exited = false;
  Timer? _killTimer;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get stopped => _stopped.future;

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    final line = jsonEncode(message);
    final process = _process;
    if (process != null) {
      _writeLine(process, line);
      return;
    }
    _pending.add(line);
    if (!_starting) {
      _starting = true;
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    try {
      if (_cwd.isEmpty || !await Directory(_cwd).exists()) {
        _fail('The project folder is not available on this computer.');
        return;
      }
      final executable = await _findCodex();
      if (_closed) return;
      if (executable == null) {
        _fail(
          'Codex CLI not found. Install the official Codex CLI and restart '
          'BaoCode, or set BAOCODE_CODEX_PATH to the full executable path.',
        );
        return;
      }
      final process = await Process.start(
        executable,
        const ['app-server'],
        workingDirectory: _cwd,
        runInShell: false,
      );
      if (_closed) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        return;
      }
      _process = process;
      final drained = Completer<void>();
      _stdout = process.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (Object _) => _fail('Could not read the Codex response.'),
            onDone: drained.complete,
          );
      // Drain stderr to avoid blocking the child. It can include private
      // paths and other diagnostics; don't forward it as a chat/UI event.
      _stderr = process.stderr.listen((_) {}, onError: (Object _) {});
      unawaited(
        process.stdin.done.then<void>(
          (_) {},
          onError: (Object _) => _fail('Could not send a request to Codex.'),
        ),
      );
      unawaited(_watchExit(process, drained.future));
      final pending = List<String>.of(_pending);
      _pending.clear();
      for (final line in pending) {
        if (_closed) break;
        _writeLine(process, line);
      }
    } catch (_) {
      _fail('Could not start Codex App Server. Check your Codex installation.');
    } finally {
      _starting = false;
      if (_closed && _process == null) _settleStopped();
    }
  }

  Future<void> _watchExit(Process process, Future<void> drained) async {
    try {
      final code = await process.exitCode;
      _exited = true;
      _settleStopped();
      // An exit can be observed before the last stdout message arrives.
      await drained.timeout(const Duration(seconds: 1), onTimeout: () {});
      _fail('Codex App Server exited (code $code).');
    } catch (_) {
      _exited = true;
      _settleStopped();
      _fail('Lost the connection to Codex App Server.');
    }
  }

  void _settleStopped() {
    _killTimer?.cancel();
    if (!_stopped.isCompleted) _stopped.complete();
  }

  void _onLine(String line) {
    if (_closed || line.trim().isEmpty) return;
    try {
      final message = jsonDecode(line);
      if (message is! Map<String, Object?>) {
        _fail('Codex App Server returned an invalid response.');
        return;
      }
      _messages.add(message);
    } on FormatException {
      _fail('Codex App Server returned an invalid response.');
    }
  }

  void _writeLine(Process process, String line) {
    try {
      process.stdin.writeln(line);
    } catch (_) {
      _fail('Could not send a request to Codex.');
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _messages.addError(StateError(message));
    close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    final stdout = _stdout;
    final stderr = _stderr;
    if (stdout != null) unawaited(stdout.cancel());
    if (stderr != null) unawaited(stderr.cancel());
    final process = _process;
    if (process != null && !_exited) {
      unawaited(
        process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      );
      process.kill();
      _killTimer = Timer(const Duration(seconds: 2), () {
        if (!_exited) process.kill(ProcessSignal.sigkill);
      });
    } else if (!_starting) {
      _settleStopped();
    }
    unawaited(_messages.close());
  }
}

Future<String?> _findCodex() async {
  final env = Platform.environment;
  final configured = env['BAOCODE_CODEX_PATH'];
  if (configured != null && configured.isNotEmpty) {
    if (!p.isAbsolute(configured) ||
        (Platform.isWindows && !configured.toLowerCase().endsWith('.exe'))) {
      return null;
    }
    return await File(configured).exists() ? configured : null;
  }

  final windows = Platform.isWindows;
  final dirSeparator = windows ? ';' : ':';
  final path = windows
      ? env.entries
            .where((entry) => entry.key.toLowerCase() == 'path')
            .firstOrNull
            ?.value
      : env['PATH'];
  final directories = <String>{
    for (final entry in (path ?? '').split(dirSeparator))
      _stripQuotes(entry.trim()),
    if (env['APPDATA'] case final appData? when windows) p.join(appData, 'npm'),
    if (env['HOME'] case final home? when !windows)
      p.join(home, '.local', 'bin'),
    if (!windows) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ],
  }.where(p.isAbsolute);
  for (final dir in directories) {
    // No implicit current directory lookup and no .cmd shim or shell. The
    // directory is fixed before Process.start receives the project folder.
    final native = p.join(dir, windows ? 'codex.exe' : 'codex');
    if (await File(native).exists()) return native;
    if (!windows) continue;

    // npm installs a .cmd shim, but the official package also ships its
    // native executable. Look only in the known global package layout.
    final arm64 =
        (env['PROCESSOR_ARCHITEW6432'] ?? env['PROCESSOR_ARCHITECTURE'])
            ?.toLowerCase() ==
        'arm64';
    for (final arch in arm64 ? ['arm64', 'x64'] : ['x64']) {
      final triple = arch == 'arm64'
          ? 'aarch64-pc-windows-msvc'
          : 'x86_64-pc-windows-msvc';
      final packages = p.join(dir, 'node_modules', '@openai');
      for (final vendor in [
        p.join(packages, 'codex-win32-$arch', 'vendor'),
        p.join(
          packages,
          'codex',
          'node_modules',
          '@openai',
          'codex-win32-$arch',
          'vendor',
        ),
        p.join(packages, 'codex', 'vendor'),
      ]) {
        for (final exe in [
          p.join(vendor, triple, 'bin', 'codex.exe'),
          p.join(vendor, triple, 'codex', 'codex.exe'),
        ]) {
          if (await File(exe).exists()) return exe;
        }
      }
    }
  }
  return null;
}

String _stripQuotes(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.substring(1, value.length - 1)
    : value;
