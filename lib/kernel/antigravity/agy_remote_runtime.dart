import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  String get setup => 'Antigravity on ${RemoteLocation.hostName(host)}';

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
      // Use output only to classify the failure, never display or log it.
      final signIn = RegExp(
        r'(?:log|sign)\s*in|authenticat|oauth|not logged',
        caseSensitive: false,
      ).hasMatch('${result.stdout}\n${result.stderr}');
      throw AgyUnavailable(
        'Antigravity models are not available on $host',
        signIn: signIn,
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

  static const _feed =
      'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests';
  static const _archiveHost = 'storage.googleapis.com';

  Future<({String version, Uri archive, String checksum})> _release(
    RemoteClient root,
  ) async {
    final arch = switch (root.hello!.platform.arch) {
      'x64' => 'amd64',
      'arm64' => 'arm64',
      _ => throw const AgyUnavailable('Antigravity does not support this CPU'),
    };
    final http = HttpClient()..connectionTimeout = wait;
    try {
      final request = await http.getUrl(Uri.parse('$_feed/linux_$arch.json'));
      request.followRedirects = false;
      final response = await request.close().timeout(wait);
      if (response.statusCode != 200) {
        throw const AgyUnavailable(
          'Google’s Antigravity release feed is unavailable',
        );
      }
      final body = <int>[];
      await for (final chunk in response.timeout(wait)) {
        body.addAll(chunk);
        if (body.length > 65536) {
          throw const AgyUnavailable('Invalid Antigravity release metadata');
        }
      }
      final json = jsonDecode(utf8.decode(body));
      if (json case {
        'version': final String version,
        'url': final String url,
        'sha512': final String checksum,
      }) {
        final archive = Uri.tryParse(url);
        if (RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) &&
            RegExp(r'^[a-fA-F\d]{128}$').hasMatch(checksum) &&
            archive != null &&
            archive.scheme == 'https' &&
            archive.host == _archiveHost &&
            archive.port == 443 &&
            archive.userInfo.isEmpty &&
            !archive.hasQuery &&
            !archive.hasFragment &&
            archive.path.startsWith('/antigravity-public/antigravity-cli/') &&
            archive.path.endsWith('.tar.gz')) {
          return (
            version: version,
            archive: archive,
            checksum: checksum.toLowerCase(),
          );
        }
      }
      throw const AgyUnavailable('Invalid Antigravity release metadata');
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<String> latestVersion() async =>
      (await _release(await client)).version;

  @override
  Future<void> install({void Function(double progress)? onProgress}) =>
      installOnHost(onProgress: onProgress);

  Future<void> installOnHost({
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    final root = await client;
    if (await _locate(root) != null || cancelled) return;
    final release = await _release(root);
    if (cancelled) return;
    onProgress?.call(0);
    final ended = Completer<void>();
    unawaited(
      cancel?.then((_) {
        if (!ended.isCompleted) ended.complete();
      }),
    );
    try {
      final result = await root
          .run('/bin/sh', [
            '-c',
            remoteAgyInstallScript,
            'baocode-install-agy',
            release.archive.toString(),
            release.checksum,
          ], cancel: ended.future)
          .timeout(const Duration(minutes: 6));
      if (cancelled) return;
      if (result.exitCode != 0 || await _locate(root) == null) {
        throw const AgyUnavailable(
          'Could not install Antigravity on this host',
          detail: 'Check internet access and that curl, tar and sha512sum are available.',
        );
      }
      onProgress?.call(1);
    } finally {
      if (!ended.isCompleted) ended.complete();
    }
  }

  /// Runs the official interactive CLI login on this host. The user opens
  /// the Google link and returns the short-lived authorization code in-app.
  Future<void> signInOnHost({
    required Future<String?> Function(Uri) authorize,
    Future<void>? cancel,
  }) async {
    final root = await client;
    final bin = await _executable(root);
    var cancelled = false;
    final stop = Completer<void>();
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        if (!stop.isCompleted) stop.complete();
      }),
    );
    final starting = root.start(bin, const ['acp', '--login']);
    final RemoteProcess process;
    try {
      process = await starting.timeout(wait);
    } on TimeoutException {
      unawaited(starting.then<void>(_stop, onError: (Object _) {}));
      rethrow;
    }
    final link = Completer<Uri?>();
    final tails = ['', ''];
    void output(int stream, String chunk) {
      var tail = tails[stream];
      if (link.isCompleted) return;
      tail += chunk;
      final cut = tail.lastIndexOf('\n');
      if (cut >= 0) {
        if (agyRemoteOAuthLink(tail.substring(0, cut)) case final uri?) {
          link.complete(uri);
        }
        tail = tail.substring(cut + 1);
      }
      tails[stream] = tail.length > 16384 ? '' : tail;
    }

    final out = const Utf8Decoder(allowMalformed: true)
        .bind(process.stdout)
        .listen((chunk) => output(0, chunk), onError: (Object _) {});
    final err = const Utf8Decoder(allowMalformed: true)
        .bind(process.stderr)
        .listen((chunk) => output(1, chunk), onError: (Object _) {});
    try {
      final url = await Future.any<Uri?>([
        link.future,
        process.exitCode.then((_) => agyRemoteOAuthLink(tails.join('\n'))),
        stop.future.then((_) => null),
      ]).timeout(wait);
      if (cancelled) return;
      if (url == null) {
        if (await process.exitCode.timeout(wait) == 0) return;
        throw const AgyUnavailable(
          'Antigravity could not start Google sign-in',
        );
      }
      final value = await Future.any<String?>([
        authorize(url),
        stop.future.then((_) => null),
        process.exitCode.then((_) => null),
      ]).timeout(const Duration(minutes: 9));
      if (cancelled) return;
      if (value == null) throw const AgyUnavailable('Google sign-in ended');
      final code = value.trim();
      if (code.isEmpty ||
          code.length > 4096 ||
          code.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const AgyUnavailable('Invalid Google authorization code');
      }
      process.write(utf8.encode('$code\n'));
      final exit = await Future.any<int>([
        process.exitCode,
        stop.future.then((_) => RemoteProcess.lostExitCode),
      ]).timeout(wait);
      if (exit != 0 && !cancelled) {
        throw const AgyUnavailable('Google sign-in did not complete');
      }
    } finally {
      unawaited(_stop(process));
      await out.cancel();
      await err.cancel();
    }
  }

  @override
  Future<void> signIn({Future<void>? cancel}) async =>
      throw const AgyUnavailable('Use the remote Google sign-in dialog');

  @override
  Future<void> signOut() async =>
      throw const AgyUnavailable('Manage sign-out on the remote host');
}

