import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'agy_runtime.dart';
import 'agy_runtime_remote.dart';
import 'agy_ssh_location.dart';

/// The conversations agy keeps (the user's terminal's among them).
/// Startup discovers local projects; known SSH projects are listed on
/// demand, through their own host's runtime.
class AntigravityCatalog implements SessionCatalog, ChangingCatalog {
  const AntigravityCatalog({AgyRuntime Function(String? cwd)? runtimeFor})
    : _runtimeFor = runtimeFor ?? agyRuntimeFor;

  final AgyRuntime Function(String? cwd) _runtimeFor;
  static final Expando<_Listing> _listings = Expando();
  static final _Changes _changes = _Changes();

  @override
  Listenable get changes => _changes;

  static _Listing _listingOf(AgyRuntime runtime) =>
      _listings[runtime] ??= _Listing();

  /// Lists anew next time (a conversation started).
  static void forget([String? host]) {
    final runtime = agyRuntimeFor(
      host == null ? null : RemoteLocation.of(host, '/'),
    );
    _listings[runtime]?.listedAt = null;
  }

  AgyRuntime _remoteRuntime(String cwd) {
    final runtime = _runtimeFor(cwd);
    if (identical(runtime, _runtimeFor(null))) {
      throw const AgyUnavailable('Antigravity is unavailable on this host');
    }
    return runtime;
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final runtime = _runtimeFor(null);
    final byPath = <String, List<SessionRecord>>{};
    for (final session in await _listingOf(
      runtime,
    ).sessions(runtime, useLast: true)) {
      byPath.putIfAbsent(session.cwd, () => []).add(session);
    }
    final projects = [
      for (final MapEntry(key: path, value: sessions) in byPath.entries)
        ProjectRecord(
          path: path,
          sessions: sessions
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        ),
    ];
    projects.sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final host = RemoteLocation.hostOf(cwd);
    final runtime = host == null ? _runtimeFor(null) : _remoteRuntime(cwd);
    final path = RemoteLocation.pathOf(cwd);
    return [
      for (final session in await _listingOf(
        runtime,
      ).sessions(runtime, useLast: host == null))
        if (session.cwd == path)
          if (host == null)
            session
          else
            SessionRecord(
              id: agySessionKey(host, session.id),
              cwd: RemoteLocation.of(host, session.cwd),
              title: session.title,
              updatedAt: session.updatedAt,
              // Workspace's periodic file-modification probe is local.
            ),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<void> delete(String id) async {
    final remote = parseAgySessionKey(id);
    if (remote == null && isAgySshSessionKey(id)) {
      throw const FormatException('Invalid Antigravity SSH session key');
    }
    final runtime = remote == null
        ? _runtimeFor(null)
        : _remoteRuntime(RemoteLocation.of(remote.host, '/'));
    await runtime.delete(remote?.id ?? id);
    // Replace the entry so an older in-flight listing cannot repopulate it.
    _listings[runtime] = null;
  }
}

class _Listing {
  List<SessionRecord>? _listed;
  DateTime? listedAt;
  Future<List<SessionRecord>>? _listing;

  static const _fresh = Duration(seconds: 15);

  Future<List<SessionRecord>> sessions(
    AgyRuntime runtime, {
    required bool useLast,
  }) {
    final at = listedAt;
    if (_listed case final listed?
        when at != null && DateTime.now().difference(at) < _fresh) {
      return Future.value(listed);
    }
    final listing = _listing ??= runtime
        .sessions()
        .then((sessions) {
          _listed = sessions;
          listedAt = DateTime.now();
          return sessions;
        })
        .whenComplete(() => _listing = null);
    if (useLast && _listed == null) {
      if (runtime.lastSessions case final kept?) {
        // Shown at once; told of the listing when it comes.
        _listed = kept;
        unawaited(
          listing.then(
            (_) => AntigravityCatalog._changes.tell(),
            onError: (_) {},
          ),
        );
        return Future.value(kept);
      }
    }
    return listing;
  }
}

class _Changes extends ChangeNotifier {
  void tell() => notifyListeners();
}
