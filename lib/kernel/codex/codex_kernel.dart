import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_account.dart';
import 'codex_catalog.dart';
import 'codex_history.dart';
import 'codex_subagents.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]. This adapter does not expose
/// background tasks or file undo through BaoCode. Conversation rollback is
/// distinct from reverting workspace files.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        ReportsContext,
        RewindsConversation,
        LoadsHistory,
        AcceptsImages {
  CodexKernel(
    this.descriptor,
    this._transport, {
    KernelContext context = const KernelContext(),
    CodexTransport Function()? restartTransport,
  }) : _context = context,
       _restartTransport = restartTransport,
       _threadId = context.resume?.id,
       _title = context.resume?.title {
    if (restartTransport == null) _health = KernelHealth.ready;
    _listen();
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final CodexTransport Function()? _restartTransport;
  CodexTransport _transport;
  late StreamSubscription<Map<String, Object?>> _subscription;
  Future<void>? _initializing;
  bool _disposed = false;
  bool _transportFailed = false;
  bool _threadAttached = false;
  bool _historyLoaded = false;
  CodexHistoryPager? _historyPager;
  Future<void>? _readingEarlier;
  String? _title;
  Future<void> _catalogWrites = Future.value();

  CodexAccountInfo _accountInfo = const CodexAccountInfo();
  Future<void>? _accountRefresh;
  int _accountEpoch = 0;
  int _quotaEpoch = 0;
  final Map<String, int> _quotaRevisions = {};

  CodexAccountInfo get accountInfo => _accountInfo;

  void _setAccount(CodexAccountInfo value) {
    if (_disposed) return;
    _accountInfo = value;
    emitInfoChanged();
  }

  /// Reads currently active credentials' metadata and ChatGPT quota only.
  /// Authentication remains entirely with the local Codex CLI.
  Future<void> refreshAccount() {
    if (_disposed || _transportFailed || _restartTransport == null) {
      return Future.value();
    }
    final pending = _accountRefresh;
    if (pending != null) return pending;
    final epoch = _accountEpoch;
    final future = _readAccount(epoch);
    _accountRefresh = future;
    return future.whenComplete(() {
      if (identical(_accountRefresh, future)) _accountRefresh = null;
    });
  }

  bool _canReadAccount(int epoch) =>
      !_disposed && !_transportFailed && epoch == _accountEpoch;

  Future<void> _readAccount(int epoch) async {
    _setAccount(
      _accountInfo.withRateLimits(
        _accountInfo.rateLimits,
        unavailable: _accountInfo.rateLimitsUnavailable,
        loading: true,
      ),
    );
    try {
      await _initialize();
      if (!_canReadAccount(epoch)) return;
      final result = await _request('account/read', {
        'refreshToken': false,
      }, timeout: const Duration(seconds: 8));
      if (!_canReadAccount(epoch)) return;
      final account = CodexAccountInfo.fromResult(result);
      if (account.kind != CodexAccountKind.chatgpt) {
        _setAccount(account);
        return;
      }
      final retained =
          _accountInfo.kind == account.kind &&
              _accountInfo.email == account.email &&
              _accountInfo.plan == account.plan
          ? _accountInfo.rateLimits
          : const <CodexRateLimitBucket>[];
      if (retained.isEmpty) _quotaRevisions.clear();
      _setAccount(account.withRateLimits(retained, loading: true));
      final quotaEpoch = _quotaEpoch;
      try {
        final snapshot = await _request(
          'account/rateLimits/read',
          const {},
          timeout: const Duration(seconds: 8),
        );
        if (!_canReadAccount(epoch)) return;
        final buckets = CodexRateLimitBucket.fromResult(snapshot);
        // An incoming update can be newer than an overlapping read. Keep the
        // update for its bucket, filling in any other buckets from the read.
        final current = _accountInfo.rateLimits;
        final merged = quotaEpoch == _quotaEpoch
            ? buckets
            : {
                for (final bucket in buckets) bucket.id: bucket,
                for (final bucket in current)
                  if ((_quotaRevisions[bucket.id] ?? 0) > quotaEpoch)
                    bucket.id: bucket,
              }.values.toList();
        _setAccount(
          account.withRateLimits(merged, unavailable: merged.isEmpty),
        );
      } catch (_) {
        if (_canReadAccount(epoch)) {
          final updated = _accountInfo.rateLimits
              .where((bucket) => (_quotaRevisions[bucket.id] ?? 0) > quotaEpoch)
              .toList();
          _setAccount(
            account.withRateLimits(updated, unavailable: updated.isEmpty),
          );
        }
      }
    } catch (_) {
      // Older servers can omit these account methods. That must not stop
      // the coding adapter or turn a connection into a login failure.
      if (_canReadAccount(epoch)) _setAccount(const CodexAccountInfo());
    }
  }

  void _accountUpdated() {
    if (_disposed || _transportFailed || _restartTransport == null) return;
    _accountEpoch++;
    _accountRefresh = null;
    _quotaRevisions.clear();
    _setAccount(const CodexAccountInfo());
    unawaited(refreshAccount());
  }

  void _quotaUpdated(Map<String, Object?> payload) {
    if (_accountInfo.kind != CodexAccountKind.chatgpt) return;
    final updates = CodexRateLimitBucket.fromResult(
      payload,
      previous: _accountInfo.rateLimits,
    );
    if (updates.isEmpty) return;
    _quotaEpoch++;
    for (final bucket in updates) {
      _quotaRevisions[bucket.id] = _quotaEpoch;
    }
    final buckets = {
      for (final bucket in _accountInfo.rateLimits) bucket.id: bucket,
      for (final bucket in updates) bucket.id: bucket,
    };
    _setAccount(
      _accountInfo.withRateLimits(
        buckets.values.toList(),
        loading: _accountInfo.loading,
      ),
    );
  }

  void _listen() {
    _subscription = _transport.messages.listen(
      (message) {
        try {
          _receive(message);
        } catch (_) {
          _connectionFailed('Codex returned an invalid protocol message.');
        }
      },
      onError: (Object error) => _connectionFailed(error),
      onDone: () => _connectionFailed('The Codex process exited.'),
    );
  }

  @override
  late final LocalChoice model = LocalChoice(
    _restartTransport == null ? _models : const [],
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  late final KernelChoiceSource mode = LocalChoice(
    _modes,
    onChanged: (_) => emitInfoChanged(),
  );

  KernelHealth _health = KernelHealth.idle;

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _threadId;

  @override
  Future<void> get stopped async {
    final transport = _transport;
    if (transport is ManagedCodexTransport) await transport.stopped;
    await _catalogWrites;
  }

  @override
  void prepare() {
    if (_disposed || _restartTransport == null || _transportFailed) return;
    final transport = _transport;
    unawaited(() async {
      try {
        await _initialize();
        if (_context.resume != null && !_historyLoaded && _turn == null) {
          await _attachThread();
        }
      } catch (error) {
        if (identical(transport, _transport)) _connectionFailed(error);
      }
    }());
  }

  @override
  void release() {}

  @override
  void restart() {
    final create = _restartTransport;
    if (_disposed || !_transportFailed || create == null) return;
    unawaited(_subscription.cancel());
    _transport.close();
    _transport = create();
    _transportFailed = false;
    _threadAttached = false;
    _initializing = null;
    _serverTurn = null;
    _attaching = null;
    _listen();
    prepare();
  }

  static const _models = [
    KernelOption(
      'gpt-5.5-codex',
      'GPT-5.5 Codex',
      Icons.bolt_rounded,
      'Tuned for coding',
    ),
    KernelOption('gpt-5.5', 'GPT-5.5', Icons.bolt_rounded, 'General purpose'),
    KernelOption('gpt-5.5-mini', 'GPT-5.5 mini', Icons.bolt_rounded, 'Fastest'),
  ];

  /// Modes are its approval and sandbox policies.
  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace, ask before commands',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  @override
  int get contextWindow => 272000;

  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};
  Future<void>? _attaching;
  bool _cancelRequested = false;
  bool _interruptSent = false;
  String? _threadId;

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};
  final _subagents = CodexSubagents(DateTime.now);

  /// Pending approvals: our request id → the server's JSON-RPC id.
  final Map<String, Object?> _approvals = {};

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    try {
      _transport.write({'id': id, 'method': method, 'params': params});
    } catch (error, stack) {
      _responses.remove(id)?.completeError(error, stack);
    }
    return response.future.timeout(
      timeout,
      onTimeout: () {
        _responses.remove(id);
        throw TimeoutException('Codex did not answer $method.');
      },
    );
  }

  void _connectionFailed(Object error) {
    if (_disposed || _transportFailed) return;
    _transportFailed = true;
    _accountEpoch++;
    _accountRefresh = null;
    _quotaRevisions.clear();
    _accountInfo = const CodexAccountInfo();
    _health = KernelHealth(
      KernelHealthStatus.failed,
      message: 'Codex App Server: $error',
    );
    final responses = _responses.values.toList();
    _responses.clear();
    for (final response in responses) {
      response.completeError(StateError('The Codex connection closed.'));
    }
    _transport.close();
    if (_turn case final turn?) {
      _reportTurnError(turn, _health.message!);
    }
    emitInfoChanged();
  }

  void _reportTurnError(String turn, String message) {
    emit(
      ItemUpserted(
        nextSeq,
        '$turn:error',
        NoticeItem(NoticeKind.error, message),
      ),
    );
    _endTurn(turn, interrupted: true);
  }

  Future<void> _initialize() => _initializing ??= () async {
    _health = const KernelHealth(KernelHealthStatus.starting);
    emitInfoChanged();
    await _request('initialize', {
      'clientInfo': {'name': 'baocode', 'title': 'BaoCode', 'version': '1.0.0'},
    });
    if (_disposed) return;
    _transport.write({'method': 'initialized'});
    if (_restartTransport != null) {
      final result = await _request('model/list', {'limit': 100});
      final models = <KernelOption>[];
      String? defaultModel;
      for (final raw in result['data'] as List? ?? const []) {
        if (raw is! Map || raw['hidden'] == true) continue;
        final id = raw['id'] ?? raw['model'];
        if (id is! String || id.isEmpty) continue;
        models.add(
          KernelOption(
            id,
            raw['displayName'] as String? ?? id,
            Icons.bolt_rounded,
            raw['description'] as String? ?? '',
          ),
        );
        if (raw['isDefault'] == true) defaultModel = id;
      }
      model.options = models;
      model.reported = defaultModel;
    }
    _health = KernelHealth.ready;
    emitInfoChanged();
    if (_restartTransport != null && _accountRefresh == null) {
      unawaited(refreshAccount());
    }
  }();

  Future<void> _attachThread() {
    if (_threadAttached) return Future.value();
    return _attaching ??= () async {
      try {
        final threadId = _threadId;
        final started = await _request(
          threadId == null ? 'thread/start' : 'thread/resume',
          {
            'threadId': ?threadId,
            if (threadId != null)
              'excludeTurns': _historyLoaded || _restartTransport != null,
            if (threadId == null && model.selected != null)
              'model': model.selected,
            'cwd': ?_context.cwd,
          },
        );
        final thread = started['thread'] as Map;
        _threadId = thread['id'] as String;
        if (threadId != null && !_historyLoaded) {
          if (started['model'] case final String resumedModel
              when model.options.any((option) => option.id == resumedModel)) {
            model.reported = resumedModel;
          }
          await _initialHistory(threadId, thread);
        }
        _threadAttached = true;
        _historyLoaded = true;
        emitInfoChanged();
      } finally {
        _attaching = null;
      }
    }();
  }

  @override
  bool get loadingHistory =>
      _context.resume != null && !_historyLoaded && !_transportFailed;

  @override
  bool get hasEarlierHistory =>
      _historyLoaded && (_historyPager?.hasEarlier ?? false);

  @override
  bool get loadingEarlier => _readingEarlier != null;

  Future<void> _initialHistory(String threadId, Map thread) async {
    var history = CodexHistory.itemsFromThread(thread);
    if (history.isEmpty && _restartTransport != null) {
      final pager = CodexHistoryPager(threadId, _request);
      try {
        history = await pager.loadEarlier();
        _historyPager = pager;
      } on StateError {
        // Older CLI builds may not support the paging method. They retain
        // one legacy snapshot endpoint; don't keep retrying it as a page.
        final result = await _request('thread/read', {
          'threadId': threadId,
          'includeTurns': true,
        });
        history = CodexHistory.itemsFromThread(result['thread']);
      }
    }
    if (history.isNotEmpty && !_disposed) {
      emit(HistoryPrepended(nextSeq, history));
    }
  }

  @override
  Future<void> loadEarlier() {
    if (_readingEarlier case final pending?) return pending;
    final pager = _historyPager;
    if (_disposed || _transportFailed || pager == null || !pager.hasEarlier) {
      return Future.value();
    }
    final transport = _transport;
    final pending = () async {
      try {
        final history = await pager.loadEarlier();
        if (!_disposed &&
            identical(transport, _transport) &&
            history.isNotEmpty) {
          emit(HistoryPrepended(nextSeq, history));
        }
      } catch (_) {
        // Retain the cursor for retry. Never turn a failed scrollback request
        // into a failed coding turn.
      } finally {
        _readingEarlier = null;
        if (!_disposed) emitInfoChanged();
      }
    }();
    _readingEarlier = pending;
    emitInfoChanged();
    return pending;
  }

  void _rememberTurn(String text) {
    final catalog = descriptor.catalog;
    final id = _threadId;
    final cwd = _context.cwd;
    if (catalog is! CodexCatalog || id == null || cwd == null) return;
    final prompt = text.split('\n').first.trim();
    if ((_title ?? '').isEmpty && prompt.isNotEmpty) {
      _title = String.fromCharCodes(prompt.runes.take(100));
    }
    final record = SessionRecord(
      id: id,
      title: _title ?? '',
      cwd: cwd,
      updatedAt: DateTime.now(),
    );
    _catalogWrites = _catalogWrites.then((_) async {
      try {
        await catalog.remember(record);
      } catch (_) {
        if (!_disposed) {
          emit(
            ItemUpserted(
              nextSeq,
              '$id:catalog-error',
              const NoticeItem(
                NoticeKind.error,
                'Could not save this Codex thread to the BaoCode history list.',
              ),
            ),
          );
        }
      }
    });
  }

  @override
  void send(KernelTurn turn) {
    if (_disposed ||
        _transportFailed ||
        _turn != null ||
        !_sentTurns.add(turn.id)) {
      return;
    }
    _turn = turn.id;
    _turnStarted = DateTime.now();
    _cancelRequested = false;
    _interruptSent = false;
    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );
    final transport = _transport;
    unawaited(() async {
      try {
        await _start(turn);
      } on TimeoutException catch (error) {
        if (identical(transport, _transport)) _connectionFailed(error);
      } catch (error) {
        if (_turn == turn.id) _reportTurnError(turn.id, 'Codex: $error');
        if (_health.status == KernelHealthStatus.starting &&
            identical(transport, _transport)) {
          _connectionFailed(error);
        }
      }
    }());
  }

  Future<void> _start(KernelTurn turn) async {
    await _initialize();
    if (_turn != turn.id) return;
    if (_cancelRequested) {
      _endTurn(turn.id, interrupted: true);
      return;
    }
    await _attachThread();
    if (_turn != turn.id) return;
    if (_cancelRequested) {
      _endTurn(turn.id, interrupted: true);
      return;
    }
    final readOnly = mode.selected == 'ask';
    final started = await _request('turn/start', {
      'threadId': _threadId,
      'cwd': ?_context.cwd,
      'input': [
        {'type': 'text', 'text': turn.text},
        for (final note in turn.notes) {'type': 'text', 'text': note},
        for (final image in turn.images)
          {
            'type': 'image',
            'url':
                'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
          },
      ],
      'model': ?model.selected,
      'approvalPolicy': readOnly ? 'never' : 'on-request',
      'sandboxPolicy': {'type': readOnly ? 'readOnly' : 'workspaceWrite'},
    });
    if (!_disposed) _rememberTurn(turn.text);
    if (_turn != turn.id || _disposed) return;
    _serverTurn ??= (started['turn'] as Map)['id'] as String;
    if (_cancelRequested) _interrupt();
  }

  void _interrupt() {
    final serverTurn = _serverTurn;
    final threadId = _threadId;
    if (serverTurn == null || threadId == null || _interruptSent) return;
    _interruptSent = true;
    unawaited(() async {
      try {
        await _request('turn/interrupt', {
          'threadId': threadId,
          'turnId': serverTurn,
        });
      } catch (error) {
        if (_serverTurn == serverTurn) _connectionFailed(error);
      }
    }());
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (!_approvals.containsKey(requestId)) return;
    final rpcId = _approvals.remove(requestId);
    emit(InteractionResolved(nextSeq, requestId));
    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport.write({
      'id': rpcId,
      'result': {'decision': decision},
    });
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _cancelRequested = true;
    _interrupt();
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    if (_threadId case final threadId? when turns > 0) {
      try {
        await _attachThread();
        await _request('thread/rollback', {
          'threadId': threadId,
          'numTurns': turns,
        });
      } catch (error) {
        emit(
          ItemUpserted(
            nextSeq,
            '$itemId:rewind',
            NoticeItem(NoticeKind.error, 'Codex: $error'),
          ),
        );
        return false;
      }
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _turn = null;
    unawaited(_subscription.cancel());
    final responses = _responses.values.toList();
    _responses.clear();
    for (final response in responses) {
      response.completeError(StateError('Codex session closed.'));
    }
    _transport.close();
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      final response = _responses.remove(message['id']);
      if (response == null) return;
      if (message['error'] case final Map error) {
        response.completeError(
          StateError(error['message'] as String? ?? 'Codex RPC failed.'),
        );
        return;
      }
      final result = (message['result'] as Map?)?.cast<String, Object?>();
      response.complete(result ?? const {});
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    if (params?['threadId'] case final String id when id != _threadId) return;
    switch (method) {
      case 'account/updated':
        // Capabilities can emit while a synchronous test transport is still
        // dispatching the notification; do not reenter that stream.
        scheduleMicrotask(_accountUpdated);
      case 'account/rateLimits/updated':
        _quotaUpdated(params ?? const {});
      case 'turn/started':
        if (_turn == null) return;
        _serverTurn = (params!['turn'] as Map)['id'] as String;
        if (_cancelRequested) _interrupt();
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        if (_serverTurn != null && turn['id'] != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          if (turn['status'] == 'failed') {
            final error = (turn['error'] as Map?)?['message'] ?? 'Turn failed.';
            _reportTurnError(ours, 'Codex: $error');
          } else {
            _endTurn(ours, interrupted: turn['status'] == 'interrupted');
          }
        }
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/reasoning/summaryTextDelta':
        final id = params!['itemId'] as String;
        final buffer = _reasoning[id];
        if (buffer == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null && buffer.isNotEmpty && part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
    }
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    final (title, preview) = switch (method) {
      'item/commandExecution/requestApproval' => (
        'Run command',
        CommandPreview('${params['command']}') as ApprovalPreview?,
      ),
      'item/fileChange/requestApproval' => ('Apply changes', null),
      _ => (null, null),
    };
    if (title == null) {
      _transport.write({
        'id': rpcId,
        'error': {'code': -32601, 'message': 'Unsupported server request'},
      });
      return;
    }
    final threadId = params['threadId'];
    final turnId = params['turnId'];
    if (_turn == null ||
        _cancelRequested ||
        (threadId != null && threadId != _threadId) ||
        (turnId != null && _serverTurn != null && turnId != _serverTurn)) {
      _transport.write({
        'id': rpcId,
        'result': {'decision': 'decline'},
      });
      return;
    }
    final id = 'approval:$rpcId';
    _approvals[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: method.split('/')[1],
          reason: params['reason'] as String?,
          preview: preview,
          alwaysAllowLabel: 'Approve for this session',
        ),
      ),
    );
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'collabAgentToolCall' || 'subAgentActivity':
        for (final (key, card) in _subagents.apply(
          item,
          parentThreadId: _threadId,
        )) {
          emit(ItemUpserted(nextSeq, key, card));
        }
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningClock[id] = Stopwatch()..start();
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'collabAgentToolCall' || 'subAgentActivity':
        for (final (key, card) in _subagents.apply(
          item,
          parentThreadId: _threadId,
        )) {
          emit(ItemUpserted(nextSeq, key, card));
        }
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        final text =
            buffer?.toString() ??
            (item['summary'] as List<Object?>? ?? const []).join('\n\n');
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(
                1,
                ((clock?.elapsedMilliseconds ?? 0) / 1000).round(),
              ),
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String),
          ),
        );
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        // A declined or failed patch is not a confirmed workspace edit.
        if (item['status'] case final String status
            when status != 'completed') {
          return;
        }
        final changes = item['changes'] as List<Object?>;
        for (final (index, raw) in changes.indexed) {
          final change = raw as Map;
          _fileChange(
            '$id:$index',
            change['path'] as String,
            change['diff'] as String,
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List<Object?>? ?? const [])
        (action as Map).cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final done = switch (item['status']) {
      'completed' || 'failed' || 'declined' || 'interrupted' => true,
      _ => false,
    };
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String;
      return ToolCallItem(
        kind: ToolKind.read,
        target: path.split(RegExp(r'[/\\]')).last,
        path: path,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String,
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      output: output ?? '',
      status: !done
          ? CommandStatus.running
          : item['status'] == 'completed' && item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(String id, String path, String diff, {String? kind}) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    var inHunk = false;
    final diffLines = diff.split('\n');
    final wholeFile = !diffLines.any(hunk.hasMatch);
    for (var i = 0; i < diffLines.length; i++) {
      final line = diffLines[i];
      if (wholeFile && (kind == 'add' || kind == 'delete')) {
        if (line.isEmpty && i == diffLines.length - 1) continue;
        if (kind == 'add') {
          lines.add(DiffLine(DiffLineType.added, newLine++, line));
          added++;
        } else {
          lines.add(DiffLine(DiffLineType.removed, oldLine++, line));
          removed++;
        }
        continue;
      }
      if (hunk.firstMatch(line) case final match?) {
        inHunk = true;
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty ||
          !inHunk ||
          (line[0] != '+' && line[0] != '-' && line[0] != ' ')) {
        continue;
      }
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: path.substring(slash + 1),
          directory: slash < 0 ? '' : path.substring(0, slash),
          lines: lines,
        ),
      ),
    );
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: added, removed: removed),
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    _serverTurn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}
