import 'dart:io';

import 'package:baocode/chat/composer/remote_agy_setup.dart';
import 'package:baocode/kernel/antigravity/agy_remote_runtime.dart';
import 'package:baocode/kernel/antigravity/agy_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote login accepts only the Google OAuth authorization origin', () {
    final actual = Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth?client_id=test&state=secret',
    );
    expect(agyRemoteOAuthLink('Open this URL: $actual\n'), actual);
    for (final bad in [
      'http://accounts.google.com/o/oauth2/v2/auth?x=y',
      'https://accounts.google.com.evil.example/o/oauth2/v2/auth?x=y',
      'https://evil.example/?x=accounts.google.com',
      'https://accounts.google.com:8443/o/oauth2/v2/auth?x=y',
    ]) {
      expect(agyRemoteOAuthLink(bad), isNull);
    }
  });

  testWidgets('click opens the setup dialog for just the chosen WSL target', (
    tester,
  ) async {
    final remote = _FakeRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showRemoteAgySetup(context, runtime: remote, install: true),
              child: const Text('Install remotely'),
            ),
          ),
        ),
      ),
    );
    expect(remote.installs, 0);
    await tester.tap(find.text('Install remotely'));
    await tester.pumpAndSettle();
    expect(remote.installs, 1);
    expect(find.textContaining('Install Antigravity'), findsOneWidget);
    expect(find.textContaining('Ubuntu'), findsOneWidget);
    expect(
      find.text('Installed. Choose Sign in in the model menu.'),
      findsOneWidget,
    );
  });

  test(
    'user-local install rejects bad checksums and keeps an existing agy',
    () async {
      if (!Platform.isLinux) return;
      final dir = await Directory.systemTemp.createTemp('remote-agy-test-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/antigravity').writeAsString('test agent');
      final archive = '${dir.path}/release.tar.gz';
      final tar = await Process.run('tar', [
        '-czf',
        archive,
        '-C',
        dir.path,
        'antigravity',
      ]);
      expect(tar.exitCode, 0);
      final digest = sha512
          .convert(await File(archive).readAsBytes())
          .toString();
      final fakeCurl = File('${dir.path}/curl');
      await fakeCurl.writeAsString('''#!/bin/sh
while [ "\$1" != "-o" ]; do shift; done
cp -- "\$AGY_ARCHIVE" "\$2"
''');
      expect((await Process.run('chmod', ['700', fakeCurl.path])).exitCode, 0);
      Future<ProcessResult> install(String hash) => Process.run(
        '/bin/sh',
        ['-c', remoteAgyInstallScript, 'test', 'https://example.invalid', hash],
        environment: {
          'HOME': dir.path,
          'PATH': '${dir.path}:${Platform.environment['PATH']}',
          'AGY_ARCHIVE': archive,
        },
      );
      final file = File('${dir.path}/.local/bin/agy');
      expect((await install('0' * 128)).exitCode, isNot(0));
      expect(await file.exists(), isFalse);
      expect((await install(digest)).exitCode, 0);
      expect(await file.readAsString(), 'test agent');
      await file.writeAsString('previous executable');
      expect((await install(digest)).exitCode, 0);
      expect(await file.readAsString(), 'previous executable');
    },
  );
}

class _FakeRuntime extends RemoteAgyRuntime {
  _FakeRuntime() : super('wsl+Ubuntu');
  int installs = 0;

  @override
  Future<void> installOnHost({
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    installs++;
  }

  @override
  Future<String?> version() async => '1.5.17';

  @override
  Future<List<AgyModel>> models() async =>
      throw const AgyUnavailable('Sign in required', signIn: true);
}
