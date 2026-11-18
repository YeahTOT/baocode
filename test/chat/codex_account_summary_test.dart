import 'package:baocode/chat/panels/codex_account_summary.dart';
import 'package:baocode/kernel/codex/codex_account.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    CodexAccountInfo account,
    VoidCallback onRefresh,
  ) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Material(
        child: CodexAccountSummary(account: account, onRefresh: onRefresh),
      ),
    ),
  );

  testWidgets('reports account and remaining limits separately', (
    tester,
  ) async {
    var refreshed = 0;
    await show(
      tester,
      CodexAccountInfo(
        kind: CodexAccountKind.chatgpt,
        email: 'example@example.com',
        plan: 'plus',
        rateLimits: [
          CodexRateLimitBucket(
            id: 'codex',
            name: 'Codex',
            primary: CodexRateLimitWindow(
              usedPercent: 25,
              windowMinutes: 300,
              resetsAt: DateTime.now().add(const Duration(hours: 2)),
            ),
            secondary: const CodexRateLimitWindow(
              usedPercent: 100,
              windowMinutes: 10080,
            ),
          ),
        ],
      ),
      () => refreshed++,
    );
    expect(find.textContaining('example@example.com'), findsOneWidget);
    expect(find.textContaining('75% left'), findsOneWidget);
    expect(find.textContaining('0% left'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh'));
    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not mistake API key or signed out for exhausted quota', (
    tester,
  ) async {
    await show(
      tester,
      const CodexAccountInfo(kind: CodexAccountKind.apiKey),
      () {},
    );
    expect(find.textContaining('API key'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await show(
      tester,
      const CodexAccountInfo(kind: CodexAccountKind.signedOut),
      () {},
    );
    expect(find.textContaining('local Codex CLI'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
