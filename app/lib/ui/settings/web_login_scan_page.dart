import 'dart:async';

import 'package:app/data/site/web_login.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Builds the live scanner; must call [onCode] with every decoded QR text.
/// Injectable so widget tests can feed codes without a camera.
typedef WebLoginScannerBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String> onCode,
);

/// Camera scanner, same `mobile_scanner` setup as the pairing flow. The
/// widget owns its controller, so unmounting it releases the camera.
Widget cameraWebLoginScanner(
  BuildContext context,
  ValueChanged<String> onCode,
) {
  return MobileScanner(
    onDetect: (capture) {
      final raw = capture.barcodes.firstOrNull?.rawValue;
      if (raw != null) onCode(raw);
    },
  );
}

enum _Phase { scanning, confirming, sending, failed }

/// Settings → "Sign in on web": scans the QR code shown on the website,
/// confirms, then hands the code to [onApprove], which encrypts and delivers
/// the Owner seed. Pops with `true` once the browser is signed in.
class WebLoginScanPage extends StatefulWidget {
  final Future<WebLoginResult> Function(WebLoginRequest request) onApprove;
  final WebLoginScannerBuilder scannerBuilder;

  const WebLoginScanPage({
    super.key,
    required this.onApprove,
    this.scannerBuilder = cameraWebLoginScanner,
  });

  @override
  State<WebLoginScanPage> createState() => _WebLoginScanPageState();
}

class _WebLoginScanPageState extends State<WebLoginScanPage> {
  _Phase _phase = _Phase.scanning;

  /// Why the last scanned code was rejected; the camera keeps scanning.
  String? _scanError;

  /// Why the last sign-in attempt failed (shown in [_Phase.failed]).
  String? _failure;

  void _onCode(String raw) {
    if (_phase != _Phase.scanning) return;
    final WebLoginRequest request;
    try {
      request = parseWebLoginCode(raw);
    } on WebLoginCodeException catch (e) {
      if (_scanError != e.message) setState(() => _scanError = e.message);
      return;
    }
    setState(() {
      _phase = _Phase.confirming;
      _scanError = null;
    });
    unawaited(_confirmAndSend(request));
  }

  Future<void> _confirmAndSend(WebLoginRequest request) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in on web'),
        content: Text(
          'Sign in the browser at ${request.host}? '
          'It gets full control of your PCs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (approved != true) {
      // Leaving rather than resuming: the same code is still in front of
      // the camera and would reopen the dialog at once.
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _phase = _Phase.sending);
    final WebLoginResult result;
    try {
      result = await widget.onApprove(request);
    } catch (_) {
      if (!mounted) return;
      _fail('Sign-in failed. Refresh the website and scan again.');
      return;
    }
    if (!mounted) return;
    switch (result) {
      case WebLoginDelivered():
        Navigator.of(context).pop(true);
      case WebLoginExpired():
        _fail('Code expired, refresh the website and scan again');
      case WebLoginAlreadyUsed():
        _fail('This code was already used. Refresh the website and scan '
            'again.');
      case WebLoginNetworkError():
        _fail('Network error. Check your connection and try again.');
      case WebLoginServerError(:final status):
        _fail('The website could not complete the sign-in'
            '${status == null ? '' : ' (HTTP $status)'}. Try again.');
      case WebLoginNoIdentity():
        _fail('Owner identity is unavailable. Retry after reopening the '
            'app.');
    }
  }

  void _fail(String message) {
    setState(() {
      _phase = _Phase.failed;
      _failure = message;
    });
  }

  void _scanAgain() {
    setState(() {
      _phase = _Phase.scanning;
      _failure = null;
      _scanError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        title: const Text('Scan the code on the website'),
      ),
      body: switch (_phase) {
        _Phase.scanning => _buildScanner(context),
        // Camera released while the dialog is up.
        _Phase.confirming => const SizedBox.expand(),
        _Phase.sending => Center(
            child: CircularProgressIndicator(color: colors.accent),
          ),
        _Phase.failed => _FailureView(
            message: _failure ?? '',
            onScanAgain: _scanAgain,
          ),
      },
    );
  }

  Widget _buildScanner(BuildContext context) {
    final colors = context.colors;
    final scanError = _scanError;
    return Stack(
      children: [
        Positioned.fill(child: widget.scannerBuilder(context, _onCode)),
        Center(
          child: Container(
            width: 268,
            height: 268,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.accent, width: 2),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (scanError != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.error),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.circleAlert,
                        color: colors.error,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          scanError,
                          style: TextStyle(color: colors.text, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                'Open $webLoginHost/web on your computer and point the '
                'camera at its QR code',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FailureView extends StatelessWidget {
  final String message;
  final VoidCallback onScanAgain;

  const _FailureView({required this.message, required this.onScanAgain});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.circleAlert, color: colors.error, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted2, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onScanAgain,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
              child: const Text('Scan again'),
            ),
          ],
        ),
      ),
    );
  }
}
