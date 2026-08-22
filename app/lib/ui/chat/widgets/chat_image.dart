import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Decodes and renders images from Markdown responses or user messages.
///
/// Supports:
/// - Data URIs: `data:image/png;base64,...` / `data:image/jpeg;base64,...` / `data:image/...`
/// - Raw base64 image strings
/// - Network images: `https://...` / `http://...`
/// - Local file paths: `file:///...` / `/...`
///
/// Tapping the image opens an [ImageViewerDialog] with pinch-to-zoom and pan.
class ChatImage extends StatelessWidget {
  final String url;
  final String? altText;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool enableViewer;

  const ChatImage({
    super.key,
    required this.url,
    this.altText,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.enableViewer = true,
  });

  /// Parse the image payload into bytes (for data-uri or base64) or determine scheme.
  static Uint8List? tryDecodeBytes(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('data:')) {
      final commaIndex = trimmed.indexOf(',');
      if (commaIndex != -1) {
        final meta = trimmed.substring(0, commaIndex);
        final payload = trimmed.substring(commaIndex + 1).trim();
        if (meta.contains(';base64')) {
          try {
            // Clean up any potential url-encoding, newlines, or whitespace
            final cleaned = payload.replaceAll(RegExp(r'\s+'), '');
            return base64Decode(cleaned);
          } catch (_) {
            return null;
          }
        } else {
          // URL-encoded or plain string
          try {
            final unencoded = Uri.decodeComponent(payload);
            return Uint8List.fromList(utf8.encode(unencoded));
          } catch (_) {
            return null;
          }
        }
      }
    }

    // Check if it might be raw base64 (no data: scheme, at least 32 chars, only base64 charset)
    if (!trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://') &&
        !trimmed.startsWith('file://') &&
        !trimmed.startsWith('/') &&
        trimmed.length > 32 &&
        RegExp(r'^[A-Za-z0-9+/=_\-\s]+$').hasMatch(trimmed)) {
      try {
        final cleaned = trimmed.replaceAll(RegExp(r'\s+'), '');
        final bytes = base64Decode(cleaned);
        if (bytes.isNotEmpty) return bytes;
      } catch (_) {
        // Fall through
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final trimmedUrl = url.trim();
    final bytes = tryDecodeBytes(trimmedUrl);

    Widget imageWidget;
    ImageProvider? provider;

    if (bytes != null && bytes.isNotEmpty) {
      provider = MemoryImage(bytes);
      imageWidget = Image.memory(
        bytes,
        fit: fit,
        width: width,
        height: height,
        gaplessPlayback: true,
        errorBuilder: (ctx, err, stack) => _buildErrorWidget(context),
      );
    } else if (trimmedUrl.startsWith('http://') || trimmedUrl.startsWith('https://')) {
      provider = NetworkImage(trimmedUrl);
      imageWidget = Image.network(
        trimmedUrl,
        fit: fit,
        width: width,
        height: height,
        loadingBuilder: (ctx, child, progress) {
          if (progress == null) return child;
          final total = progress.expectedTotalBytes;
          final loaded = progress.cumulativeBytesLoaded;
          final value = total != null && total > 0 ? loaded / total : null;
          return Container(
            height: height ?? 160,
            width: width,
            alignment: Alignment.center,
            color: colors.codeBg,
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 2,
                color: colors.muted,
              ),
            ),
          );
        },
        errorBuilder: (ctx, err, stack) => _buildErrorWidget(context),
      );
    } else if (trimmedUrl.startsWith('file://') || trimmedUrl.startsWith('/')) {
      final filePath = trimmedUrl.startsWith('file://')
          ? trimmedUrl.substring(7)
          : trimmedUrl;
      final file = File(filePath);
      provider = FileImage(file);
      imageWidget = Image.file(
        file,
        fit: fit,
        width: width,
        height: height,
        errorBuilder: (ctx, err, stack) => _buildErrorWidget(context),
      );
    } else {
      imageWidget = _buildErrorWidget(context);
    }

    final constrained = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: height ?? 360,
        maxWidth: width ?? double.infinity,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border.withValues(alpha: 0.8)),
        ),
        clipBehavior: Clip.antiAlias,
        child: imageWidget,
      ),
    );

    if (!enableViewer || provider == null) {
      return constrained;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        showImageViewer(
          context,
          imageProvider: provider!,
          title: altText,
        );
      },
      child: constrained,
    );
  }

  Widget _buildErrorWidget(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final label = altText?.trim();
    return Container(
      height: 100,
      width: width ?? double.infinity,
      color: colors.codeBg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, color: colors.muted, size: 24),
          const SizedBox(height: 4),
          Text(
            label != null && label.isNotEmpty ? label : 'Image unavailable',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: typo.mono.copyWith(fontSize: 11, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// Opens a full-screen interactive image viewer dialog with zoom and pan.
void showImageViewer(
  BuildContext context, {
  required ImageProvider imageProvider,
  String? title,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (ctx) => ImageViewerDialog(
      imageProvider: imageProvider,
      title: title,
    ),
  );
}

/// Fullscreen zoomable image viewer dialog.
class ImageViewerDialog extends StatefulWidget {
  final ImageProvider imageProvider;
  final String? title;

  const ImageViewerDialog({
    super.key,
    required this.imageProvider,
    this.title,
  });

  @override
  State<ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<ImageViewerDialog> {
  final TransformationController _transformController =
      TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final titleText = widget.title?.trim();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Dismiss on tapping outside image when not zoomed
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
          ),
          // Interactive image
          Center(
            child: GestureDetector(
              onDoubleTap: _resetZoom,
              child: InteractiveViewer(
                transformationController: _transformController,
                minScale: 0.5,
                maxScale: 5.0,
                child: Image(
                  image: widget.imageProvider,
                  fit: BoxFit.contain,
                  errorBuilder: (ctx, err, stack) => Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.imageOff, color: colors.error, size: 36),
                        const SizedBox(height: 8),
                        Text(
                          'Failed to load image',
                          style: typo.mono.copyWith(color: colors.text),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Top bar: title + close button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    if (titleText != null && titleText.isNotEmpty)
                      Expanded(
                        child: Text(
                          titleText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.sansBody.copyWith(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    IconButton(
                      key: const Key('image-viewer-close'),
                      icon: const Icon(LucideIcons.x, color: Colors.white, size: 22),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
