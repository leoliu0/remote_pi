import 'dart:convert';
import 'dart:io';

import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke: pump EVERY assistant text from the real NFP_CEO session
/// (selectable, exactly as ChatPage renders) — must complete quickly.
void main() {
  testWidgets('NFP_CEO real messages render without hanging', (tester) async {
    final file = File(
      '/home/leo/.omp/agent/sessions/-da-Dropbox-tony_leo-NFP_CEO/'
      '2026-09-12T05-43-59-330Z_01a09424-de62-75a0-819a-90f2d0e17b58.jsonl',
    );
    if (!file.existsSync()) {
      return; // machine-local fixture; nothing to smoke on CI
    }
    final texts = <String>[];
    for (final line in file.readAsLinesSync()) {
      if (!line.trim().startsWith('{')) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        final msg = j['message'] as Map<String, dynamic>?;
        if (msg != null && msg['role'] == 'assistant') {
          final content = msg['content'];
          if (content is List) {
            for (final part in content) {
              if (part is Map && part['type'] == 'text') {
                texts.add(part['text'] as String);
              }
            }
          }
        }
      } catch (_) {}
    }
    expect(texts, isNotEmpty);

    for (final t in texts) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AgentMarkdown(t, selectable: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
