// Security audit follow-up: a viewer never loads a huge received file whole.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/ui/viewers/file_viewer.dart';

void main() {
  test('readAll refuses files over the in-memory cap; readHead stays bounded', () async {
    final dir = Directory.systemTemp.createTempSync('lumora-viewer-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/big.txt');
    final raf = f.openSync(mode: FileMode.write)..truncateSync(3 * 1024 * 1024);
    raf.closeSync();
    final src = ViewerSource(f.path, 'big.txt');
    await expectLater(src.readAll(max: 1024 * 1024), throwsA(isA<FileSystemException>()));
    expect((await src.readAll()).length, 3 * 1024 * 1024);
    final (head, total) = await src.readHead(2 * 1024 * 1024);
    expect(head.length, 2 * 1024 * 1024);
    expect(total, 3 * 1024 * 1024);
    expect(ViewerSource.maxInMemory, lessThanOrEqualTo(64 * 1024 * 1024));
  });
}
