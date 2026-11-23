/// Google's Antigravity CLI update manifests, used by its official installer.
const agyUpdateFeed =
    'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests';

/// A project's path as agy lists it: URL-encoded (`Application%20Support`).
String agyPath(String path) {
  if (!RegExp('%[0-9A-Fa-f]{2}').hasMatch(path)) return path;
  try {
    return Uri.decodeFull(path);
  } on ArgumentError {
    return path;
  }
}
