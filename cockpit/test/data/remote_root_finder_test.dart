import 'dart:convert';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/data/remote/remote_root_finder.dart';
import 'package:cockpit_core/cockpit_core.dart' show FileEntry, FileService;
import 'package:flutter_test/flutter_test.dart';

/// Filesystem remoto de mentira: mapa de pasta → entradas, e de arquivo →
/// conteúdo. Pasta ausente lança, como o servidor real faria.
class _FakeFs implements FileService {
  _FakeFs(this.dirs, [this.files = const {}]);

  final Map<String, List<String>> dirs;
  final Map<String, String> files;

  int listCalls = 0;

  @override
  Future<List<FileEntry>> list(String path) async {
    listCalls++;
    final entries = dirs[path];
    if (entries == null) throw StateError('not found: $path');
    return [
      for (final e in entries)
        FileEntry(name: e, isDirectory: !e.contains('.') || e == '.git'),
    ];
  }

  @override
  Future<Uint8List> read(String path, {int maxBytes = 8 * 1024 * 1024}) async {
    final content = files[path];
    if (content == null) throw StateError('not a file: $path');
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  Future<String> home() async => '/home/jacob';

  @override
  Future<void> write(String path, Uint8List bytes) async {}
}

void main() {
  test('pasta com .git é single-root (monorepo)', () async {
    final fs = _FakeFs({
      '/srv/mono': ['.git', 'lib', 'test'],
    });
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/mono'), ['/srv/mono']);
  });

  test('filhas com .git viram roots (multirepo), ordenadas', () async {
    final fs = _FakeFs({
      '/srv/multi': ['web', 'api', 'docs'],
      '/srv/multi/web': ['.git', 'src'],
      '/srv/multi/api': ['.git', 'src'],
      '/srv/multi/docs': ['index'],
    });
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/multi'), [
      '/srv/multi/api',
      '/srv/multi/web',
    ]);
  });

  test('pasta sem git nenhum devolve ela mesma', () async {
    final fs = _FakeFs({
      '/srv/plain': ['a', 'b'],
      '/srv/plain/a': ['x'],
      '/srv/plain/b': ['y'],
    });
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/plain'), [
      '/srv/plain',
    ]);
  });

  test('worktree linkada de irmã não vira root', () async {
    final fs = _FakeFs(
      {
        '/srv/ws': ['app', 'app-fix'],
        '/srv/ws/app': ['.git'],
        '/srv/ws/app-fix': ['.git'],
      },
      {'/srv/ws/app-fix/.git': 'gitdir: /srv/ws/app/.git/worktrees/app-fix\n'},
    );
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/ws'), ['/srv/ws/app']);
  });

  test('worktree de repo de FORA do workspace continua sendo root', () async {
    final fs = _FakeFs(
      {
        '/srv/ws': ['app', 'outside-fix'],
        '/srv/ws/app': ['.git'],
        '/srv/ws/outside-fix': ['.git'],
      },
      {
        '/srv/ws/outside-fix/.git':
            'gitdir: /elsewhere/other/.git/worktrees/fix\n',
      },
    );
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/ws'), [
      '/srv/ws/app',
      '/srv/ws/outside-fix',
    ]);
  });

  test('pasta ilegível (host offline) degrada para single-root', () async {
    final fs = _FakeFs(const {});
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/gone'), ['/srv/gone']);
  });

  test('ignora ocultas e barra pasta com filhas demais', () async {
    final many = [for (var i = 0; i < 80; i++) 'p$i'];
    final fs = _FakeFs({
      '/srv/home': [...many, '.cache'],
      for (final p in many) '/srv/home/$p': ['.git'],
    });
    final finder = RemoteRootFinder(fs);
    expect(await finder.deriveRoots('/srv/home'), ['/srv/home']);
    // Barrou antes de inspecionar as filhas: só a listagem da raiz e o teste
    // de `.git` da própria pasta.
    expect(fs.listCalls, lessThanOrEqualTo(2));
  });

  test('barra final não muda o resultado', () async {
    final fs = _FakeFs({
      '/srv/mono': ['.git'],
    });
    expect(await RemoteRootFinder(fs).deriveRoots('/srv/mono/'), ['/srv/mono']);
  });
}
