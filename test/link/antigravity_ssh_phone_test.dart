import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/kernel/acp/acp_connection.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/agy_runtime.dart';
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:baocode/kernel/antigravity/antigravity_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'workspace_bridge_test.dart' show peers;

void main() {
  const alphaProject = 'ssh://alpha/work/app';
  const betaProject = 'ssh://beta/work/app';
  const alphaSession = 'agy-ssh:alpha:shared';
  const betaSession = 'agy-ssh:beta:shared';
  late _Runtime alpha;
  late _Runtime beta;
  late LinkPeer phone;

  Future<void> setup({bool twoKernels = false}) async {
    final local = _Runtime('local');
    alpha = _Runtime('alpha');
    beta = _Runtime('beta');
    _Runtime runtimeFor(String? cwd) => switch (cwd) {
      alphaProject => alpha,
      betaProject => beta,
      null => local,
      _ => throw StateError('Unexpected CWD $cwd'),
    };
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'antigravity',
      label: 'Antigravity',
      description: '',
      icon: Icons.auto_awesome,
      catalog: AntigravityCatalog(runtimeFor: runtimeFor),
      create: (context) => AntigravityKernel(
        descriptor,
        context,
        runtime: runtimeFor(context.cwd),
      ),
    );
    late final KernelDescriptor other;
    other = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      description: '',
      icon: Icons.auto_awesome,
      create: (context) => AntigravityKernel(other, context, runtime: local),
    );
    final workspace = Workspace(kernels: [if (twoKernels) other, descriptor]);
    final LinkPeer desktop;
    (phone, desktop) = await peers();
    final bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'PC', kind: 'pc', system: 'Linux'),
      reachHost: (_) async {},
      filesOf: (project) => (
        files: _Screenshots(switch (project.path) {
          alphaProject => [1, 2, 3],
          betaProject => [4, 5, 6],
          _ => throw StateError('Unexpected file host ${project.path}'),
        }),
        paths: p.posix,
      ),
    )..start();
    desktop.onRequest = bridge.handle;
    addTearDown(() async {
      bridge.dispose();
      workspace.dispose();
      await phone.close();
      await desktop.close();
    });
    await workspace.openFolder(alphaProject);
    await workspace.openFolder(betaProject);
    await pumpEventQueue();
  }

  test('the phone resumes identical agy IDs on their own hosts', () async {
    await setup();
    final state = LinkState.fromJson(
      (await phone.call(LinkMethods.state))! as Map<String, Object?>,
    );
    expect(
      state.sessions
          .where((session) => session.id.startsWith('agy-ssh:'))
          .map((session) => (session.project, session.id)),
      unorderedEquals([
        (alphaProject, alphaSession),
        (betaProject, betaSession),
      ]),
    );

    Future<String> open(String session) async {
      final result = LinkSessionUpdate.fromJson(
        (await phone.call(LinkMethods.open, {'session': session}))!
            as Map<String, Object?>,
      );
      expect(result.session, session);
      return result.items
          .map(ChatCodec.decode)
          .whereType<UserMessageItem>()
          .single
          .text;
    }

    // The first open starts asynchronous history replay. Ask again after
    // its notification, as a phone reopening the conversation would.
    await phone.call(LinkMethods.open, {'session': alphaSession});
    await phone.call(LinkMethods.open, {'session': betaSession});
    await pumpEventQueue();
    expect(await open(alphaSession), 'history on alpha');
    expect(await open(betaSession), 'history on beta');
    expect(alpha.replayed, [('shared', alphaProject)]);
    expect(beta.replayed, [('shared', betaProject)]);
  });

  test(
    'a phone project send passes its image to the right ACP process',
    () async {
      await setup();
      final result = await phone.call(LinkMethods.send, {
        'project': betaProject,
        'text': 'Look at this',
        'images': [
          {'type': 'image/jpeg', 'data': 'AQID'},
        ],
      });
      expect(result, {'session': startsWith('new-')});
      final prompt = await beta.prompt.future.timeout(
        const Duration(seconds: 5),
      );
      expect(alpha.startCwds, isEmpty);
      expect(beta.startCwds, [betaProject]);
      expect(beta.newCwds, ['/work/app']);
      expect(prompt, {
        'sessionId': 'new-on-host',
        'prompt': [
          {'type': 'text', 'text': 'Look at this\n[Image #1]'},
          {'type': 'image', 'mimeType': 'image/jpeg', 'data': 'AQID'},
        ],
      });
    },
  );

  test(
    'a phone can opt in to kernel choices and switch an SSH draft',
    () async {
      await setup(twoKernels: true);
      final draft =
          (await phone.call(LinkMethods.draft, {'project': betaProject}))!
              as Map<String, Object?>;
      final id = draft['session']! as String;
      expect(id, startsWith('new-'));
      Future<LinkSessionUpdate> open({bool includeKernel = false}) async =>
          LinkSessionUpdate.fromJson(
            (await phone.call(LinkMethods.open, {
                  'session': id,
                  if (includeKernel) 'kernelChoices': true,
                }))!
                as Map<String, Object?>,
          );
      expect(
        (await open()).choices.where((choice) => choice.kind == 'kernel'),
        isEmpty,
      );

      final shown = (await open(includeKernel: true)).choices
          .singleWhere((choice) => choice.kind == 'kernel');
      expect(shown.selected, 'claude-code');
      expect(shown.options.map((option) => option.id), contains('antigravity'));

      await phone.call(LinkMethods.choose, {
        'session': id,
        'kind': 'kernel',
        'option': 'antigravity',
      });
      final selected = (await open(includeKernel: true)).choices
          .singleWhere((choice) => choice.kind == 'kernel');
      expect(selected.selected, 'antigravity');
      await phone.call(LinkMethods.send, {'session': id, 'text': 'Hello'});
      final prompt = await beta.prompt.future.timeout(
        const Duration(seconds: 5),
      );
      expect(prompt['sessionId'], 'new-on-host');
      expect(alpha.startCwds, isEmpty);
    },
  );

  test('phone screenshot fetch uses the specified SSH project host', () async {
    await setup();
    Future<Object?> image(String project, String path) =>
        phone.call(LinkMethods.image, {'project': project, 'path': path});
    expect(await image(alphaProject, 'screenshot.png'), {
      'type': 'image/png',
      'data': 'AQID',
    });
    expect(await image(betaProject, '/work/app/screenshot.png'), {
      'type': 'image/png',
      'data': 'BAUG',
    });
  });
}

