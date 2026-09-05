import 'dart:async';
import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/states/settings_state.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/settings/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

class SettingsPage extends StatelessWidget {
  /// Plan/tablet — `true` when presented as a modal bottom sheet (tablet)
  /// rather than a pushed full-screen route (phone). Swaps the back arrow
  /// for a close (X), since the sheet is dismissed, not popped to a parent.
  final bool embedded;

  const SettingsPage({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SettingsViewModel>();
    final state = vm.state;
    final colors = context.colors;

    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(
            embedded ? LucideIcons.x : LucideIcons.chevronLeft,
            size: embedded ? 22 : 18,
            color: colors.text,
          ),
          tooltip: embedded ? 'Close' : 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(color: colors.border, height: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _DisplaySection(),
          Divider(color: colors.border, height: 1),
          const _RelaySection(),
          Divider(color: colors.border, height: 1),
          const _SectionHeader('Pairings'),
          switch (state) {
            SettingsLoading() => Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: CircularProgressIndicator(color: colors.accent),
              ),
            ),
            SettingsNoPeer() => const _EmptyState(),
            SettingsList(:final peers) => _PeerList(
              peers: peers,
              onRevoke: vm.revoke,
              onSetNickname: vm.setNickname,
            ),
          },
          // Plan-17 follow-up — entry point to pair an additional Pi.
          // The flow itself lives at /pair and survives whatever
          // peers/rooms already exist (PairingViewModel handles the
          // add path the same way as the first pair).
          const _AddPairingButton(),
          const _VersionFooter(),
        ],
      ),
    );
  }
}

class _AddPairingButton extends StatelessWidget {
  const _AddPairingButton();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      child: OutlinedButton.icon(
        onPressed: () => context.push('/pair'),
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.accent,
          side: BorderSide(color: colors.border),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
          minimumSize: const Size.fromHeight(0),
        ),
        icon: const Icon(LucideIcons.scanQrCode, size: 18),
        label: Text(
          'Add new pairing',
          style: const TextStyle(fontFamily: kMonoFamily, fontSize: 13),
        ),
      ),
    );
  }
}

class _RelaySection extends StatefulWidget {
  const _RelaySection();
  @override
  State<_RelaySection> createState() => _RelaySectionState();
}

