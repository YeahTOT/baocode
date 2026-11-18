import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'codex/codex_process_transport.dart';
import '../remote/remote_claude.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex App Server',
    icon: Icons.data_object_rounded,
    description: 'Use the locally installed OpenAI Codex agent',
    create: (context) {
      launch() => createCodexProcessTransport(cwd: context.cwd ?? '');
      return CodexKernel(
        codex,
        launch(),
        context: context,
        restartTransport: launch,
      );
    },
    catalog: const CodexCatalog(),
  );

  static List<KernelDescriptor> _all = [
    claudeCode,
    if (!kIsWeb &&
        const {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform))
      codex,
  ];

  static List<KernelDescriptor> get all => _all;

  static const defaultSettingKey = 'chat.defaultAgent';
  static String? Function() configuredDefault = () => null;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
