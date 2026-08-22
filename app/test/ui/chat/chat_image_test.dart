import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/chat_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// 1x1 transparent PNG base64.
const _kSamplePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const _kSampleDataUri = 'data:image/png;base64,$_kSamplePngBase64';

void main() {
  group('ChatImage', () {
    testWidgets('renders memory image from data URI', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatImage(
              url: _kSampleDataUri,
              altText: 'Sample diagram',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(LucideIcons.imageOff), findsNothing);
    });

    testWidgets('renders memory image from raw base64 payload', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatImage(
              url: _kSamplePngBase64,
              altText: 'Raw base64',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('renders fallback error widget on invalid image data', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatImage(
              url: 'data:image/png;base64,invalid!notbase64',
              altText: 'Failed diagram',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
      expect(find.text('Failed diagram'), findsOneWidget);
    });

    testWidgets('tapping image opens fullscreen viewer and close button dismisses it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatImage(
              url: _kSampleDataUri,
              altText: 'Architecture diagram',
            ),
          ),
        ),
      );
      await tester.pump();

      // Tap to open viewer
      await tester.tap(find.byType(ChatImage));
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerDialog), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('Architecture diagram'), findsOneWidget);

      // Tap close button
      await tester.tap(find.byKey(const Key('image-viewer-close')));
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerDialog), findsNothing);
    });
  });

  group('AgentMarkdown with images', () {
    testWidgets('renders markdown containing data URI image', (tester) async {
      const markdownWithImage =
          'Here is the generated output:\n\n![Generated chart]($_kSampleDataUri)\n\nEnd of response.';

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AgentMarkdown(markdownWithImage),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Here is the generated output:'), findsOneWidget);
      expect(find.byType(ChatImage), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
