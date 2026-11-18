import '../../chat/chat_models.dart';

/// Projects Codex's parent-thread collaboration items onto the transcript's
/// existing subagent cards. Each child has one stable row; a tool call
/// completing (e.g. spawn) is not evidence that the child has finished.
final class CodexSubagents {
  CodexSubagents([this._now]);

  final DateTime Function()? _now;
  final _cards = <String, AgentItem>{};

  /// Returns just the rows changed by this protocol item. Raw events from
  /// another parent are not considered when [parentThreadId] is supplied.
  List<(String, AgentItem)> apply(
    Map<dynamic, dynamic> item, {
    String? parentThreadId,
  }) {
    switch (item['type']) {
      case 'subAgentActivity':
        if (item['agentThreadId'] case final String id when id.isNotEmpty) {
          final prior = _cards[id];
          final kind = item['kind'];
          return [
            _upsert(
              id,
              name: _nonempty(item['agentPath']),
              model: _nonempty(item['model']),
              status: switch (kind) {
                'started' => CommandStatus.running,
                'interrupted' => CommandStatus.failed,
                'completed' =>
                  prior?.status == CommandStatus.failed
                      ? CommandStatus.failed
                      : CommandStatus.succeeded,
                _ => null,
              },
              fresh:
                  kind == 'started' &&
                  prior != null &&
                  prior.status != CommandStatus.running,
            ),
          ];
        }

      case 'collabAgentToolCall':
        final sender = item['senderThreadId'];
        if (parentThreadId != null &&
            sender is String &&
            sender != parentThreadId) {
          return const [];
        }
        final receivers = item['receiverThreadIds'];
        final states = item['agentsStates'];
        final tool = item['tool'];
        final ids = <String>{
          if (receivers is List) ...receivers.whereType<String>(),
          if (states is Map) ...states.keys.whereType<String>(),
        }..remove('');
        final callId = item['id'];
        if (ids.isEmpty &&
            tool == 'spawnAgent' &&
            (item['status'] == 'failed' || item['status'] == 'interrupted') &&
            callId is String) {
          return [
            _upsert(
              'failed-spawn:$callId',
              prompt: _nonempty(item['prompt']),
              model: _nonempty(item['model']),
              status: CommandStatus.failed,
            ),
          ];
        }
        return [
          for (final id in ids)
            _fromCollaboration(
              id,
              states is Map ? states[id] : null,
              prompt: tool == 'spawnAgent' ? _nonempty(item['prompt']) : null,
              model: tool == 'spawnAgent' ? _nonempty(item['model']) : null,
            ),
        ];
    }
    return const [];
  }

  (String, AgentItem) _fromCollaboration(
    String id,
    Object? state, {
    String? prompt,
    String? model,
  }) {
    final map = state is Map ? state : null;
    final status = map?['status'];
    final prior = _cards[id]?.status;
    final commandStatus = switch (status) {
      'completed' => CommandStatus.succeeded,
      'interrupted' || 'errored' || 'notFound' => CommandStatus.failed,
      'shutdown' =>
        prior == CommandStatus.succeeded
            ? CommandStatus.succeeded
            : CommandStatus.failed,
      'pendingInit' || 'running' => CommandStatus.running,
      _ => null,
    };
    return _upsert(
      id,
      prompt: prompt,
      model: model,
      status: commandStatus,
      fresh:
          commandStatus == CommandStatus.running &&
          prior != null &&
          prior != CommandStatus.running,
      result: switch (status) {
        'completed' || 'errored' => _nonempty(map?['message']),
        _ => null,
      },
    );
  }

  (String, AgentItem) _upsert(
    String id, {
    String? name,
    String? prompt,
    String? model,
    CommandStatus? status,
    String? result,
    bool fresh = false,
  }) {
    final key = 'codex-subagent:$id';
    final previous = _cards[id];
    final previousStart = previous?.startedAt;
    final current = status ?? previous?.status ?? CommandStatus.running;
    final at = _now?.call();
    final item = AgentItem(
      id: key,
      description: name ?? previous?.description ?? 'Codex subagent',
      prompt: prompt ?? previous?.prompt,
      model: model ?? previous?.model,
      status: current,
      startedAt: fresh ? at : previousStart ?? at,
      duration: current == CommandStatus.running
          ? null
          : previous?.duration ??
                (at != null && previousStart != null
                    ? at.difference(previousStart)
                    : null),
      result: fresh ? result : result ?? previous?.result,
    );
    _cards[id] = item;
    return (key, item);
  }

  static String? _nonempty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
