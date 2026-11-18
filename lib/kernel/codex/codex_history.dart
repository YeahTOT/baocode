import '../../chat/chat_models.dart';
import 'codex_subagents.dart';

/// Converts a stored Codex thread into BaoCode's transcript items. Historical
/// commands and edits are display records, never pending approvals or edits.
abstract final class CodexHistory {
  /// Takes the `thread` object from `thread/read` or `thread/resume`.
  /// Unknown items are skipped to tolerate newer App Server protocol versions.
  static List<(String, ChatItem)> itemsFromThread(Object? thread) {
    if (thread is! Map || thread['turns'] is! List) return const [];
    final result = <(String, ChatItem)>[];
    final subagents = CodexSubagents();
    final subagentSlots = <String, int>{};
    final parentId = thread['id'];
    for (final turn in thread['turns'] as List) {
      if (turn is! Map || turn['items'] is! List) continue;
      for (final item in turn['items'] as List) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String || id.isEmpty) continue;
        switch (item['type']) {
          case 'collabAgentToolCall' || 'subAgentActivity':
            for (final (key, card) in subagents.apply(
              item,
              parentThreadId: parentId is String ? parentId : null,
            )) {
              final position = subagentSlots.putIfAbsent(
                key,
                () => result.length,
              );
              if (position == result.length) {
                result.add((key, card));
              } else {
                result[position] = (key, card);
              }
            }
          case 'userMessage':
            final content = item['content'];
            if (content is! List) continue;
            final text = [
              for (final part in content)
                if (part is Map)
                  if (part['type'] == 'text' && part['text'] is String)
                    part['text'] as String
                  else if (part['type'] == 'image' ||
                      part['type'] == 'localImage')
                    '[Image]',
            ].join('\n');
            if (text.isNotEmpty) {
              result.add((id, UserMessageItem(text: text)));
            }
          case 'agentMessage':
            if (item['text'] case final String text when text.isNotEmpty) {
              result.add((id, AssistantTextItem(text)));
            }
          case 'reasoning':
            final summary = item['summary'];
            if (summary is! List) continue;
            final text = summary.whereType<String>().join('\n\n');
            if (text.isNotEmpty) {
              result.add((id, ThinkingItem(text: text, tokens: 0, seconds: 0)));
            }
          case 'commandExecution':
            if (item['command'] case final String command) {
              result.add((
                id,
                TerminalItem(
                  command: command,
                  output: item['aggregatedOutput'] is String
                      ? item['aggregatedOutput'] as String
                      : '',
                  status:
                      item['status'] == 'completed' &&
                          (item['exitCode'] == null || item['exitCode'] == 0)
                      ? CommandStatus.succeeded
                      : CommandStatus.failed,
                ),
              ));
            }
          case 'fileChange':
            final changes = item['changes'];
            if (changes is! List) continue;
            for (final (index, change) in changes.indexed) {
              if (change is! Map || change['path'] is! String) continue;
              final path = change['path'] as String;
              result.add((
                '$id:$index',
                ToolCallItem(
                  kind: ToolKind.edit,
                  target: path.split(RegExp(r'[/\\]')).last,
                  path: path,
                  status: switch (item['status']) {
                    'completed' => ToolStatus.succeeded,
                    'declined' => ToolStatus.denied,
                    _ => ToolStatus.failed,
                  },
                ),
              ));
            }
        }
      }
    }
    return result;
  }
}

/// Newest-first transport with oldest-first batches for the transcript.
/// A failed fetch can be retried and does not consume its cursor.
class CodexHistoryPager {
  CodexHistoryPager(this.threadId, this._request, {this.pageSize = 12});

  final String threadId;
  final int pageSize;
  final Future<Map<String, Object?>> Function(
    String method,
    Map<String, Object?> params,
  )
  _request;

  bool _started = false;
  String? _cursor;
  final _usedCursors = <String>{};
  Future<List<(String, ChatItem)>>? _loading;

  bool get hasEarlier => !_started || _cursor != null;
  bool get loading => _loading != null;

  Future<List<(String, ChatItem)>> loadEarlier() {
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    if (!hasEarlier) return Future.value(const []);
    return _loading = _fetch().whenComplete(() {
      _loading = null;
    });
  }

  Future<List<(String, ChatItem)>> _fetch() async {
    final cursor = _cursor;
    final page = await _request('thread/turns/list', {
      'threadId': threadId,
      'cursor': ?cursor,
      'sortDirection': 'desc',
      'itemsView': 'full',
      'limit': pageSize,
    });
    final turns = page['data'];
    if (turns is! List) {
      throw const FormatException('Codex history page has no turn list.');
    }
    final items = CodexHistory.itemsFromThread({
      'id': threadId,
      'turns': turns.reversed.toList(growable: false),
    });
    _started = true;
    if (cursor != null) _usedCursors.add(cursor);
    final next = page['nextCursor'];
    _cursor = next is String && next.isNotEmpty && !_usedCursors.contains(next)
        ? next
        : null;
    return items;
  }
}
