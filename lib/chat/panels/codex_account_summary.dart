import 'package:flutter/material.dart';

import '../../kernel/codex/codex_account.dart';
import '../../l10n/l10n.dart';
import '../../models/codex/codex_quota_format.dart';
import '../../theme/app_theme.dart';

/// The login and limits of the Codex process backing this conversation,
/// separate from context tokens and BaoCode's provider-account limits.
class CodexAccountSummary extends StatelessWidget {
  const CodexAccountSummary({
    super.key,
    required this.account,
    required this.onRefresh,
  });

  final CodexAccountInfo account;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final limits = account.rateLimits.where(
      (bucket) => bucket.primary != null || bucket.secondary != null,
    );
    final details = [
      if (account.kind == CodexAccountKind.chatgpt) l10n.codexAccountChatGpt,
      if (account.email case final email? when email.isNotEmpty) email,
      if (account.plan case final plan? when plan.isNotEmpty) plan,
    ].join(' · ');
    final note = switch (account.kind) {
      CodexAccountKind.signedOut => l10n.codexAccountSignIn,
      CodexAccountKind.apiKey => l10n.codexAccountApiKey,
      _ when account.loading && limits.isEmpty => l10n.usageCheckingLimits,
      _ when account.rateLimitsUnavailable || limits.isEmpty =>
        l10n.usageLimitsUnavailable,
      _ => null,
    };
    final faint = TextStyle(color: AppColors.textMuted, fontSize: 11);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.codexAccountLimits,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.commonRefresh,
              onPressed: account.loading ? null : onRefresh,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              iconSize: 16,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (details.isNotEmpty) Text(details, style: faint),
        if (note != null) Text(note, style: faint),
        for (final bucket in limits) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(bucket.name ?? bucket.id, style: faint),
          ),
          if (bucket.primary case final window?) _Window(window: window),
          if (bucket.secondary case final window?) _Window(window: window),
        ],
      ],
    );
  }
}

class _Window extends StatelessWidget {
  const _Window({required this.window});

  final CodexRateLimitWindow window;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final minutes = window.windowMinutes;
    final duration = minutes == null || minutes <= 0
        ? l10n.codexAccountWindow
        : minutes < 60
        ? l10n.modelsDurationMinutes(minutes)
        : minutes % 60 != 0
        ? l10n.modelsDurationHours(minutes ~/ 60, minutes % 60)
        : quotaWindowName(l10n, minutes);
    final remaining = (100 - window.usedPercent).clamp(0, 100).round();
    final now = DateTime.now();
    final reset = window.resetsAt;
    final label = [
      l10n.quotaBarWindowLeft(duration, remaining),
      if (reset != null && reset.isAfter(now)) quotaResets(l10n, reset, now),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: TextStyle(color: AppColors.text, fontSize: 11)),
          const SizedBox(height: 3),
          LinearProgressIndicator(
            value: remaining / 100,
            minHeight: 3,
            borderRadius: const BorderRadius.all(Radius.circular(2)),
          ),
        ],
      ),
    );
  }
}
