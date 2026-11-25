import 'package:baocode/kernel/antigravity/agy_remote_runtime.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final host in ['linux', 'wsl+Ubuntu']) {
    test('uses a Linux path for $host and keeps other hosts separate', () {
      final runtime = RemoteAgyRuntime(host);
      final location = RemoteLocation.of(host, '/home/user/a project');
      expect(runtime.pathOf(location), '/home/user/a project');
      expect(runtime.pathOf('/tmp'), '/tmp');
      expect(
        () => runtime.pathOf('ssh://other/home/user'),
        throwsArgumentError,
      );
      expect(() => runtime.pathOf('ssh://$host/C:/dev'), throwsArgumentError);
      expect(() => runtime.pathOf('relative'), throwsArgumentError);
    });
  }
}
