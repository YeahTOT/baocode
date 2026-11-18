import '../../chat/chat_models.dart';

/// Converts a stored Codex thread into BaoCode's transcript items. Historical
/// commands and edits are display records, never pending approvals or edits.
abstract final class CodexHistory {
  /// Takes the `thread` object from `thread/read` or `thread/resume`.
  /// Unknown items are skipped to tolerate newer App Server protocol versions.
  static List<(String, ChatItem)> itemsFromThread(Object? thread) {
    if (thread is! Map || thread['turns'] is! List) return const [];
    final result = <(String, ChatItem)>[];
    for (final turn in thread['turns'] as List) {
      if (turn is! Map || turn['items'] is! List) continue;
      for (final item in turn['items'] as List) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String || id.isEmpty) continue;
        switch (item['type']) {
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
