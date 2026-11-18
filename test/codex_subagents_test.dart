import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/codex/codex_history.dart';
import 'package:baocode/kernel/codex/codex_subagents.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> collaboration({
  String sender = 'root',
  String tool = 'spawnAgent',
  String? child = 'child-1',
  String? status,
  String? report,
  String callStatus = 'completed',
}) => {
  'type': 'collabAgentToolCall',
  'id': 'call-1',
  'senderThreadId': sender,
  'receiverThreadIds': [?child],
  'tool': tool,
  'status': callStatus,
  'prompt': 'check style',
  'model': 'codex-model',
  'agentsStates': {
    if (child != null && status != null)
      child: {'status': status, 'message': report},
  },
};

void main() {
  test('spawn completion is running until a child status says otherwise', () {
    var time = DateTime(2026, 11, 18, 12);
    final view = CodexSubagents(() => time);
    final (key, start) = view
        .apply(collaboration(), parentThreadId: 'root')
        .single;
    expect(start.status, CommandStatus.running);
    expect(start.prompt, 'check style');
    expect(start.model, 'codex-model');
    time = time.add(const Duration(seconds: 5));
    final (afterKey, after) = view
        .apply(
          collaboration(
            tool: 'wait',
            status: 'completed',
            report: 'style checks passed',
          ),
          parentThreadId: 'root',
        )
        .single;
    expect(afterKey, key);
    expect(after.status, CommandStatus.succeeded);
    expect(after.result, 'style checks passed');
    expect(after.duration, const Duration(seconds: 5));
  });

  test(
    'rejects collaboration from a different parent and shows failed spawn',
    () {
      final view = CodexSubagents();
      expect(
        view.apply(collaboration(sender: 'other'), parentThreadId: 'root'),
        isEmpty,
      );
      final (key, after) = view
          .apply(
            collaboration(child: null, callStatus: 'failed'),
            parentThreadId: 'root',
          )
          .single;
      expect(key, contains('failed-spawn'));
      expect(after.status, CommandStatus.failed);
    },
  );

  test('history folds lifecycle updates into one existing subagent card', () {
    final items = CodexHistory.itemsFromThread({
      'id': 'root',
      'turns': [
        {
          'items': [
            collaboration(),
            collaboration(sender: 'other', child: 'another-threads-child'),
            {
              'type': 'subAgentActivity',
              'id': 'done',
              'agentThreadId': 'child-1',
              'agentPath': 'root/review',
              'kind': 'completed',
            },
          ],
        },
      ],
    });
    final card = items.single.$2 as AgentItem;
    expect(card.description, 'root/review');
    expect(card.prompt, 'check style');
    expect(card.status, CommandStatus.succeeded);
  });
}
