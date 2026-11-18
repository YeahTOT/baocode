/// Only account metadata supplied by the local Codex App Server. This does
/// not read credential files, reveal tokens, or initiate a login.
enum CodexAccountKind { unknown, signedOut, chatgpt, apiKey, other }

final class CodexAccountInfo {
  const CodexAccountInfo({
    this.kind = CodexAccountKind.unknown,
    this.email,
    this.plan,
    this.requiresOpenaiAuth,
    this.loading = false,
    this.rateLimits = const [],
    this.rateLimitsUnavailable = false,
  });

  final CodexAccountKind kind;
  final String? email;
  final String? plan;
  final bool? requiresOpenaiAuth;
  final bool loading;
  final List<CodexRateLimitBucket> rateLimits;
  final bool rateLimitsUnavailable;

  factory CodexAccountInfo.fromResult(Map<String, Object?> result) {
    final account = result['account'];
    final fields = account is Map ? account : const {};
    final required = result['requiresOpenaiAuth'];
    return CodexAccountInfo(
      kind: switch (fields['type']) {
        'chatgpt' => CodexAccountKind.chatgpt,
        'apiKey' || 'apikey' => CodexAccountKind.apiKey,
        final String _ => CodexAccountKind.other,
        _ when result.containsKey('account') && account == null =>
          CodexAccountKind.signedOut,
        _ => CodexAccountKind.unknown,
      },
      email: _string(fields['email']),
      plan: _string(fields['planType']),
      requiresOpenaiAuth: required is bool ? required : null,
    );
  }

  CodexAccountInfo withRateLimits(
    List<CodexRateLimitBucket> buckets, {
    bool unavailable = false,
    bool loading = false,
  }) => CodexAccountInfo(
    kind: kind,
    email: email,
    plan: plan,
    requiresOpenaiAuth: requiresOpenaiAuth,
    loading: loading,
    rateLimits: List.unmodifiable(buckets),
    rateLimitsUnavailable: unavailable,
  );

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}

final class CodexRateLimitBucket {
  const CodexRateLimitBucket({
    required this.id,
    this.name,
    this.plan,
    this.primary,
    this.secondary,
  });

  final String id;
  final String? name;
  final String? plan;
  final CodexRateLimitWindow? primary;
  final CodexRateLimitWindow? secondary;

  /// Prefer explicit multi-bucket snapshots, filling in the backwards-
  /// compatible single bucket when necessary.
  static List<CodexRateLimitBucket> fromResult(
    Map<String, Object?> result, {
    Iterable<CodexRateLimitBucket> previous = const [],
  }) {
    final priorById = {for (final bucket in previous) bucket.id: bucket};
    final buckets = <String, CodexRateLimitBucket>{};
    if (_parse(result['rateLimits'], 'codex', priorById) case final bucket?) {
      buckets[bucket.id] = bucket;
    }
    if (result['rateLimitsByLimitId'] case final Map byId) {
      for (final entry in byId.entries) {
        if (entry.key case final String id) {
          if (_parse(entry.value, id, priorById) case final bucket?) {
            buckets[bucket.id] = bucket;
          }
        }
      }
    }
    return List.unmodifiable(buckets.values);
  }

  static CodexRateLimitBucket? _parse(
    Object? value,
    String fallbackId,
    Map<String, CodexRateLimitBucket> previous,
  ) {
    if (value is! Map ||
        (!value.containsKey('primary') && !value.containsKey('secondary'))) {
      return null;
    }
    final id = CodexAccountInfo._string(value['limitId']) ?? fallbackId;
    final prior = previous[id];
    final primary = value.containsKey('primary')
        ? CodexRateLimitWindow._parse(value['primary'], prior?.primary)
        : prior?.primary;
    final secondary = value.containsKey('secondary')
        ? CodexRateLimitWindow._parse(value['secondary'], prior?.secondary)
        : prior?.secondary;
    if (primary == null && secondary == null && prior == null) return null;
    return CodexRateLimitBucket(
      id: id,
      name: value.containsKey('limitName')
          ? CodexAccountInfo._string(value['limitName'])
          : prior?.name,
      plan: value.containsKey('planType')
          ? CodexAccountInfo._string(value['planType'])
          : prior?.plan,
      primary: primary,
      secondary: secondary,
    );
  }
}

final class CodexRateLimitWindow {
  const CodexRateLimitWindow({
    required this.usedPercent,
    this.windowMinutes,
    this.resetsAt,
  });

  final double usedPercent;
  final int? windowMinutes;
  final DateTime? resetsAt;

  static CodexRateLimitWindow? _parse(
    Object? value,
    CodexRateLimitWindow? previous,
  ) {
    if (value is! Map) return null;
    final percent = value['usedPercent'];
    if (percent is! num || !percent.isFinite || percent < 0) return null;
    final duration = value['windowDurationMins'];
    final reset = value['resetsAt'];
    return CodexRateLimitWindow(
      usedPercent: percent.toDouble(),
      windowMinutes: !value.containsKey('windowDurationMins')
          ? previous?.windowMinutes
          : duration is int && duration > 0
          ? duration
          : null,
      resetsAt: !value.containsKey('resetsAt')
          ? previous?.resetsAt
          : reset is int && reset > 0 && reset <= 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true)
          : null,
    );
  }
}