/// No user or server-provided text is executed. URL and digest are
/// independently validated before being passed as positional arguments.
const remoteAgyInstallScript = r'''
set -eu
umask 077
test -n "$HOME"
mkdir -p -- "$HOME/.local/bin"
dest="$HOME/.local/bin/agy"
[ ! -e "$dest" ] && [ ! -L "$dest" ] || exit 0
tmp=$(mktemp -d "$HOME/.local/bin/.agy-install.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
curl -fsS --proto '=https' --connect-timeout 15 --max-time 300 -o "$tmp/archive" "$1"
printf '%s  %s\n' "$2" "$tmp/archive" | sha512sum -c --status
tar -xOzf "$tmp/archive" antigravity > "$tmp/agy"
[ -s "$tmp/agy" ]
chmod 700 "$tmp/agy"
ln -T -- "$tmp/agy" "$dest"
''';

/// The only URL the remote sign-in output can offer to open on the client.
Uri? agyRemoteOAuthLink(String output) {
  for (final match in RegExp(r'https://[^\s<>"]+').allMatches(output)) {
    final uri = Uri.tryParse(match.group(0)!);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'accounts.google.com' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        uri.path.startsWith('/o/oauth2/') &&
        uri.hasQuery) {
      return uri;
    }
  }
  return null;
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
