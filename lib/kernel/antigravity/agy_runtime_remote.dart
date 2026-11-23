import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';
import 'package:path/path.dart' as p;

import '../../remote/remote_location.dart';
import '../../remote/ssh_host.dart';
import '../acp/acp_connection.dart';
import '../acp/mcp_endpoint.dart';
import '../acp/mcp_http_server.dart';
import '../agent_kernel.dart' show SessionRecord;
import '../kernel_types.dart' show RateLimitWindow;
import 'agy_agent_path.dart';
import 'agy_runtime.dart';
import 'antigravity_translator.dart';

final _runtimes = Expando<Map<String, RemoteAgyRuntime>>();

/// Uses the same runtime for each project on an SSH host. Remote locations,
/// even invalid ones, never fall back to the local Antigravity account.
AgyRuntime agyRuntimeFor(String? cwd) {
  final host = cwd == null ? null : RemoteLocation.hostOf(cwd);
  if (host == null) return AgyRuntime.local;
  final hosts = SshHosts.instance;
  final runtimes = _runtimes[hosts] ??= {};
  return runtimes.putIfAbsent(
    host,
    () => RemoteAgyRuntime(host, ready: () => hosts[host].ready),
  );
}

/// Antigravity running as the SSH account on a Linux host. Authentication
/// and the canonical history stay there; the app speaks ACP over the
/// existing resumable BaoCode connection.
class RemoteAgyRuntime implements AgyRuntime {
  RemoteAgyRuntime(this.host, {Future<RemoteClient> Function()? ready})
    : _ready = ready ?? (() => SshHosts.instance[host].ready);

  final String host;
  final Future<RemoteClient> Function() _ready;

  static const setupUrl =
      'https://antigravity.google/docs/getting-started?tab=cli';
  static const _wait = Duration(seconds: 20);
  static const _loginWait = Duration(minutes: 10);
  static const _hello = {
    'protocolVersion': 1,
    'clientCapabilities': {
      'fs': {'readTextFile': false, 'writeTextFile': false},
      'terminal': false,
    },
    'clientInfo': {'name': 'baocode', 'version': '1'},
  };

  final _processes = <RemoteProcess>{};
  final _bridges = <_RemoteMcpEndpoint>{};
  final _timings = <String, List<Map<String, Object?>>>{};
  List<SessionRecord>? _lastSessions;

  Future<RemoteClient> _client() async {
    if (host.isEmpty || RegExp(r'[\s\x00-\x1f]').hasMatch(host)) {
      throw const AgyUnavailable('Invalid Antigravity SSH host');
    }
    final client = await _ready();
    if (client.hello?.platform.os != 'linux') {
      throw AgyUnavailable(
        'Antigravity over SSH requires Linux ($host)',
        unsupportedHost: true,
      );
    }
    return client;
  }

  String _cwd(String location) {
    final target = RemoteLocation.hostOf(location);
    final path = target == null ? location : RemoteLocation.pathOf(location);
    if ((target != null && target != host) ||
        !p.posix.isAbsolute(path) ||
        path.contains('\x00')) {
      throw AgyUnavailable('Invalid Antigravity project path on $host');
    }
    return p.posix.normalize(path);
  }

  static String? _home(RemoteClient client) {
    final home = client.hello?.home;
    return home != null && p.posix.isAbsolute(home) ? home : null;
  }

  static Future<String?> _locate(RemoteClient client) async {
    final found = await client.run('sh', [
      '-c',
      r'''
candidate=$(command -v agy 2>/dev/null)
case "$candidate" in
  /*) if [ -f "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; exit 0; fi ;;
esac
candidate="$HOME/.local/bin/agy"
if [ -n "$HOME" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
  printf '%s\n' "$candidate"; exit 0
fi
exit 1
''',
    ], cwd: _home(client));
    final path = found.stdout.trim();
    return found.exitCode == 0 &&
            !path.contains(RegExp(r'[\r\n\x00]')) &&
            p.posix.isAbsolute(path)
        ? path
        : null;
  }

  @override
  Future<String?> locate() async => _locate(await _client());

