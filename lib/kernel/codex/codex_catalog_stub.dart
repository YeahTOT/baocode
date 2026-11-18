import '../agent_kernel.dart';

class CodexCatalog implements SessionCatalog {
  const CodexCatalog({String? directory});

  Future<void> remember(SessionRecord record) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<ProjectRecord>> projects() async => const [];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];
}
