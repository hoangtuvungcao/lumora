// Search that ignores case and Vietnamese diacritics (core/text_fold.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/text_fold.dart';

void main() {
  test('case and diacritics are folded', () {
    expect(foldText('Tiếng Việt'), 'tieng viet');
    expect(foldText('ĐẶNG Đức Đạt'), 'dang duc dat');
    expect(foldText('đ'), 'd');
    expect(foldText('Ơn Ưu Ẫ Ỷ'), 'on uu a y');
    expect(foldText('Café Ñandú'), 'cafe nandu');
    expect(foldText(''), '');
    // other scripts / digits / emoji untouched
    expect(foldText('Nhóm 12 🚀 東京'), 'nhom 12 🚀 東京');
  });

  test('decomposed (NFD) text folds like the precomposed spelling', () {
    // "Tiếng Việt" typed as base letters + combining marks
    const nfd = 'Tiếng Việt';
    expect(foldText(nfd), 'tieng viet');
    expect(foldText(nfd), foldText('Tiếng Việt'));
  });

  test('foldContains matches either way round', () {
    expect(foldContains('Tiếng Việt', 'tieng viet'), isTrue);
    expect(foldContains('tieng viet', 'Tiếng Việt'), isTrue);
    expect(foldContains('Đà Lạt', 'da lat'), isTrue);
    expect(foldContains('Đà Lạt', 'DA'), isTrue);
    expect(foldContains('Đà Lạt', 'Tiếng'), isFalse);
    expect(foldContains('Nhóm bạn', '  '), isTrue, reason: 'an empty query matches everything');
    expect(foldContains('Hà Nội', 'sai gon'), isFalse);
  });
}
