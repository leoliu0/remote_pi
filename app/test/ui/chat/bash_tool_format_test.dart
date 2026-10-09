import 'package:app/ui/chat/widgets/bash_tool_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bashCardView (shared vectors with the web client)', () {
    test('command not found: body stripped, footer with timeout + exit', () {
      final view = bashCardView(
        const {'command': 'flutter test', 'timeout': 300},
        'error: command not found: flutter\n\n\nWall time: 0.00 seconds\n\n'
            'Command exited with code 127',
      );
      expect(view.command, 'flutter test');
      expect(view.body, 'error: command not found: flutter');
      expect(view.footer.text, 'Wall: 0.00s | Timeout: 300s');
      expect(view.footer.exit, 'exit 127');
      expect(view.footer.line, 'Wall: 0.00s | Timeout: 300s | exit 127');
    });

    test('(no output) with no timeout → wall only', () {
      final view = bashCardView(
        const {'command': 'sleep 15'},
        '(no output)\n\nWall time: 15.67 seconds',
      );
      expect(view.body, '(no output)');
      expect(view.footer.line, 'Wall: 15.67s');
      expect(view.footer.exit, isNull);
    });
  });

  group('parseBashOutput', () {
    test('keeps inner newlines and leading indentation of the body', () {
      final out = parseBashOutput('  a\n\nb\n\nWall time: 1.2 seconds\n');
      expect(out.body, '  a\n\nb');
      expect(out.wallSeconds, 1.2);
      expect(out.exitCode, isNull);
    });

    test('accepts the trailers in either order, each at most once', () {
      final out = parseBashOutput(
        'x\nCommand exited with code 2\n\nWall time: 3 seconds',
      );
      expect(out.body, 'x');
      expect(out.exitCode, 2);
      expect(out.wallSeconds, 3);

      final twice = parseBashOutput('Wall time: 1 seconds\nWall time: 2 seconds');
      expect(twice.body, 'Wall time: 1 seconds');
      expect(twice.wallSeconds, 2);
    });

    test('only trailing status lines are stripped', () {
      final out = parseBashOutput('Wall time: 9.00 seconds\nreal output');
      expect(out.body, 'Wall time: 9.00 seconds\nreal output');
      expect(out.wallSeconds, isNull);
    });

    test('CRLF output parses like LF', () {
      final out = parseBashOutput('ok\r\n\r\nWall time: 0.50 seconds\r\n');
      expect(out.body, 'ok');
      expect(out.wallSeconds, 0.5);
    });
  });

  group('footer / view edge cases', () {
    test('running → Running… and no body', () {
      final view = bashCardView(const {'command': 'ls', 'timeout': 30}, null);
      expect(view.body, isNull);
      expect(view.footer.line, 'Running…');
    });

    test('exit 0 is not shown; timeout without wall', () {
      final view = bashCardView(
        const {'command': 'true', 'timeout': '45'},
        'Command exited with code 0',
      );
      expect(view.body, '(no output)');
      expect(view.footer.line, 'Timeout: 45s');
    });

    test('exit without wall or timeout', () {
      final view = bashCardView(
        const {'command': 'false'},
        'Command exited with code 1',
      );
      expect(view.footer.text, '');
      expect(view.footer.line, 'exit 1');
    });

    test('fractional timeout prints like JS; integral double has no .0', () {
      expect(bashTimeoutSeconds(const {'timeout': 1.5}), 1.5);
      expect(
        bashCardView(const {'command': 'x', 'timeout': 300.0}, '').footer.line,
        'Timeout: 300s',
      );
      expect(
        bashCardView(const {'command': 'x', 'timeout': 1.5}, '').footer.line,
        'Timeout: 1.5s',
      );
    });

    test('intent and cwd come from args.i / args.cwd; blanks are dropped', () {
      final view = bashCardView(const {
        'command': 'git status\ngit log',
        'i': ' Checking repo ',
        'cwd': 'app',
      }, 'clean');
      expect(view.command, 'git status\ngit log');
      expect(view.intent, 'Checking repo');
      expect(view.cwd, 'app');

      final bare = bashCardView(const {'command': 'ls', 'i': '  ', 'cwd': ''}, '');
      expect(bare.intent, isNull);
      expect(bare.cwd, isNull);
    });
  });

  group('toolOutputText (live tool_result and history share it)', () {
    test('error wins over result', () {
      expect(toolOutputText('ignored', 'boom'), 'boom');
    });

    test('string verbatim, map by output field, null → empty', () {
      expect(toolOutputText('a\n\nWall time: 1 seconds', null),
          'a\n\nWall time: 1 seconds');
      expect(toolOutputText(const {'output': 'out'}, null), 'out');
      expect(toolOutputText(null, null), '');
    });
  });
}
