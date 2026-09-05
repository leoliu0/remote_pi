import 'dart:async';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/chat/widgets/chat_image.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
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
/// app's dark/mono look. Links open in the system browser (url_launcher);
/// code blocks get a copy button. Tolerant of partial markdown so it can also
/// drive the live streaming bubble.
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

    final markdown = Theme(
      data: Theme.of(context).copyWith(
        extensions: [
          GptMarkdownThemeData(
            brightness: Theme.of(context).brightness,
            h1: baseMono.copyWith(
              fontSize: 22.0,
              fontWeight: FontWeight.w700,
              color: colors.text,
              letterSpacing: -0.2,
            ),
            h2: baseMono.copyWith(
              fontSize: 19.5,
              fontWeight: FontWeight.w700,
              color: colors.text,
              letterSpacing: -0.2,
            ),
            h3: baseMono.copyWith(
              fontSize: 17.5,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
            h4: baseMono.copyWith(
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
            h5: baseMono.copyWith(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
            h6: baseMono.copyWith(
              fontSize: 15.0,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
            highlightColor: colors.codeBg,
            linkColor: colors.accent,
            hrLineColor: colors.border,
          ),
        ],
        textTheme: Theme.of(context).textTheme.copyWith(
          headlineLarge: baseMono.copyWith(
            fontSize: 22.0,
            fontWeight: FontWeight.w700,
            color: colors.text,
            letterSpacing: -0.2,
          ),
          headlineMedium: baseMono.copyWith(
            fontSize: 19.5,
            fontWeight: FontWeight.w700,
            color: colors.text,
            letterSpacing: -0.2,
          ),
          headlineSmall: baseMono.copyWith(
            fontSize: 17.5,
            fontWeight: FontWeight.w700,
            color: colors.text,
          ),
          titleLarge: baseMono.copyWith(
            fontSize: 16.5,
            fontWeight: FontWeight.w700,
            color: colors.text,
          ),
          titleMedium: baseMono.copyWith(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: colors.text,
          ),
          titleSmall: baseMono.copyWith(
            fontSize: 15.0,
            fontWeight: FontWeight.w700,
            color: colors.text,
          ),
          bodyLarge: baseMono,
          bodyMedium: baseMono,
          bodySmall: baseMono.copyWith(fontSize: 13.0, color: colors.muted),
        ),
      ),
      child: GptMarkdown(
        data,
        style: baseMono,
        useDollarSignsForLatex: true,
        latexBuilder: (context, tex, textStyle, inline) {
          // If flutter_math fails or KaTeX font crashes on complex macros, render clean math text
          return Text(
            inline ? '\$$tex\$' : '\$\$\n$tex\n\$\$',
            style: textStyle.copyWith(
              fontFamily: 'CommitMono',
              fontStyle: FontStyle.italic,
              color: colors.accent,
            ),
          );
        },
        onLinkTap: (url, _) => _openLink(context, url),
        highlightBuilder: (context, text, style) => Text(
          text,
          style: baseMono.copyWith(
            fontSize: 14.0,
            color: colors.highlight,
            backgroundColor: colors.codeBg,
          ),
        ),
        // Fenced ``` blocks — dark card + copy button.
        codeBuilder: (context, name, code, closed) =>
            _CodeBlock(language: name, code: code),
        // Markdown images — supports data URIs, base64, files, network + zoom.
        imageBuilder: (context, url, width, height) => ChatImage(
          url: url,
          width: width,
          height: height,
        ),
      ),
    );
    return selectable ? SelectionArea(child: markdown) : markdown;
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
