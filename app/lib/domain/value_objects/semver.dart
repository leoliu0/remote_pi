/// Simple semver comparison `x.y.z` — numerical per component.
///
/// Ignores pre-release/build suffixes (`-beta`, `+1`).
library;

List<int> _parse(String v) {
  // Strip pre-release / build metadata after `-` or `+`.
  final core = v.trim().split(RegExp(r'[-+]')).first;
  final parts = core.split('.');
  return List<int>.generate(3, (i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i].trim()) ?? 0;
  });
}

/// Returns `-1` if [a] < [b], `0` if equal, `1` if [a] > [b].
int compareSemver(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

/// Returns `true` if [candidate] is newer than [current].
bool isNewerVersion(String candidate, String current) =>
    compareSemver(candidate, current) > 0;