  AgyUnavailable _missing() => AgyUnavailable(
    'Antigravity is not installed on $host',
    notInstalled: true,
    detail:
        'Install agy on $host with the same SSH account using Google’s '
        'Linux instructions: $setupUrl. Then retry.',
  );

  Future<RemoteProcess> _launch(
    RemoteClient client,
    List<String> arguments, {
    String? cwd,
    String? executable,
  }) async {
    final found = executable ?? await _locate(client);
    if (found == null) throw _missing();
    final RemoteProcess process;
    final starting = client.start(found, arguments, cwd: cwd ?? _home(client));
    try {
      process = await starting.timeout(_wait);
    } on TimeoutException {
      // The request may still complete when a suspended SSH link returns.
      unawaited(
        starting.then<void>(
          (process) => _terminate(process),
          onError: (Object _) {},
        ),
      );
      throw AgyUnavailable('Antigravity timed out starting on $host');
    } on RemoteException {
      throw AgyUnavailable('Antigravity could not start on $host');
    }
    _processes.add(process);
    unawaited(process.exitCode.then((_) => _processes.remove(process)));
    return process;
  }

  static const _acp = ['acp', '--disable-telemetry'];

  @override
  Future<AcpTransport> start(String cwd) async {
    final path = _cwd(cwd);
    return _RemoteAcpTransport(await _launch(await _client(), _acp, cwd: path));
  }

  /// A spare process would inherit another remote project's working dir.
  @override
  void warm() {}

  @override
  Future<void> install({void Function(double progress)? onProgress}) async {
    final client = await _client();
    if (await _locate(client) != null) {
      onProgress?.call(1);
      return;
    }
    final arch = switch (client.hello?.platform.arch) {
      'x64' => 'amd64',
      'arm64' => 'arm64',
      _ => null,
    };
    final home = _home(client);
    if (arch == null || home == null || client.hello?.platform.libc == 'musl') {
      throw _missing();
    }
    try {
      final manifest = await client.run('curl', [
        '--disable',
        '--fail',
        '--silent',
        '--proto',
        '=https',
        '--max-time',
        '20',
        '--max-filesize',
        '65536',
        '$agyUpdateFeed/linux_$arch.json',
      ], cwd: home);
      if (manifest.exitCode != 0) throw _missing();
      final json = jsonDecode(manifest.stdout);
      if (json case {'url': final String url, 'sha512': final String sha}
          when _officialArtifact(url, arch) &&
              RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(sha)) {
        onProgress?.call(.1);
        final installed = await client.run('sh', [
          '-c',
          _installScript,
          'baocode-agy-install',
          url,
          sha.toLowerCase(),
        ], cwd: home);
        if (installed.exitCode != 0 || await _locate(client) == null) {
          throw _missing();
        }
        onProgress?.call(1);
      } else {
        throw _missing();
      }
    } on RemoteException {
      throw _missing();
    } on FormatException {
      throw _missing();
    }
  }

