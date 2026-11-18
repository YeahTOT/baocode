import 'codex_process_transport_stub.dart'
    if (dart.library.io) 'codex_process_transport_io.dart'
    as platform;
import 'codex_transport.dart';

/// Connects to the local project's Codex app-server over JSONL stdio.
CodexTransport createCodexProcessTransport({required String cwd}) =>
    platform.createCodexProcessTransport(cwd: cwd);
