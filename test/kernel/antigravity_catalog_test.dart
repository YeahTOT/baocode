import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/agy_runtime.dart';
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _SessionStore local;
  late _SessionStore alpha;
  late _SessionStore beta;
  late AntigravityCatalog catalog;
  AgyRuntime runtimeFor(String? cwd) {
    if (cwd?.startsWith('ssh://alpha/') ?? false) return alpha;
    if (cwd?.startsWith('ssh://beta/') ?? false) return beta;
    if (cwd?.startsWith('ssh://') ?? false) {
      throw StateError('Unexpected remote project: $cwd');
    }
    return local;
  }

  setUp(() {
    local = _SessionStore('local');
    alpha = _SessionStore('alpha');
    beta = _SessionStore('beta');
    catalog = AntigravityCatalog(runtimeFor: runtimeFor);
  });

  test(
    'local startup discovery does not include queried SSH sessions',
    () async {
      await catalog.sessionsIn('ssh://alpha/work/app');
      final projects = await catalog.projects();
      expect(projects.single.path, '/work/app');
      expect(projects.single.sessions.single.id, 'same');
      expect(projects.single.sessions.single.title, 'local');
    },
  );

  test('identical working directories and IDs are isolated per host', () async {
    final a = await catalog.sessionsIn('ssh://alpha/work/app');
    final b = await catalog.sessionsIn('ssh://beta/work/app');
    expect(a.single.cwd, 'ssh://alpha/work/app');
    expect(b.single.cwd, 'ssh://beta/work/app');
    expect(a.single.id, 'agy-ssh:alpha:same');
    expect(b.single.id, 'agy-ssh:beta:same');
    expect(a.single.title, 'alpha');
    expect(a.single.path, isNull);
    expect(b.single.title, 'beta');
    expect(await catalog.sessionsIn('ssh://alpha/work/other'), isEmpty);
  });

  test('deleting a remote session changes only its host catalog', () async {
    final a = await catalog.sessionsIn('ssh://alpha/work/app');
    await catalog.sessionsIn('ssh://beta/work/app');
    await catalog.sessionsIn('/work/app');
    await catalog.delete(a.single.id);
    expect(await catalog.sessionsIn('ssh://alpha/work/app'), isEmpty);
    expect(
      (await catalog.sessionsIn('ssh://beta/work/app')).single.id,
      'agy-ssh:beta:same',
    );
    expect((await catalog.sessionsIn('/work/app')).single.id, 'same');
  });

  test('malformed remote keys never become local delete requests', () async {
    await expectLater(
      catalog.delete('agy-ssh:%XX:same'),
      throwsFormatException,
    );
    expect(local.ids, ['same']);
  });
}

class _SessionStore implements AgyRuntime {
  _SessionStore(this.name);

  final String name;
  final ids = ['same'];

  @override
  List<SessionRecord>? get lastSessions => null;

  @override
  Future<List<SessionRecord>> sessions() async => [
    for (final id in ids)
      SessionRecord(
        id: id,
        title: name,
        updatedAt: DateTime.utc(2026),
        cwd: '/work/app',
        path: '/home/user/.gemini/antigravity-cli/conversations/$id.db',
      ),
  ];

  @override
  Future<void> delete(String sessionId) async {
    if (!ids.remove(sessionId)) throw StateError('Unexpected ID: $sessionId');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