  static bool _officialArtifact(String url, String arch) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'storage.googleapis.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final platform = arch == 'amd64' ? 'x64' : arch;
    // The current Google ARM64 manifests use a linux-arm directory.
    final directories = arch == 'arm64'
        ? {'linux-arm', 'linux-arm64'}
        : {'linux-x64'};
    if (uri.pathSegments
        case [
          'antigravity-public',
          'antigravity-cli',
          final build,
          final target,
          final archive,
        ]
        when RegExp(r'^[0-9][0-9a-zA-Z.-]*$').hasMatch(build) &&
            directories.contains(target) &&
            archive == 'cli_linux_$platform.tar.gz') {
      return true;
    }
    return false;
  }

  // Extract only the verified executable to stdout, never archive paths.
  // Stage on the same filesystem and publish with a no-clobber hard link.
  static const _installScript = r'''
set -eu
umask 077
test -n "$HOME"
dir="$HOME/.local/bin"
mkdir -p -- "$dir"
tmp=$(mktemp -d -- "$dir/.baocode-agy.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
curl --disable --fail --silent --proto '=https' --max-time 300 \
  --max-filesize 536870912 --output "$tmp/artifact" -- "$1"
(cd -- "$tmp" && printf '%s  artifact\n' "$2" | sha512sum --check --status)
tar -xOzf "$tmp/artifact" -- antigravity > "$tmp/agy"
test -s "$tmp/agy"
chmod 700 -- "$tmp/agy"
ln -T -- "$tmp/agy" "$dir/agy"
''';

  Future<T> _read<T>(
    Future<T> Function(AcpConnection reader) read, {
    required RemoteClient client,
    String? cwd,
    String? executable,
    void Function(String, Map<String, Object?>)? notify,
  }) async {
    final transport = _RemoteAcpTransport(
      await _launch(client, _acp, cwd: cwd, executable: executable),
    );
    final reader = AcpConnection(
      transport,
      onRequest: (method, _) async =>
          throw AcpError(-32601, 'Method not found: $method'),
      onNotification: notify ?? (_, _) {},
    );
    try {
      await reader.request('initialize', _hello).timeout(_wait);
      return await read(reader);
    } finally {
      reader.close();
      await reader.dispose();
    }
  }

  @override
  Future<Map<String, Object?>> replay(
    String sessionId,
    String cwd,
    void Function(Map<String, Object?> update) onUpdate,
  ) async {
    final path = _cwd(cwd);
    return _read(
      (reader) => reader
          .request('session/load', {
            'sessionId': sessionId,
            'cwd': path,
            'mcpServers': const [],
          })
          .timeout(_wait),
      client: await _client(),
      cwd: path,
      notify: (method, params) {
        if (method != 'session/update' || params['sessionId'] != sessionId) {
          return;
        }
        if (params['update'] case final Map<String, Object?> update) {
          onUpdate(update);
        }
      },
    );
  }

  @override
  Future<List<SessionRecord>> sessions() async {
    final client = await _client();
    final executable = await _locate(client);
    if (executable == null) {
      _lastSessions = const [];
      return const [];
    }
    final records = await _read<List<SessionRecord>>(
      (reader) async {
        final records = <String, SessionRecord>{};
        final cursors = <String>{};
        String? cursor;
        for (var page = 0; page < 100 && records.length < 10000; page++) {
          final result = await reader
              .request('session/list', {'cursor': ?cursor})
              .timeout(_wait);
          for (final entry in result['sessions'] as List? ?? const []) {
            if (entry
                case {'sessionId': final String id, 'cwd': final String cwd}
                when id.isNotEmpty) {
              final path = agyPath(cwd);
              if (!p.posix.isAbsolute(path) || path.contains('\x00')) continue;
              records[id] = SessionRecord(
                id: id,
                title: AntigravityTranslator.withoutReminders(
                  entry['title'] is String ? entry['title'] as String : '',
                ),
                cwd: p.posix.normalize(path),
                updatedAt:
                    (DateTime.tryParse('${entry['updatedAt']}') ??
                            DateTime.fromMillisecondsSinceEpoch(0))
                        .toLocal(),
              );
              if (records.length >= 10000) break;
            }
          }
          final next = result['nextCursor'];
          if (next is! String || next.isEmpty || !cursors.add(next)) break;
          cursor = next;
        }
        return List.unmodifiable(records.values);
      },
      client: client,
      executable: executable,
    );
    _lastSessions = records;
    return records;
  }

  @override
  List<SessionRecord>? get lastSessions => _lastSessions;

  @override
  Future<void> delete(String sessionId) async {
    if (sessionId.isEmpty || sessionId.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw AgyUnavailable('Invalid Antigravity conversation ID on $host');
    }
    try {
      await _read(
        (reader) => reader
            .request('session/delete', {'sessionId': sessionId})
            .timeout(_wait),
        client: await _client(),
      );
    } on AcpError catch (error) {
      if (error.code != -32601) rethrow;
      throw AgyUnavailable(
        'Antigravity on $host does not support deleting through BaoCode',
        detail: 'Delete the conversation in agy on the SSH host instead.',
      );
    }
    _lastSessions = _lastSessions
        ?.where((record) => record.id != sessionId)
        .toList(growable: false);
    _timings.remove(sessionId);
  }

  @override
  Future<void> login({
    required void Function(Uri link) link,
    required Future<String?> Function() code,
  }) async {
    final process = await _launch(await _client(), ['acp', '--login']);
    final found = Completer<Uri?>();
    var ended = false;
    void read(String line) {
      if (found.isCompleted) return;
      for (final match in RegExp(r'https://[^\s<>"\x27]+').allMatches(line)) {
        final uri = Uri.tryParse(match.group(0)!);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host != 'accounts.google.com' ||
            uri.userInfo.isNotEmpty ||
            uri.port != 443) {
          continue;
        }
        found.complete(uri);
        return;
      }
    }

    final stdout = _lines(process.stdout).listen(read);
    final stderr = _lines(process.stderr).listen(read);
    final exit = process.exitCode.then((status) {
      ended = true;
      if (!found.isCompleted) found.complete(null);
      return status;
    });
    final failed = AgyUnavailable(
      'Signing in to Antigravity on $host did not finish',
      detail:
          'Run agy acp --login on the SSH host to see Google’s sign-in prompt.',
    );
    try {
      final uri = await found.future.timeout(_loginWait);
      if (uri == null && await exit == 0) return;
      if (uri == null || ended) throw failed;
      link(uri);
      final answer = await Future.any<String?>([code(), exit.then((_) => null)])
          .timeout(_loginWait);
      final trimmed = answer?.trim() ?? '';
      if (ended || trimmed.isEmpty || trimmed.contains(RegExp(r'[\r\n\x00]'))) {
        throw failed;
      }
      process.write(utf8.encode('$trimmed\n'));
      if (await exit.timeout(_loginWait) != 0) throw failed;
    } on TimeoutException {
      throw failed;
    } finally {
      if (!ended) await _terminate(process);
      unawaited(stdout.cancel());
      unawaited(stderr.cancel());
    }
  }

  @override
  Future<McpEndpoint> serveTools(McpHandler handle) async {
    final client = await _client();
    final local = await McpHttpServer.start(handle);
    try {
      final forward = await client.forward(local.url.port);
      final endpoint = _RemoteMcpEndpoint(local, forward, _bridges.remove);
      _bridges.add(endpoint);
      unawaited(
        client.peer.done
            .then((_) => endpoint.close())
            .catchError((Object _) {}),
      );
      return endpoint;
    } on Object {
      await local.close();
      rethrow;
    }
  }

  @override
  Future<void> stopAll() async {
    for (final process in [..._processes]) {
      process.kill();
    }
    await Future.wait([
      for (final endpoint in [..._bridges]) endpoint.close(),
    ]);
  }

  // No remote auth stores, filesystem fallback, or local account lookup.
  // ACP usage updates and per-turn timings are still available in chat.
  @override
  Future<AgyCredentials?> credentials() async => null;

  @override
  Future<List<RateLimitWindow>?> quota() async => null;

  @override
  Future<List<AgyMcpServer>> mcpServers() async => const [];

  @override
  Future<void> setMcpServerEnabled(String name, bool enabled) async {
    throw AgyUnavailable('Manage Antigravity MCP servers on $host.');
  }

  @override
  AgyRecords records(String sessionId) => _RemoteAgyRecords(_client, sessionId);

  @override
  String? fileText(String path) => null;

  @override
  Map<String, Object?>? kept;

  @override
  List<Map<String, Object?>> turnsTimed(String sessionId) =>
      List.unmodifiable(_timings[sessionId] ?? const []);

  @override
  void timeTurn(String sessionId, Map<String, Object?> turn) {
    final turns = _timings.putIfAbsent(sessionId, () => []);
    turns.add(Map.unmodifiable(turn));
    if (turns.length > 1000) turns.removeAt(0);
  }
}

