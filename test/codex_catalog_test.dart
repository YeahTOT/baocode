import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'stores only named BaoCode threads and keeps the newest first',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bao-codex-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final catalog = CodexCatalog(directory: directory.path);
      final project = p.join(directory.path, 'project');
      final other = p.join(directory.path, 'other');
      SessionRecord record(String id, String cwd, int minute, String title) =>
          SessionRecord(
            id: id,
            cwd: cwd,
            title: title,
            updatedAt: DateTime.utc(2026, 1, 1, 0, minute),
          );

      expect(await catalog.projects(), isEmpty);
      await Future.wait([
        catalog.remember(record('thread-1', project, 1, 'original')),
        catalog.remember(record('thread-2', project, 2, 'second')),
        catalog.remember(record('thread-3', other, 3, 'different project')),
        catalog.remember(record('../out-of-index', project, 4, 'invalid id')),
      ]);
      await catalog.remember(record('thread-1', project, 4, 'updated'));
      await File(p.join(directory.path, 'broken.json')).writeAsString('{');

      final reopened = CodexCatalog(directory: directory.path);
      final threads = await reopened.sessionsIn(project);
      expect(threads.map((item) => item.id), ['thread-1', 'thread-2']);
      expect(threads.first.title, 'updated');
      expect((await reopened.projects()).map((item) => item.path), [
        project,
        other,
      ]);
      await reopened.delete('thread-1');
      await reopened.delete('thread-1');
      expect((await reopened.sessionsIn(project)).single.id, 'thread-2');
      expect((await reopened.sessionsIn(other)).single.id, 'thread-3');
    },
  );

  test('history ignores unknown items and preserves order and IDs', () {
    final items = CodexHistory.itemsFromThread({
      'turns': [
        {
          'items': [
            {
              'id': 'user',
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': 'hello'},
                {'type': 'localImage', 'path': '/unread'},
              ],
            },
            {'id': 'unknown', 'type': 'futureItem'},
            {'id': 'reply', 'type': 'agentMessage', 'text': 'hi'},
            {'id': 'bad', 'type': 'agentMessage', 'text': 123},
          ],
        },
        {
          'items': [
            {
              'id': 'command',
              'type': 'commandExecution',
              'aggregatedOutput': 'ok',
              'command': 'echo ok',
              'status': 'completed',
              'exitCode': 0,
            },
          ],
        },
      ],
    });
    expect(items.map((item) => item.$1), ['user', 'reply', 'command']);
    expect((items.first.$2 as UserMessageItem).text, 'hello\n[Image]');
    expect((items.last.$2 as TerminalItem).status, CommandStatus.succeeded);
  });
}
