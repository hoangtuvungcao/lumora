// Unit-level regression tests for the pre-release review (numbers = finding #).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/core/api.dart';
import 'package:lumora/core/ffi_api.dart';
import 'package:lumora/core/file_safety.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/ui/chats/composer.dart';
import 'package:lumora/ui/chats/message_bubble.dart';
import 'package:lumora/ui/media_editor/photo_io.dart';
import 'package:lumora/ui/widgets/common.dart';

Message _msg(String kind, String body, {bool mine = true}) => Message.fromJson({
      'id': 'm1',
      'conv': 'd:x',
      'author': mine ? 'me' : 'x',
      'mine': mine,
      'kind': kind,
      'body': body,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

Uint8List _jpegWithGps({int orientation = 6}) {
  final im = img.Image(width: 40, height: 30);
  im.exif.gpsIfd.gpsLatitudeRef = 'N';
  im.exif.gpsIfd.gpsLatitude = 21.0285;
  im.exif.gpsIfd.gpsLongitudeRef = 'E';
  im.exif.gpsIfd.gpsLongitude = 105.8542;
  im.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(im);
}

void main() {
  group('#6 file names from other people', () {
    test('only a clean base name survives (same rules as the core)', () {
      expect(sanitizeFileName('../../etc/passwd'), 'passwd');
      expect(sanitizeFileName(r'C:\x\a<b>.txt'), 'ab.txt');
      expect(sanitizeFileName('...'), 'file');
      expect(sanitizeFileName('..'), 'file');
      expect(sanitizeFileName(''), 'file');
      expect(sanitizeFileName('a\u0000b\u202Ec.txt'), 'abc.txt');
      expect(sanitizeFileName('CON.txt'), '_CON.txt');
      expect(sanitizeFileName('com1'), '_com1');
      expect(sanitizeFileName(' report. '), 'report');
      expect(sanitizeFileName('ảnh đẹp.png'), 'ảnh đẹp.png');
      final long = sanitizeFileName('${'x' * 300}.pdf');
      expect(utf8.encode(long).length, lessThanOrEqualTo(200));
      expect(long, endsWith('.pdf'));
    });

    test('the downloaded file\'s own name wins over the message\'s', () {
      expect(saveNameFor('../../evil.sh', path: '/dl/Lumora/report (1).pdf'), 'report (1).pdf');
      expect(saveNameFor('../../evil.sh'), 'evil.sh');
      expect(saveNameFor('a/b.txt', path: 'asset:x/y.txt'), 'b.txt');
    });
  });

  group('#7 saving never overwrites', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('lumora-save'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('existing names get (1), (2)…', () {
      File('${dir.path}/a.txt').writeAsStringSync('mine');
      final f1 = createUniqueFile(dir.path, 'a.txt');
      final f2 = createUniqueFile(dir.path, 'a.txt');
      expect(f1.path, endsWith('a (1).txt'));
      expect(f2.path, endsWith('a (2).txt'));
      expect(File('${dir.path}/a.txt').readAsStringSync(), 'mine');
    });

    test('a path-like name stays inside the folder', () {
      final f = createUniqueFile(dir.path, '../../escape.txt');
      expect(f.parent.path, dir.path);
      expect(f.path, endsWith('escape.txt'));
    });
  });

  group('#8 only text can be edited; copy gives words, not JSON', () {
    test('edit', () {
      expect(canEditMessage(_msg('text', 'hi')), isTrue);
      expect(canEditMessage(_msg('text', 'hi', mine: false)), isFalse);
      for (final k in ['voice', 'location', 'contact', 'sticker', 'call', 'file', 'poll', 'checklist', 'reminder']) {
        expect(canEditMessage(_msg(k, '{"a":1}')), isFalse, reason: k);
      }
    });

    test('copy', () {
      expect(copyableText(_msg('text', 'hello')), 'hello');
      final loc = copyableText(_msg('location', jsonEncode({'lat': 21.0285, 'lon': 105.8542, 'label': 'Hồ Gươm'})));
      expect(loc, 'Hồ Gươm (21.028500, 105.854200)');
      final card = copyableText(_msg('contact', jsonEncode({'peer': 'p', 'short_id': '123 456 789', 'name': 'Lan'})));
      expect(card, 'Lan (123 456 789)');
      expect(copyableText(_msg('voice', '{"dur":3}')), isNull);
      expect(copyableText(_msg('sticker', '{"h":"x"}')), isNull);
      expect(copyableText(_msg('call', '{"dur":3}')), isNull);
    });
  });

  group('#18 drafts survive editing', () {
    test('edit another message, then cancel → draft is back', () {
      final c = ComposerController();
      c.text.text = 'my unsent draft';
      c.edit(_msg('text', 'old message'));
      expect(c.text.text, 'old message');
      c.edit(_msg('text', 'another old one'));
      c.clearTarget();
      expect(c.text.text, 'my unsent draft');
      c.dispose();
    });

    test('editing a voice note is refused (and keeps the draft)', () {
      final c = ComposerController();
      c.text.text = 'draft';
      c.edit(_msg('voice', '{"dur":3}'));
      expect(c.editing, isNull);
      expect(c.text.text, 'draft');
      c.dispose();
    });
  });

  test('#15 a worker still blocked in the core is not picked again', () {
    final load = {'a': 1, 'b': 0, 'c': 2};
    expect(FfiLumoraApi.pickWorker(['a', 'b', 'c'], (w) => load[w]!), 'b');
    load['b'] = 3; // its call timed out in Dart but the native call still runs
    expect(FfiLumoraApi.pickWorker(['a', 'b', 'c'], (w) => load[w]!), 'a');
  });

  group('#19 photos the editor can\'t open still lose their metadata', () {
    test('JPEG with a rotation flag: forced strip removes GPS', () {
      final b = _jpegWithGps();
      expect(hasExif(b), isTrue);
      expect(stripMetadataLossless(b), isNull, reason: 'lossless path refuses (orientation)');
      final out = stripMetadataForced(b)!;
      expect(hasExif(out), isFalse);
      expect(img.decodeJpgExif(out)?.gpsIfd.hasGPSLatitude ?? false, isFalse);
      expect(img.decodeJpg(out)!.width, 40);
    });

    test('WebP: EXIF/XMP chunks dropped', () {
      Uint8List chunk(String t, List<int> data) {
        final h = ByteData(8)..setUint32(4, data.length, Endian.little);
        final b = h.buffer.asUint8List()..setRange(0, 4, ascii.encode(t));
        return Uint8List.fromList([...b, ...data, if (data.length.isOdd) 0]);
      }
      final vp8x = chunk('VP8X', List.filled(10, 0)..[0] = 0x0C);
      final body = [...vp8x, ...chunk('VP8 ', List.filled(12, 7)), ...chunk('EXIF', ascii.encode('GPS 21.0 105.8')), ...chunk('XMP ', ascii.encode('<x/>'))];
      final riff = ByteData(12)
        ..setUint32(0, 0x46464952, Endian.little)
        ..setUint32(4, body.length + 4, Endian.little)
        ..setUint32(8, 0x50424557, Endian.little);
      final webp = Uint8List.fromList([...riff.buffer.asUint8List(), ...body]);
      final out = stripMetadataForced(webp)!;
      final text = latin1.decode(out);
      expect(text.contains('EXIF'), isFalse);
      expect(text.contains('GPS'), isFalse);
      expect(text.contains('XMP '), isFalse);
      expect(out[20] & 0x0C, 0, reason: 'VP8X no longer announces EXIF/XMP');
      expect(ByteData.sublistView(out, 4, 8).getUint32(0, Endian.little), out.length - 8);
    });

    test('unknown formats are not passed off as clean', () {
      expect(stripMetadataForced(Uint8List.fromList(utf8.encode('....ftypheic....'))), isNull);
    });
  });

  test('#26 errors shown to people are plain words; raw text only as details', () {
    final s = S(true);
    const fs = FileSystemException('Cannot copy file', '/home/x/a.txt', OSError('No space left on device', 28));
    expect(errorMessage(s, fs, fallbackKey: 'viewer_save_failed'), s('viewer_save_failed'));
    expect(errorMessage(s, fs).contains('/home/x'), isFalse);
    expect(errorDetails(fs), contains('No space left'));
    expect(errorMessage(s, ApiException('timeout', cmd: 'send')), s('err_timeout'));
    expect(errorMessage(s, ApiException('Peer offline', code: 'err.restore_mismatch')), s('err_restore_mismatch'));
    expect(errorMessage(s, const UserMessageException('Ảnh này không mở được')), 'Ảnh này không mở được');
    expect(errorDetails(const UserMessageException('x')), isNull);
  });
}
