import 'dart:async';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/chat/widgets/chat_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Strips `<think>...</think>`, `<thought>...</thought>`, and `<thinking>...</thinking>`
/// blocks from text in brief mode so reasoning traces are omitted.
/// For finalized text, it strictly removes closed blocks at block boundaries and
/// never truncates trailing content.
String stripThinkingTrace(String text, {bool isLiveStreaming = false}) {
  var cleaned = text.replaceAll(
    RegExp(
      r'^\s*<(?:think|thought|thinking)>[\s\S]*?<\/(?:think|thought|thinking)>\s*',
      caseSensitive: false,
    ),
    '',
  );
  cleaned = cleaned.replaceAll(
    RegExp(
      r'(?:^|\n)<(?:think|thought|thinking)>[\s\S]*?<\/(?:think|thought|thinking)>',
      caseSensitive: false,
    ),
    '',
  );
  if (isLiveStreaming) {
    // Drop an UNCLOSED think block wherever it starts — string start or after
    // a newline. The daemon now wraps streamed reasoning in <think> tags; a
    // block that opened after visible text must still hide while it grows.
    cleaned = cleaned.replaceAll(
      RegExp(r'(?:^|\n)\s*<(?:think|thought|thinking)>[\s\S]*$', caseSensitive: false),
      '',
    );
  }
  return cleaned.trim();
}

/// Plan/32b — renders the agent's Markdown reply (GFM + code) themed to the
/// app's dark/mono look. Uses standard Flutter Markdown parsing to prevent
/// text doubling or line wrapping bugs.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key, this.selectable = false});

  final String data;

  /// Wrap in a [SelectionArea] so prose/code can be selected + copied. Off for
  /// the streaming bubble (content changes every frame).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final baseMono = typo.mono.copyWith(
      fontSize: 15.0,
      height: 1.5,
      color: colors.text,
    );

    final styleSheet = MarkdownStyleSheet(
      p: baseMono,
      h1: baseMono.copyWith(fontSize: 22.0, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      h2: baseMono.copyWith(fontSize: 19.5, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      h3: baseMono.copyWith(fontSize: 17.5, fontWeight: FontWeight.w700),
      h4: baseMono.copyWith(fontSize: 16.5, fontWeight: FontWeight.w700),
      h5: baseMono.copyWith(fontSize: 15.5, fontWeight: FontWeight.w700),
      h6: baseMono.copyWith(fontSize: 15.0, fontWeight: FontWeight.w700),
      em: baseMono.copyWith(fontStyle: FontStyle.italic),
      strong: baseMono.copyWith(fontWeight: FontWeight.bold),
      code: baseMono.copyWith(
        fontSize: 14.0,
        color: colors.highlight,
        backgroundColor: colors.codeBg,
      ),
      codeblockDecoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      blockquote: baseMono.copyWith(color: colors.muted),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.accent, width: 3)),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      listBullet: baseMono.copyWith(color: colors.muted),
      tableBody: baseMono.copyWith(fontSize: 14.0),
      tableHead: baseMono.copyWith(fontSize: 14.0, fontWeight: FontWeight.bold),
      tableBorder: TableBorder.all(color: colors.border, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );

    final widget = MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      onTapLink: (text, href, title) {
        if (href != null) _openLink(context, href);
      },
      imageBuilder: (uri, title, alt) {
        return ChatImage(url: uri.toString());
      },
      builders: {
        'code': _CodeElementBuilder(context),
      },
    );

    return widget;
  }

  static Future<void> _openLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  }
}

class _CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  _CodeElementBuilder(this.context);

  @override
  Widget? visitElementAfter(mdElement, TextStyle? preferredStyle) {
    // Only intercept multiline fenced code blocks (<pre><code>...)
    final text = mdElement.textContent;
    if (mdElement.attributes['class'] != null || text.contains('\n')) {
      final language = mdElement.attributes['class']?.replaceFirst('language-', '') ?? '';
      return _CodeBlock(language: language, code: text.trimRight());
    }
    return null;
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: typo.monoSmall.copyWith(
                      fontSize: 10,
                      color: colors.muted,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                _CopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text(
              code,
              style: typo.mono.copyWith(color: colors.text, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      key: const Key('code-copy'),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      iconSize: 15,
      splashRadius: 16,
      tooltip: 'Copy code',
      onPressed: _copy,
      icon: Icon(
        _copied ? LucideIcons.check : LucideIcons.copy,
        color: _copied ? colors.success : colors.muted,
      ),
    );
  }
}
