import 'package:flutter/widgets.dart';

/// Minimum logical pixel width/height breakpoint for two-pane tablet mode.
const double kTabletBreakpoint = 600.0;

/// Returns `true` when the window is tablet-class (wide enough in either orientation).
///
/// Uses `shortestSide` (= `min(width, height)`) to avoid landscape phone false-positives.
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= kTabletBreakpoint;

/// Maximum content width for single-column layouts (onboarding, empty states).
const double kMaxContentWidth = 460.0;

/// Centers and limits [child] width on wide screens; passthrough on mobile.
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = kMaxContentWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Adaptive shell layout state. Manages `isZeroState` to collapse two-pane
/// layout into a single centered pane when no paired Pi exists.
/// Default `false` (two-pane split by default on wide screens).
class ShellLayout extends ChangeNotifier {
  bool _zeroState = false;
  bool get isZeroState => _zeroState;

  void setZeroState(bool value) {
    if (value == _zeroState) return;
    _zeroState = value;
    notifyListeners();
  }
}

/// Currently-selected session in the UI (chat shown in tablet detail pane
/// and highlighted in master list).
///
/// Starts `null` on boot so no chat is pre-selected until tapped.
class SessionSelection extends ChangeNotifier {
  ({String epk, String roomId, String title, String device, bool online})?
  _current;

  ({String epk, String roomId, String title, String device, bool online})?
  get current => _current;

  /// Returns `true` if `(epk, roomId)` is the currently selected session.
  bool matches(String epk, String roomId) {
    final c = _current;
    return c != null && c.epk == epk && c.roomId == roomId;
  }

  /// Plan/32g — `device` is the paired device name passed to `ChatPage.initialDevice`.
  /// `online` seeds the AppBar status dot to avoid reconnecting flashes during runtime boot.
  void select(
    String epk,
    String roomId,
    String title, [
    String device = '',
    bool online = false,
  ]) {
    final c = _current;
    if (c != null && c.epk == epk && c.roomId == roomId) {
      return; // no-op — evita rebuild do detail/master
    }
    _current = (
      epk: epk,
      roomId: roomId,
      title: title,
      device: device,
      online: online,
    );
    notifyListeners();
  }

  void clear() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}
