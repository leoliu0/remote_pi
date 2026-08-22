// Plan/30 — ImageBubble renders a static thumbnail from base64 + optional
// caption, with a broken-image fallback for bad data.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/chat/widgets/chat_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1×1 transparent PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  Future<void> pump(WidgetTester tester, MessageImage image, String caption) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ImageBubble(image: image, caption: caption),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the image and the caption', (tester) async {
    await pump(
      tester,
      const MessageImage(data: _png, mime: 'image/jpeg'),
      'a kitten',
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('a kitten'), findsOneWidget);
  });

  testWidgets('renders without a caption when empty', (tester) async {
    await pump(tester, const MessageImage(data: _png, mime: 'image/jpeg'), '');
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('falls back to a broken-image glyph on bad base64', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(data: 'not valid base64 !!', mime: 'image/jpeg'),
      '',
    );
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
  testWidgets('tapping image bubble opens fullscreen viewer', (tester) async {
    await pump(
      tester,
      const MessageImage(data: _png, mime: 'image/jpeg'),
      'a kitten',
    );
    await tester.pump();
    await tester.tap(find.byType(ImageBubble));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ImageViewerDialog),
        matching: find.text('a kitten'),
      ),
      findsOneWidget,
    );
  });
}
