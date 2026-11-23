/// The desktop's session key, not the raw identifier used in ACP. Equal
/// identifiers on different hosts must never resolve to the same session.
const _sshSessionPrefix = 'agy-ssh:';

bool isAgySshSessionKey(String value) => value.startsWith(_sshSessionPrefix);

String agySessionKey(String? host, String id) => host == null
    ? id
    : '$_sshSessionPrefix${Uri.encodeComponent(host)}:${Uri.encodeComponent(id)}';

({String host, String id})? parseAgySessionKey(String value) {
  if (!isAgySshSessionKey(value)) return null;
  final encoded = value.substring(_sshSessionPrefix.length);
  final parts = encoded.split(':');
  if (parts.length != 2) return null;
  try {
    final host = Uri.decodeComponent(parts[0]);
    final id = Uri.decodeComponent(parts[1]);
    if (host.isEmpty ||
        host.contains('/') ||
        host.contains(RegExp(r'[\x00-\x20\x7f]')) ||
        id.isEmpty ||
        agySessionKey(host, id) != value) {
      return null;
    }
    return (host: host, id: id);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}
