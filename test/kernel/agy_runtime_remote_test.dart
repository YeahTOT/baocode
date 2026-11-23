import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/kernel/antigravity/agy_runtime.dart';
import 'package:baocode/kernel/antigravity/agy_runtime_remote.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/remote_harness.dart';

void main() {
  test('the resolver separates SSH hosts and preserves the local runtime', () {
    expect(agyRuntimeFor('/local'), same(AgyRuntime.local));
    expect(agyRuntimeFor(null), same(AgyRuntime.local));
    expect(
      agyRuntimeFor('ssh://user@first:2200/a'),
      same(agyRuntimeFor('ssh://user@first:2200/b')),
    );
    expect(
      agyRuntimeFor('ssh://user@first:2200/a'),
      isNot(same(agyRuntimeFor('ssh://user@second:2200/a'))),
    );
  });

  test(
    'ACP history paginates and decodes paths using a disposable reader',
    () async {
      final fixture = _RemoteFixture();
      addTearDown(fixture.close);
      final runtime = fixture.runtime;
      final sessions = await runtime.sessions();
      expect(sessions.map((s) => (s.id, s.cwd)), [
        ('original', '/home/ssh/work tree'),
        ('older', '/home/ssh'),
      ]);
      expect(runtime.lastSessions, sessions);
      expect(fixture.methods, ['initialize', 'session/list', 'session/list']);
      expect(fixture.starts.single['arguments'], [
        'acp',
        '--disable-telemetry',
      ]);
      expect(fixture.starts.single['cwd'], '/home/ssh');
      await until(() => fixture.kills.length == 1);
      expect(fixture.forceKills, isEmpty);
    },
  );

  test('process shutdown escalates only when SIGTERM is ignored', () async {
    final fixture = _RemoteFixture(ignoresTerminate: true);
    addTearDown(fixture.close);
    final transport = await fixture.runtime.start('/home/ssh/work');
    transport.close();
    expect(
      (await transport.exited.timeout(const Duration(seconds: 8))).code,
      137,
    );
    expect(fixture.kills, [1, 1]);
    expect(fixture.forceKills, [1]);
  });

  test(
    'replay uses the remote path and only emits the requested session',
    () async {
      final fixture = _RemoteFixture();
      addTearDown(fixture.close);
      final updates = <Map<String, Object?>>[];
      final result = await fixture.runtime.replay(
        'original',
        'ssh://work-server/home/ssh/work tree',
        updates.add,
      );
      expect(result, {'configOptions': []});
      expect(updates, [
        {'sessionUpdate': 'user_message_chunk'},
      ]);
      expect(fixture.starts.single['cwd'], '/home/ssh/work tree');
      expect(fixture.lastCwd, '/home/ssh/work tree');
      await until(() => fixture.kills.length == 1);
    },
  );

  test(
    'refuses non-Linux hosts and paths from another host before launch',
    () async {
      final fixture = _RemoteFixture(os: 'darwin');
      addTearDown(fixture.close);
      await expectLater(
        fixture.runtime.start('/work'),
        throwsA(isA<AgyUnavailable>()),
      );
      await expectLater(
        fixture.runtime.start('ssh://other/work'),
        throwsA(isA<AgyUnavailable>()),
      );
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'missing CLI points to the official setup without a local fallback',
    () async {
      final fixture = _RemoteFixture(installed: false);
      addTearDown(fixture.close);
      expect(await fixture.runtime.locate(), isNull);
      await expectLater(
        fixture.runtime.install(),
        throwsA(
          isA<AgyUnavailable>().having(
            (e) => '${e.message} ${e.detail}',
            'same-user setup',
            allOf(
              contains('work-server'),
              contains('https://antigravity.google/'),
            ),
          ),
        ),
      );
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'installs from the signed-out official feed on the same SSH host',
    () async {
      final fixture = _RemoteFixture(
        installed: false,
        manifest: {'url': _artifactUrl, 'sha512': _checksum},
      );
      addTearDown(fixture.close);
      final progress = <double>[];
      await fixture.runtime.install(onProgress: progress.add);
      final download = fixture.installations.single;
      expect(download, containsAllInOrder([_artifactUrl, _checksum]));
      expect(progress.last, 1);
      expect(await fixture.runtime.locate(), '/home/ssh/.local/bin/agy');
    },
  );

  test('accepts the official Linux ARM64 artifact directory', () async {
    final fixture = _RemoteFixture(
      arch: 'arm64',
      installed: false,
      manifest: {'url': _armArtifactUrl, 'sha512': _checksum},
    );
    addTearDown(fixture.close);
    await fixture.runtime.install();
    expect(fixture.installations.single, contains(_armArtifactUrl));
  });

  test('rejects a nonofficial artifact before running the installer', () async {
    final fixture = _RemoteFixture(
      installed: false,
      manifest: {
        'url': 'https://unrelated.test/artifact.tar.gz',
        'sha512': _checksum,
      },
    );
    addTearDown(fixture.close);
    await expectLater(
      fixture.runtime.install(),
      throwsA(isA<AgyUnavailable>()),
    );
    expect(fixture.installations, isEmpty);
  });

  test(
    'headless login sends one code to the host process and returns no tokens',
    () async {
      final fixture = _RemoteFixture();
      addTearDown(fixture.close);
      final links = <Uri>[];
      await fixture.runtime.login(
        link: links.add,
        code: () async => ' one-time-code ',
      );
      expect(links.single.host, 'accounts.google.com');
      expect(fixture.loginInput, 'one-time-code\n');
      expect(fixture.starts.single['arguments'], ['acp', '--login']);
      expect(await fixture.runtime.credentials(), isNull);
      expect(await fixture.runtime.quota(), isNull);
    },
  );

  test('remote inbox returns task status without following links or copying output', () async {
    final home = await Directory.systemTemp.createTemp('agy-inbox-');
    addTearDown(() => home.delete(recursive: true));
    final fixture = _RemoteFixture(inboxHome: home.path);
    addTearDown(fixture.close);
    const id = '12345678-12ab-34ab-56ab-1234567890ab';
    final dir = Directory(
      '${home.path}/.gemini/antigravity-cli/brain/$id/.system_generated/messages',
    )..createSync(recursive: true);
    File('${dir.path}/1.json').writeAsStringSync(
      jsonEncode({
        'content': 'Task id "$id/task-1" finished with result:\nprivate output',
        'access_token': 'do not send',
      }),
    );
    final outside = File('${home.path}/outside.json')
      ..writeAsStringSync(
        jsonEncode({'content': 'Task id "$id/task-2" finished'}),
      );
    Link('${dir.path}/2.json').createSync(outside.path);
    expect(await fixture.runtime.records(id).messages(), [
      {'content': 'Task id "$id/task-1" finished'},
    ]);
    expect(await fixture.runtime.records('../invalid').messages(), isEmpty);
    expect(fixture.inboxReads, 1);
  }, skip: !Platform.isLinux);

  test(
    'the remote MCP bridge retains bearer auth and closes both ends',
    () async {
      final harness = await RemoteHarness.start();
      addTearDown(harness.close);
      final runtime = RemoteAgyRuntime(
        'work-server',
        ready: () async => harness.client,
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final endpoint = await runtime.serveTools(
        (message) async => {'echo': message['method']},
      );
      final uri = endpoint.url;
      expect(uri.host, '127.0.0.1');
      expect(harness.client.forwardedPorts, contains(uri.port));
      final rejected = await (await http.postUrl(uri)).close();
      expect(rejected.statusCode, 404);
      await rejected.drain<void>();
      final request = await http.postUrl(uri);
      endpoint.headers.forEach(request.headers.set);
      request.write('{"id":1,"method":"test"}');
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(jsonDecode(await utf8.decodeStream(response)), {'echo': 'test'});
      await endpoint.close();
      expect(harness.client.forwardedPorts, isEmpty);
    },
    skip: !Platform.isLinux,
  );
}

const _artifactUrl =
    'https://storage.googleapis.com/antigravity-public/'
    'antigravity-cli/1.5.14-5302690847260672/linux-x64/cli_linux_x64.tar.gz';
const _armArtifactUrl =
    'https://storage.googleapis.com/antigravity-public/'
    'antigravity-cli/1.5.14-5302690847260672/linux-arm/cli_linux_arm64.tar.gz';
final _checksum = 'ab' * 64;

class _RemoteFixture {
  _RemoteFixture({
    String os = 'linux',
    String arch = 'x64',
    bool installed = true,
    Map<String, Object?>? manifest,
    String? inboxHome,
    bool ignoresTerminate = false,
  }) {
    server.handlers[RemoteProtocol.processRun] = (params, _) async {
      final args = params as Map;
      final List<dynamic> arguments = args['arguments'] as List;
      if (args['executable'] == 'python3') {
        inboxReads++;
        final result = await Process.run('python3', arguments.cast<String>());
        return {'stdout': result.stdout, 'exitCode': result.exitCode};
      }
      if (args['executable'] == 'curl') {
        return {
          'stdout': manifest == null ? '' : jsonEncode(manifest),
          'exitCode': manifest == null ? 1 : 0,
        };
      }
      if (arguments.contains('baocode-agy-install')) {
        installations.add(arguments);
        installed = arguments.contains(_checksum);
        return {'exitCode': installed ? 0 : 1};
      }
      return {
        'stdout': installed ? '/home/ssh/.local/bin/agy\n' : '',
        'exitCode': installed ? 0 : 1,
      };
    };
    server.handlers[RemoteProtocol.processStart] = (params, _) {
      final args = (params as Map).cast<String, Object?>();
      starts.add(args);
      final id = starts.length;
      if ((args['arguments'] as List).contains('--login')) {
        _out(
          id,
          'Open https://accounts.google.com/o/oauth2/auth?state=test\n',
          fd: 2,
        );
      }
      return {'id': id};
    };
    server.handlers[RemoteProtocol.processWrite] = (params, _) {
      final id = (params as Map)['id'] as int;
      final line = utf8.decode(decodeBytes(params['data']));
      if ((starts[id - 1]['arguments'] as List).contains('--login')) {
        loginInput = line;
        _exit(id, 0);
        return null;
      }
      final call = jsonDecode(line) as Map;
      final method = call['method'] as String;
      methods.add(method);
      final args = call['params'] as Map;
      final Object result;
      switch (method) {
        case 'initialize':
          result = {'protocolVersion': 1};
        case 'session/list':
          result = args['cursor'] == null
              ? {
                  'sessions': [
                    {'sessionId': 'original', 'cwd': '/home/ssh/work%20tree'},
                  ],
                  'nextCursor': 'next',
                }
              : {
                  'sessions': [
                    {'sessionId': 'older', 'cwd': '/home/ssh'},
                  ],
                };
        case 'session/load':
          lastCwd = args['cwd'] as String;
          for (final session in ['unrelated', 'original']) {
            _message(id, {
              'method': 'session/update',
              'params': {
                'sessionId': session,
                'update': {'sessionUpdate': 'user_message_chunk'},
              },
            });
          }
          result = {'configOptions': []};
        default:
          result = {};
      }
      _message(id, {'id': call['id'], 'result': result});
      return null;
    };
    server.handlers[RemoteProtocol.processKill] = (params, _) {
      final args = params as Map;
      final id = args['id'] as int;
      kills.add(id);
      final force = args['force'] == true;
      if (force) forceKills.add(id);
      if (force || !ignoresTerminate) _exit(id, force ? 137 : 143);
      return null;
    };
    server.handlers[RemoteProtocol.processCloseStdin] = (_, _) => null;
    client.hello = RemoteHello(
      protocol: RemoteProtocol.version,
      version: 'test',
      platform: RemotePlatform(os, arch),
      pid: 1,
      home: inboxHome ?? '/home/ssh',
      dataDir: '/home/ssh/.baocode-server/data',
    );
    runtime = RemoteAgyRuntime('work-server', ready: () async => client);
  }

  final toServer = StreamController<String>();
  final toClient = StreamController<String>();
  late final server = RpcPeer(toServer.stream, toClient.add);
  late final client = RemoteClient(RpcPeer(toClient.stream, toServer.add));
  late final RemoteAgyRuntime runtime;
  final starts = <Map<String, Object?>>[];
  final installations = <List<Object?>>[];
  final methods = <String>[];
  final kills = <int>[];
  final forceKills = <int>[];
  int inboxReads = 0;
  String? lastCwd;
  String? loginInput;

  void _message(int id, Map<String, Object?> message) =>
      _out(id, '${jsonEncode({'jsonrpc': '2.0', ...message})}\n');

  void _out(int id, String text, {int fd = 1}) => server.notify(
    RemoteProtocol.processOutput,
    {'id': id, 'fd': fd, 'data': encodeBytes(utf8.encode(text))},
  );

  void _exit(int id, int code) =>
      server.notify(RemoteProtocol.processExit, {'id': id, 'code': code});

  Future<void> close() async {
    await runtime.stopAll();
    await toServer.close();
    await toClient.close();
  }
}
