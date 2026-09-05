/// Opens an external URL (browser / OS download).
abstract class UrlOpener {
  /// Opens [url]. Returns `true` on success, `false` otherwise.
  Future<bool> open(String url);
}