class _Screenshots implements IdeHostFiles {
  _Screenshots(this.bytes);
  final List<int> bytes;

  @override
  Future<Uint8List> readBytes(String path) async {
    if (path != '/work/app/screenshot.png') throw StateError('No file $path');
    return Uint8List.fromList(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Runtime implements AgyRuntime {
  _Runtime(this.host);
  final String host;
  final replayed = <(String, String)>[];
  final startCwds = <String>[];
  final newCwds = <String>[];
  final prompt = Completer<Map<String, Object?>>();
  @override
  Map<String, Object?>? kept;
  @override
  List<SessionRecord>? get lastSessions => null;

  @override
  Future<List<SessionRecord>> sessions() async => [
    if (host != 'local')
      SessionRecord(
        id: 'shared',
        cwd: '/work/app',
        title: 'on $host',
        updatedAt: DateTime.utc(2026),
      ),
  ];

  @override
  Future<Map<String, Object?>> replay(
    String sessionId,
    String cwd,
    void Function(Map<String, Object?> update) onUpdate,
  ) async {
    replayed.add((sessionId, cwd));
    onUpdate({
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': 'history on $host'},
    });
    return {};
  }

  @override
  Future<AcpTransport> start(String cwd) async {
    startCwds.add(cwd);
    return _AcpProcess((method, params) {
      switch (method) {
        case 'initialize':
          return {
            'agentCapabilities': {'loadSession': true},
          };
        case 'session/new':
          newCwds.add(params['cwd']! as String);
          return {'sessionId': 'new-on-host'};
        case 'session/prompt':
          prompt.complete(params);
          return {'stopReason': 'end_turn'};
        default:
          return <String, Object?>{};
      }
    });
  }

  @override
  Future<String?> locate() async => '/usr/bin/agy';
  @override
  void warm() {}
  @override
  Future<List<RateLimitWindow>?> quota() async => null;
  @override
  String? fileText(String path) => null;
  @override
  List<Map<String, Object?>> turnsTimed(String sessionId) => const [];
  @override
  void timeTurn(String sessionId, Map<String, Object?> turn) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AcpProcess implements AcpTransport {
  _AcpProcess(this.respond);
  final Map<String, Object?> Function(String, Map<String, Object?>) respond;
  final _messages = StreamController<Map<String, Object?>>();
  final _exited = Completer<AcpExit>();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<AcpExit> get exited => _exited.future;

  @override
  void write(Map<String, Object?> message) {
    final id = message['id'];
    if (id == null) return;
    final response = respond(
      message['method']! as String,
      (message['params']! as Map).cast<String, Object?>(),
    );
    // Serialize like the ACP pipe and the phone's requests.
    _messages.add(
      (jsonDecode(
        jsonEncode({'id': id, 'jsonrpc': '2.0', 'result': response}),
      ) as Map).cast<String, Object?>(),
    );
  }

  @override
  void close() {
    if (_exited.isCompleted) return;
    unawaited(_messages.close());
    _exited.complete(const AcpExit(0));
  }
}