/// Reads only agy's completion notices. Never exports task output, arbitrary
/// paths or credentials; Python is optional on the remote host.
class _RemoteAgyRecords implements AgyRecords {
  const _RemoteAgyRecords(this._client, this._session);

  final Future<RemoteClient> Function() _client;
  final String _session;

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
  );

  @override
  Future<List<Map<String, Object?>>> messages() async {
    if (!_uuid.hasMatch(_session)) return const [];
    final client = await _client();
    final home = RemoteAgyRuntime._home(client);
    if (home == null) return const [];
    final cancel = Completer<void>();
    try {
      final result = await client
          .run(
            'python3',
            ['-I', '-S', '-c', _notices, home, _session],
            cwd: home,
            cancel: cancel.future,
          )
          .timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const [];
      return [
        for (final line in const LineSplitter().convert(result.stdout))
          if (line.startsWith('Task id ')) {'content': line},
      ];
    } on RemoteException {
      return const [];
    } on TimeoutException {
      cancel.complete();
      return const [];
    }
  }

  // Only fixed directories under the account home. Walk with directory
  // descriptors and O_NOFOLLOW so renames cannot redirect the reader.
  // Reject nonregular files and hard links before reading any bytes.
  static const _notices = r'''
import itertools, json, os, re, stat, sys

home, session = sys.argv[1:]
dirs = ('.gemini', 'antigravity-cli', 'brain', session, '.system_generated', 'messages')
flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY
try:
    folder = os.open(home, flags)
    for part in dirs:
        child = os.open(part, flags, dir_fd=folder)
        os.close(folder)
        folder = child
except OSError:
    sys.exit(0)

task = re.compile(r'Task id "?(' + re.escape(session) +
                  r'/task-[0-9]+)"? (finished|failed|was cancelled|was killed)\b')
with os.scandir(folder) as listing:
    for entry in itertools.islice(listing, 256):
        name = entry.name
        if name == 'read.json' or not name.endswith('.json'):
            continue
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=folder)
            with os.fdopen(fd, 'rb') as file:
                meta = os.fstat(fd)
                if not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1 or meta.st_size > 65536:
                    continue
                message = json.loads(file.read(65537))
            content = message.get('content') if isinstance(message, dict) else None
            match = task.search(content) if isinstance(content, str) else None
            if match:
                task_id, status = match.groups()
                suffix = ' (exit code 1)' if re.search(r'exit code:?\s*[1-9]', content) else ''
                print(f'Task id "{task_id}" {status}{suffix}')
        except (OSError, ValueError, RecursionError):
            pass
os.close(folder)
''';

  @override
  String taskLog(String taskId) => '';
}

