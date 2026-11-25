import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';
import 'package:path/path.dart' as p;

import '../../remote/remote_location.dart';
import '../../remote/ssh_host.dart';
import '../acp/acp_connection.dart';
import 'agy_runtime.dart';

/// Antigravity on the Linux side of a Bao remote connection (SSH or WSL).
/// The executable, Google sign-in and native sessions belong to that user.
class RemoteAgyRuntime implements AgyRuntime {
  RemoteAgyRuntime(this.host, {Future<RemoteClient> Function()? connect})
    : _connect = connect ?? (() => SshHosts.instance[host].ready);

  final String host;
  final Future<RemoteClient> Function() _connect;
  static const wait = Duration(seconds: 30);
  final _live = <_RemoteAcp>{};

  String get setup =>
      'Install agy in ${RemoteLocation.hostName(host)} and sign in there '
      'as the project user with agy acp --login.';

  String pathOf(String location) {
    final target = RemoteLocation.hostOf(location);
    final path = RemoteLocation.pathOf(location);
    if ((target != null && target != host) ||
        !p.posix.isAbsolute(path) ||
        path.contains('\x00')) {
      throw ArgumentError.value(location, 'location', 'Not on this Linux host');
    }
    return p.posix.normalize(path);
  }

  Future<RemoteClient> get client async {
    final client = await _connect().timeout(wait);
    if (client.hello?.platform.os != 'linux') {
      throw const AgyUnavailable('Remote Antigravity requires Linux');
    }
    return client;
  }

  Future<String?> _locate(RemoteClient client) async {
    final cancel = Completer<void>();
    try {
      final result = await client
          .run('/bin/sh', [
            '-c',
            r'''
bin=$(command -v agy)
case "$bin" in /*) [ -f "$bin" ] && [ -x "$bin" ] && printf '%s' "$bin" && exit 0;; esac
bin="$HOME/.local/bin/agy"
[ -n "$HOME" ] && [ -f "$bin" ] && [ -x "$bin" ] && printf '%s' "$bin"
''',
          ], cancel: cancel.future)
          .timeout(wait);
      final bin = result.stdout.trim();
      return result.exitCode == 0 &&
              p.posix.isAbsolute(bin) &&
              !bin.contains(RegExp(r'[\r\n\x00]'))
          ? bin
          : null;
    } finally {
      cancel.complete();
    }
  }

  Future<String> _executable(RemoteClient client) async =>
      await _locate(client) ??
      (throw AgyUnavailable(
        'Antigravity is not installed on $host',
        notInstalled: true,
        detail: setup,
      ));

  @override
  Future<String?> version() async {
    final root = await client;
    final bin = await _locate(root);
    if (bin == null) return null;
    final cancel = Completer<void>();
    try {
      final result = await root
          .run(bin, const ['--version'], cancel: cancel.future)
          .timeout(wait);
      if (result.exitCode != 0) {
        throw AgyUnavailable(
          'Antigravity could not start on $host',
          detail: setup,
        );
      }
      return RegExp(r'\d+\.\d+\.\d+').stringMatch(result.stdout) ?? 'installed';
    } finally {
      cancel.complete();
    }
  }

  @override
  Future<List<AgyModel>> models() async {
    final root = await client;
    final bin = await _executable(root);
    final cancel = Completer<void>();
    try {
      final result = await root
          .run(bin, const ['models'], cancel: cancel.future)
          .timeout(wait);
      final models = parseAgyModels(result.stdout);
      if (result.exitCode == 0 && models.isNotEmpty) return models;
      // The command may print account or diagnostic details. Do not put
      // those into a local log or model picker.
      throw AgyUnavailable(
        'Antigravity models are not available on $host',
        detail: setup,
      );
    } finally {
      cancel.complete();
    }
  }

  @override
  Future<AcpTransport> start(String cwd) async {
    final path = pathOf(cwd);
    final root = await client;
    final bin = await _executable(root);
    final starting = root.start(bin, const [
      'acp',
      '--disable-telemetry',
    ], cwd: path);
    try {
      final transport = _RemoteAcp(await starting.timeout(wait));
      _live.add(transport);
      unawaited(transport.exited.then((_) => _live.remove(transport)));
      return transport;
    } on TimeoutException {
      unawaited(starting.then<void>(_stop, onError: (Object _) {}));
      throw AgyUnavailable('Antigravity did not start on $host', detail: setup);
    }
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    final root = await client;
    final home = root.hello?.home;
    if (home == null || !p.posix.isAbsolute(home)) return;
    final connection = AcpConnection(
      await start(home),
      onRequest: (_, _) async => null,
      onNotification: (_, _) {},
    );
    try {
      await connection.request('initialize', agyHello).timeout(wait);
      await connection
          .request('session/delete', {'sessionId': sessionId})
          .timeout(wait);
    } finally {
      connection.close();
    }
  }

  @override
  void warm() {}

  @override
  Future<void> stopAll() async {
    final live = _live.toList();
    for (final transport in live) {
      transport.close();
    }
    await Future.wait(live.map((entry) => entry.exited)).timeout(wait);
  }

  Never _manual() =>
      throw AgyUnavailable('Manage Antigravity on $host', detail: setup);

  @override
  Future<String> latestVersion() async => _manual();

  @override
  Future<void> install({void Function(double progress)? onProgress}) async =>
      _manual();

  @override
  Future<void> signIn({Future<void>? cancel}) async => _manual();

  @override
  Future<void> signOut() async => _manual();
}

Future<void> _stop(RemoteProcess process) async {
  process.kill();
  await process.exitCode.timeout(
    const Duration(seconds: 2),
    onTimeout: () {
      process.kill(force: true);
      return RemoteProcess.lostExitCode;
    },
  );
}

class _RemoteAcp implements AcpTransport {
  _RemoteAcp(this._process) {
    final stdout = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          try {
            if (jsonDecode(line) case final Map<String, Object?> value) {
              _out.add(value);
            }
          } on FormatException {
            // Only ACP frames belong on this stream.
          }
        });
    final stderr = _process.stderr.drain<void>();
    exited = Future.wait<void>([stdout, stderr]).then(
      (_) async {
        final code = await _process.exitCode;
        unawaited(_out.close());
        return AcpExit(code);
      },
      onError: (Object _) {
        unawaited(_out.close());
        return const AcpExit(RemoteProcess.lostExitCode);
      },
    );
  }

  final RemoteProcess _process;
  final _out = StreamController<Map<String, Object?>>();
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  late final Future<AcpExit> exited;

  @override
  void write(Map<String, Object?> message) {
    if (!_closed) _process.write(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_stop(_process));
  }
}
