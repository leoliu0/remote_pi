import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Warning shown before the web sign-in link is revealed. Returns true only
/// when the user explicitly continues.
Future<bool> showWebSignInConfirmDialog(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: ctx.colors.surface,
      title: Text(
        'Sign in on web?',
        style: TextStyle(color: ctx.colors.text),
      ),
      content: Text(
        'This link gives full control of your PCs. '
        'Only open it on your own browser.',
        style: TextStyle(color: ctx.colors.muted2),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: ctx.colors.muted2)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Continue', style: TextStyle(color: ctx.colors.accent)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Bottom sheet presenting the web sign-in [link] as a QR code plus a
/// Copy action. The link is a secret: it is rendered, never logged.
Future<void> showWebSignInSheet(BuildContext context, {required String link}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.colors.bg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => WebSignInSheetBody(link: link),
  );
}

class WebSignInSheetBody extends StatefulWidget {
  final String link;
  const WebSignInSheetBody({super.key, required this.link});

  @override
  State<WebSignInSheetBody> createState() => _WebSignInSheetBodyState();
}

class _WebSignInSheetBodyState extends State<WebSignInSheetBody> {
  // Feedback stays inside the sheet: a SnackBar would render on the
  // Scaffold underneath the modal and never be seen.
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sign in on web',
              style: context.typo.sansBody.copyWith(
                color: colors.text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Scan with your computer's camera, or copy the link and open "
              'it in your own browser.',
              style: context.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Container(
                // QR readers need dark modules on a light quiet zone,
                // whatever the app theme.
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: widget.link,
                  size: 232,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                  semanticsLabel: 'Web sign-in QR code',
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _copy,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: Icon(
                _copied ? LucideIcons.check : LucideIcons.copy,
                size: 18,
              ),
              label: Text(_copied ? 'Link copied' : 'Copy link'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Done', style: TextStyle(color: colors.muted2)),
            ),
          ],
        ),
      ),
    );
  }
}