Stream<String> _lines(Stream<List<int>> input) => input
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());

final _terminations = Expando<Future<void>>();

/// End only the process we started. Escalate once after a bounded grace
/// period, even if the caller no longer waits for the process to exit.
Future<void> _terminate(RemoteProcess process) =>
    _terminations[process] ??= () async {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(force: true);
          return RemoteProcess.lostExitCode;
        },
      );
    }();

class _RemoteAcpTransport implements AcpTransport {
  _RemoteAcpTransport(this._process) {
    final stdout = _lines(_process.stdout).forEach(_line);
    // Remote stderr may contain auth/setup output. Do not retain or expose it.
    final stderr = _process.stderr.drain<void>();
    _exit = Future.wait<void>([stdout, stderr]).then((_) async {
      final code = await _process.exitCode;
      _closed = true;
      unawaited(_messages.close());
      return AcpExit(code);
    });
  }

  final RemoteProcess _process;
  final _messages = StreamController<Map<String, Object?>>();
  late final Future<AcpExit> _exit;
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<AcpExit> get exited => _exit;

  void _line(String line) {
    try {
      if (jsonDecode(line) case final Map<String, Object?> message) {
        _messages.add(message);
      }
    } on FormatException {
      // Not ACP; ignored instead of leaking arbitrary remote process output.
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (!_closed) _process.write(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_terminate(_process));
  }
}

class _RemoteMcpEndpoint implements McpEndpoint {
  _RemoteMcpEndpoint(this._local, this._forward, this._remove);

  final McpEndpoint _local;
  final RemoteForward _forward;
  final void Function(_RemoteMcpEndpoint) _remove;
  Future<void>? _closing;

  @override
  Uri get url => _local.url.replace(port: _forward.remotePort);

  @override
  Map<String, String> get headers => _local.headers;

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _remove(this);
    await Future.wait([
      _local.close(),
      _forward.close().timeout(RemoteAgyRuntime._wait, onTimeout: () {}),
    ]);
  }
}