class _RelaySectionState extends State<_RelaySection>
    with WidgetsBindingObserver {
  late final SettingsViewModel _vm;
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  late final String _initial;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vm = context.read<SettingsViewModel>();
    _initial = _vm.relayUrlOverride;
    _ctrl = TextEditingController(text: _initial);
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_save(silent: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_save(silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final text = _ctrl.text;
    if (text.trim() != _initial.trim()) {
      unawaited(_vm.saveRelayUrl(text));
    }
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save({bool silent = false}) async {
    if (silent && _ctrl.text.trim() == _initial.trim()) return;
    final err = await _vm.saveRelayUrl(
      _ctrl.text,
      alwaysReconnect: !silent,
    );
    if (!mounted) return;
    setState(() => _error = err);
    if (silent || err != null) return;
    _ctrl.text = _vm.effectiveRelayUrl;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Relay updated',
          style: TextStyle(fontFamily: kMonoFamily),
        ),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SettingsViewModel>();
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Relay'),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_save()),
                style: context.typo.mono.copyWith(
                  fontSize: 13,
                  color: colors.text,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'https://my-relay.example.com',
                  hintStyle: context.typo.mono.copyWith(
                    color: colors.muted,
                    fontSize: 12,
                  ),
                  helperText: 'Current: ${vm.effectiveRelayUrl}',
                  helperStyle: context.typo.mono.copyWith(
                    fontSize: 10,
                    color: colors.muted,
                  ),
                  errorText: _error,
                  errorStyle: context.typo.mono.copyWith(
                    fontSize: 10,
                    color: colors.error,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colors.accent),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () => unawaited(_save()),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accent,
                        foregroundColor: colors.onAccent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                        ),
                      ),
                      child: Text(
                        'Save',
                        style: TextStyle(
                          fontFamily:
                              context.typo.mono.fontFamily ?? kMonoFamily,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: () async {
                        _ctrl.text = kDefaultRelayUrl;
                        final messenger = ScaffoldMessenger.of(context);
                        await vm.saveRelayUrl(
                          null,
                          alwaysReconnect: true,
                        );
                        if (!mounted) return;
                        setState(() => _error = null);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Relay reset to default',
                              style: TextStyle(fontFamily: kMonoFamily),
                            ),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Text(
                        'Use default Relay',
                        style: TextStyle(
                          fontFamily:
                              context.typo.mono.fontFamily ?? kMonoFamily,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DisplaySection extends StatelessWidget {
  const _DisplaySection();

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Display'),
        // Theme mode — System follows the OS; Light / Dark pin it.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Theme',
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {prefs.themeMode},
                  onSelectionChanged: (s) => prefs.setThemeMode(s.first),
                ),
              ),
            ],
          ),
        ),
        // Font family — selectable coding/system font family.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Font family',
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: colors.codeBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AppFontFamily>(
                    isExpanded: true,
                    dropdownColor: colors.surface,
                    value: prefs.fontFamily,
                    icon: Icon(
                      LucideIcons.chevronDown,
                      size: 18,
                      color: colors.muted,
                    ),
                    items: [
                      for (final font in AppFontFamily.values)
                        DropdownMenuItem(
                          value: font,
                          child: Text(
                            font.label,
                            style: font.textStyle(
                              fontSize: 13.5,
                              color: colors.text,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (f) {
                      if (f != null) prefs.setFontFamily(f);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        // Text size — the app hardcodes its font sizes and Flutter can't read
        // iOS's per-app Text Size, so without this the only way to enlarge chat
        // text is the OS-wide accessibility setting (issue #114).
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Text size',
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppFontScale>(
                  showSelectedIcon: false,
                  segments: [
                    for (final scale in AppFontScale.values)
                      ButtonSegment(value: scale, label: Text(scale.label)),
                  ],
                  selected: {prefs.fontScale},
                  onSelectionChanged: (s) => prefs.setFontScale(s.first),
                ),
              ),
            ],
          ),
        ),
        // Tool calls display mode in chat: Full, Brief, or Hidden.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tool calls in chat',
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
              const SizedBox(height: 4),
              Text(
                'Full shows entire code blocks; Brief shows compact expandable pills; Hidden hides tools.',
                style: context.typo.sansBody.copyWith(
                  color: colors.muted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ToolCallDisplay>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ToolCallDisplay.full,
                      label: Text('Full'),
                    ),
                    ButtonSegment(
                      value: ToolCallDisplay.brief,
                      label: Text('Brief'),
                    ),
                    ButtonSegment(
                      value: ToolCallDisplay.hidden,
                      label: Text('Hidden'),
                    ),
                  ],
                  selected: {prefs.toolCallDisplay},
                  onSelectionChanged: (s) => prefs.setToolCallDisplay(s.first),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.colors.muted,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.monitorSmartphone, color: colors.muted, size: 40),
          const SizedBox(height: 12),
          Text(
            'No pairings yet',
            style: TextStyle(color: colors.muted2, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap + to pair a new Mac.',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => context.push('/pair'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
            ),
            icon: const Icon(LucideIcons.scanQrCode, size: 18),
            label: const Text('Scan QR'),
          ),
        ],
      ),
    );
  }
}

class _PeerList extends StatelessWidget {
  final List<PeerRecord> peers;
  final Future<void> Function(String epk) onRevoke;
  final Future<void> Function(String epk, String? nickname) onSetNickname;

  const _PeerList({
    required this.peers,
    required this.onRevoke,
    required this.onSetNickname,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final peer in peers)
          PeerListItem(
            peer: peer,
            onEditNickname: () => _editNickname(context, peer),
            onRevokeRequested: () async {
              final confirmed = await showRevokeConfirmDialog(
                context,
                peer: peer,
              );
              if (!confirmed) return false;
              await onRevoke(peer.remoteEpk);
              return true;
            },
          ),
      ],
    );
  }

  Future<void> _editNickname(BuildContext context, PeerRecord peer) async {
    final result = await showNicknameEditor(
      context,
      defaultName: peer.sessionName,
      currentNickname: peer.nickname ?? '',
    );
    if (result == null) return; // canceled
    await onSetNickname(peer.remoteEpk, result.isEmpty ? null : result);
  }
}

/// Build identity footer — makes "which APK is actually installed"
/// verifiable on-device (the 1.2.4+12 versionCode collision meant
/// reinstalls silently kept the old build).
class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              'Remote Pi ${info.version} (${info.buildNumber})',
              style: context.typo.mono.copyWith(
                fontSize: 10,
                color: colors.muted2,
              ),
            ),
          ),
        );
      },
    );
  }
}
