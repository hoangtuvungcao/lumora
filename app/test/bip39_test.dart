// The bundled BIP39 list and phrase helpers (lib/core/bip39.dart) agree with
// the official vectors and with the core (core/crates/lumora-core/src/bip39.rs).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/bip39.dart';
import 'package:lumora/core/mock_api.dart' show kMockRecoveryPhrase;

List<int> _hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

/// Official BIP39 vectors (trezor/python-mnemonic vectors.json, English, 256-bit).
const _vectors = {
  '0000000000000000000000000000000000000000000000000000000000000000':
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art',
  '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f':
      'legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title',
  'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff': 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote',
  '68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c':
      'hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length',
  'f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f':
      'void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold',
};

void main() {
  test('bundled list is the official English list', () {
    expect(bip39Words, hasLength(2048));
    final digest = sha256.convert(utf8.encode('${bip39Words.join('\n')}\n')).toString();
    expect(digest, '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda');
  });

  test('official vectors encode and check', () {
    _vectors.forEach((h, words) {
      expect(encodePhrase(_hex(h)), words);
      expect(checkPhraseWords(phraseTokens(words)).ok, isTrue);
    });
    expect(checkPhraseWords(phraseTokens(kMockRecoveryPhrase)).ok, isTrue, reason: 'mock phrase is valid');
  });

  test('lookup: exact words and 4-letter starts; suggestions', () {
    expect(bip39Word('ABAN'), 'abandon');
    expect(bip39Word('act'), 'act');
    expect(bip39Word('ab'), isNull);
    expect(bip39Word('abandonx'), isNull);
    expect(bip39IsPrefix('cag'), isTrue);
    expect(bip39IsPrefix('cagx'), isFalse);
    expect(bip39Suggest('ab'), ['abandon', 'ability', 'able', 'about']);
    expect(bip39Suggest('a'), isEmpty);
  });

  test('problems are reported in order: word, count, checksum', () {
    final w = phraseTokens(kMockRecoveryPhrase);
    final bad = [...w]..[6] = 'lumora';
    final c = checkPhraseWords(bad);
    expect(c.problem, PhraseProblem.word);
    expect(c.position, 7);
    expect(checkPhraseWords(w.take(12).toList()).problem, PhraseProblem.count);
    final swapped = [w[1], w[0], ...w.skip(2)];
    expect(checkPhraseWords(swapped).problem, PhraseProblem.checksum);
  });

  test('older-style codes are recognised and map to the same account', () {
    const legacy = 'aebag-bafay-dqqci-kbmga-2dqpc-airee-yucul-bogaz-dinry-hi6d4-qpbum-e';
    expect(looksLikeLegacyPhrase(legacy), isTrue);
    expect(looksLikeLegacyPhrase(legacy.replaceAll('-', ' ').toUpperCase()), isTrue);
    expect(looksLikeLegacyPhrase(legacy.replaceAll('-', '')), isTrue);
    expect(legacyPhraseComplete(legacy), isTrue);
    expect(legacyPhraseComplete(legacy.substring(0, 30)), isFalse);
    expect(looksLikeLegacyPhrase(kMockRecoveryPhrase), isFalse);
    // golden vector: secret 0x01…0x20 in both formats
    expect(phraseSecretKey(legacy), isNotNull);
    expect(phraseSecretKey(legacy), phraseSecretKey(kMockRecoveryPhrase));
    expect(phraseSecretKey(kMockRecoveryPhrase.toUpperCase().replaceAll(' ', '\n')), phraseSecretKey(kMockRecoveryPhrase));
    expect(phraseSecretKey('abandon ability'), isNull);
  });
}
