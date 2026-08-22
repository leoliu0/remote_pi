import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/chat/widgets/chat_image.dart';
import 'package:flutter/material.dart';

/// Plan/30 — static image thumbnail + optional caption inside the user
/// bubble (decision #7: no full-screen, no tap/zoom). Renders straight from
/// the inline base64 ([MessageImage.data]); the bytes are decoded once so
/// list scrolling doesn't re-decode every frame.
class ImageBubble extends StatefulWidget {
  const ImageBubble({
    super.key,
    required this.image,
    this.caption = '',
    this.isFailed = false,
  });

  final MessageImage image;
  final String caption;
  final bool isFailed;

  /// Cap the thumbnail height; the width follows the bubble's 300px max.
  static const double maxHeight = 220;

  @override
  State<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<ImageBubble> {
  late Uint8List _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _decode(widget.image.data);
  }

  @override
  void didUpdateWidget(ImageBubble old) {
    super.didUpdateWidget(old);
    if (old.image.data != widget.image.data) {
      _bytes = _decode(widget.image.data);
    }
  }

  static Uint8List _decode(String data) {
    try {
      return base64Decode(data);
    } catch (_) {
      return Uint8List(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption.trim();
    final colors = context.colors;
    final bubble = Container(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(12),
        border: widget.isFailed
            ? Border.all(color: colors.error, width: 1)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: ImageBubble.maxHeight),
            child: _bytes.isEmpty
                ? _broken(context)
                : SizedBox(
                    width: double.infinity,
                    child: Image.memory(
                      _bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              child: Text(
                caption,
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
            ),
        ],
      ),
    );

    if (_bytes.isEmpty) return bubble;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        showImageViewer(
          context,
          imageProvider: MemoryImage(_bytes),
          title: caption.isNotEmpty ? caption : null,
        );
      },
      child: bubble,
    );
  }

  Widget _broken(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 120,
      color: colors.codeBg,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, color: colors.muted, size: 28),
    );
  }
}
