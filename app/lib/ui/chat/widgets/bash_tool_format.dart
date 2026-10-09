// Pure model behind the bash tool card in Full mode. Mirrors the terminal and
// the web client (site/src/components/web/tool-output.ts) string for string:
//
//   $ <command>
//   <intent>            (muted, when args.i is set)
//   in <cwd>            (muted, when args.cwd is set)
//   Output
//   <body | (no output)>
//   Wall: 0.00s | Timeout: 300s | exit 127      (exit only when non-zero, red)
//
// The live `tool_result` frame and the replayed history event carry the same
// fields (`result` on success, `error` on failure), so both paths reach the
// card as one output string via [toolOutputText].

/// Bash tool text split into its body and the trailing status lines.
class BashOutput {
  /// Output with the trailing wall-time / exit-code lines removed.
  final String body;
  final double? wallSeconds;
  final int? exitCode;

  const BashOutput({required this.body, this.wallSeconds, this.exitCode});
}

final RegExp _wallLine = RegExp(r'^Wall time: (\d+(?:\.\d+)?) seconds$');
final RegExp _exitLine = RegExp(r'^Command exited with code (-?\d+)$');

/// Strips the trailing `Wall time: <x> seconds` and
/// `Command exited with code <n>` lines (and the blank lines around them)
/// from the bash tool text.
BashOutput parseBashOutput(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  double? wallSeconds;
  int? exitCode;
  while (true) {
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final last = lines.isEmpty ? '' : lines.last.trim();
    final wall = _wallLine.firstMatch(last);
    final exit = _exitLine.firstMatch(last);
    if (wall != null && wallSeconds == null) {
      wallSeconds = double.parse(wall.group(1)!);
    } else if (exit != null && exitCode == null) {
      exitCode = int.parse(exit.group(1)!);
    } else {
      break;
    }
    lines.removeLast();
  }
  return BashOutput(
    body: lines.join('\n'),
    wallSeconds: wallSeconds,
    exitCode: exitCode,
  );
}

/// `args.timeout` in seconds, when the call carried one.
num? bashTimeoutSeconds(Object? args) {
  if (args is! Map) return null;
  final raw = args['timeout'];
  final n = switch (raw) {
    final num v => v,
    final String s when s.trim().isNotEmpty => num.tryParse(s.trim()),
    _ => null,
  };
  return n != null && n.isFinite ? n : null;
}

/// Seconds the way JS prints a number: `300`, `1.5` (never `300.0`).
String _seconds(num n) =>
    n == n.truncate() ? n.truncate().toString() : n.toString();

class BashFooter {
  /// `Wall: 0.00s | Timeout: 300s`, or `Running…` while the call is pending.
  final String text;

  /// `exit 127` when the exit code is non-zero (rendered in the error color).
  final String? exit;

  const BashFooter({required this.text, this.exit});

  /// The footer as one line, e.g. `Wall: 0.00s | Timeout: 300s | exit 127`.
  String get line => [text, ?exit].where((s) => s.isNotEmpty).join(' | ');
}

/// [parsed] is null while the call is still running.
BashFooter bashFooter(BashOutput? parsed, num? timeoutSeconds) {
  if (parsed == null) return const BashFooter(text: 'Running…');
  final parts = <String>[
    if (parsed.wallSeconds case final wall?)
      'Wall: ${wall.toStringAsFixed(2)}s',
    if (timeoutSeconds != null) 'Timeout: ${_seconds(timeoutSeconds)}s',
  ];
  final code = parsed.exitCode;
  return BashFooter(
    text: parts.join(' | '),
    exit: code != null && code != 0 ? 'exit $code' : null,
  );
}

class BashCardView {
  final String command;
  final String? intent;
  final String? cwd;

  /// Null while the call is still running.
  final String? body;
  final BashFooter footer;

  const BashCardView({
    required this.command,
    this.intent,
    this.cwd,
    this.body,
    required this.footer,
  });
}

String? _argString(Object? args, String key) {
  if (args is! Map) return null;
  final v = args[key];
  return v is String && v.trim().isNotEmpty ? v : null;
}

/// Everything the bash Full card shows, from the call's args and its output
/// ([output] null = still running).
BashCardView bashCardView(Object? args, String? output) {
  final parsed = output == null ? null : parseBashOutput(output);
  return BashCardView(
    command: _argString(args, 'command') ?? _argString(args, 'cmd') ?? '',
    intent: _argString(args, 'i')?.trim(),
    cwd: _argString(args, 'cwd'),
    body: parsed == null
        ? null
        : (parsed.body.trim().isEmpty ? '(no output)' : parsed.body),
    footer: bashFooter(parsed, bashTimeoutSeconds(args)),
  );
}

/// One `tool_result` (live or history) → the text the card shows: the error
/// text on failure, else the result (strings verbatim, maps by their output
/// field, anything else stringified).
String toolOutputText(Object? result, String? error) {
  if (error != null) return error;
  return switch (result) {
    null => '',
    final String s => s,
    final Map m =>
      (m['output'] ?? m['stdout'] ?? m['result'] ?? m['data'] ?? m['error'] ??
              m['stderr'])
          ?.toString() ??
          m.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
    final List l => l.map((e) => e.toString()).join('\n'),
    _ => result.toString(),
  };
}
