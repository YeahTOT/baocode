@TestOn('windows')
@Tags(['wsl-e2e'])
library;

import 'dart:io';

import 'package:baocode/kernel/acp/acp_connection.dart';
import 'package:baocode/kernel/antigravity/agy_remote_runtime.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final distro = Platform.environment['BAOCODE_AGY_WSL_FIXTURE'];
  test(
    'AGY runs in the selected WSL distribution and project',
    () async {
      final previous = SshHosts.instance;
      final hosts = SshHosts.instance = SshHosts();
      addTearDown(() async {
        await hosts.closeAll();
        SshHosts.instance = previous;
      });
      final host = 'wsl+$distro';
      final client = await HttpOverrides.runWithHttpOverrides(
        () => hosts[host].ready,
        _PublishedDaemonHttpOverrides(),
      );
      final home = client.hello!.home;
      final fixture = '$home/.local/bin/agy';
      final project = '$home/agy-wsl-fixture';
      expect(
        await client.stat(fixture),
        isNull,
        reason: 'Run only in a disposable WSL distribution',
      );
      final setup = await client.run('/bin/sh', [
        '-c',
        r'''umask 077; mkdir -p -- "$1" "$2" && (set -C; cat > "$3") && chmod 700 "$3"''',
        'setup',
        '$home/.local/bin',
        project,
        fixture,
      ], stdin: _agent);
      expect(setup.exitCode, 0, reason: setup.stderr);
      addTearDown(() async {
        await client.run('rm', ['--', fixture]);
      });
      final runtime = RemoteAgyRuntime(host);
      expect(await runtime.version(), '1.5.14');
      expect((await runtime.models()).single.id, 'fixture-gemini');
      final acp = AcpConnection(
        await runtime.start(RemoteLocation.of(host, project)),
        onRequest: (_, _) async => null,
        onNotification: (_, _) {},
      );
      addTearDown(acp.close);
      final result = await acp.request('initialize');
      expect(result['cwd'], project);
    },
    skip: distro == null
        ? 'BAOCODE_AGY_WSL_FIXTURE must name a disposable Windows CI distro'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

const _agent = r'''#!/bin/sh
case "$1" in
  --version) printf '%s\n' 'agy 1.5.14';;
  models) printf 'fixture-gemini\tFixture Gemini\n';;
  acp)
    IFS= read -r hello
    printf '{"jsonrpc":"2.0","id":1,"result":{"cwd":"%s"}}\n' "$PWD"
    while IFS= read -r line; do :; done;;
  *) exit 1;;
esac
''';

class _PublishedDaemonHttpOverrides extends HttpOverrides {}
