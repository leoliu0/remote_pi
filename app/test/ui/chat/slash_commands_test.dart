import 'package:app/ui/chat/widgets/slash_commands.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('filterSlashCommands', () {
    test('returns empty list when input does not start with slash', () {
      expect(filterSlashCommands('hello'), isEmpty);
      expect(filterSlashCommands(''), isEmpty);
    });

    test('returns all commands when input is single slash', () {
      final all = filterSlashCommands('/');
      expect(all.length, kSlashCommands.length);
      expect(all.any((c) => c.name == 'init'), isTrue);
      expect(all.any((c) => c.name == 'compact'), isTrue);
      expect(all.any((c) => c.name == 'improve-writing'), isTrue);
    });

    test('filters commands by prefix or substring', () {
      final initMatches = filterSlashCommands('/in');
      expect(initMatches.any((c) => c.name == 'init'), isTrue);

      final writingMatches = filterSlashCommands('/writ');
      expect(writingMatches.any((c) => c.name == 'improve-writing'), isTrue);
    });

    test('returns empty when space is typed after command', () {
      expect(filterSlashCommands('/init project'), isEmpty);
      expect(filterSlashCommands('/model '), isEmpty);
    });
  });

  group('SlashCommandMenu widget', () {
    testWidgets('renders command list and triggers onSelect', (tester) async {
      SlashCommandItem? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashCommandMenu(
              items: const [
                SlashCommandItem(
                  name: 'init',
                  description: 'Initialize project configuration',
                ),
                SlashCommandItem(
                  name: 'compact',
                  description: 'Compact history',
                ),
              ],
              onSelect: (item) => selected = item,
            ),
          ),
        ),
      );

      expect(find.text('/init'), findsOneWidget);
      expect(find.text('/compact'), findsOneWidget);
      expect(find.text('Initialize project configuration'), findsOneWidget);

      await tester.tap(find.text('/init'));
      await tester.pump();

      expect(selected?.name, 'init');
    });
  });
}
