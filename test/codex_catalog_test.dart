import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_history.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/transcript.dart';
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
      final otherWindow = CodexCatalog(directory: directory.path);
      await Future.wait([
        catalog.remember(record('thread-1', project, 4, 'updated')),
        otherWindow.remember(record('thread-1', project, 1, 'stale')),
      ]);
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

  test(
    'pages from the newest turns and prepends each batch chronologically',
    () async {
      final requests = <Map<String, Object?>>[];
      final reply = Completer<Map<String, Object?>>();
      Map<String, Object?> turn(String id) => {
        'items': [
          {'type': 'agentMessage', 'id': id, 'text': id},
        ],
      };
      final pager = CodexHistoryPager('example-thread', (method, params) async {
        expect(method, 'thread/turns/list');
        requests.add(params);
        if (requests.length == 1) return reply.future;
        if (requests.length == 2) throw StateError('temporary disconnect');
        return {
          'data': [turn('second'), turn('first')],
          // Some builds can repeat a cursor. Don't loop on it.
          'nextCursor': 'older',
        };
      }, pageSize: 2);

      final newest = pager.loadEarlier();
      expect(pager.loading, isTrue);
      expect(pager.loadEarlier(), same(newest));
      reply.complete({
        'data': [turn('fourth'), turn('third')],
        'nextCursor': 'older',
      });
      expect((await newest).map((entry) => entry.$1), ['third', 'fourth']);
      expect(pager.loading, isFalse);
      expect(requests.first, {
        'threadId': 'example-thread',
        'sortDirection': 'desc',
        'itemsView': 'full',
        'limit': 2,
      });
      expect(pager.hasEarlier, isTrue);
      await expectLater(pager.loadEarlier(), throwsStateError);
      expect(pager.hasEarlier, isTrue);
      expect((await pager.loadEarlier()).map((entry) => entry.$1), [
        'first',
        'second',
      ]);
      expect(requests[1]['cursor'], 'older');
      expect(requests[2]['cursor'], 'older');
      expect(pager.hasEarlier, isFalse);
      expect(await pager.loadEarlier(), isEmpty);
      expect(requests, hasLength(3));
    },
  );

  test('older history does not replace a newer subagent status', () async {
    final pager = CodexHistoryPager('parent', (_, params) async {
      final older = params.containsKey('cursor');
      return {
        if (!older) 'nextCursor': 'older',
        'data': [
          {
            'items': [
              {
                'id': older ? 'spawn' : 'completion',
                'type': 'subAgentActivity',
                'agentThreadId': 'child',
                'kind': older ? 'started' : 'completed',
              },
              {
                'id': 'unrelated',
                'type': 'collabAgentToolCall',
                'senderThreadId': 'unrelated-parent',
                'receiverThreadIds': ['unrelated-child'],
              },
            ],
          },
        ],
      };
    });
    final transcript = Transcript();
    transcript.apply(HistoryPrepended(1, await pager.loadEarlier()));
    transcript.apply(HistoryPrepended(2, await pager.loadEarlier()));
    final row = transcript.liveItems.single;
    expect(row.$1, 'codex-subagent:child');
    expect((row.$2 as AgentItem).status, CommandStatus.succeeded);
  });
}
