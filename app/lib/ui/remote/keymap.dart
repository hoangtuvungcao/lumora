import 'package:flutter/services.dart';

/// Maps Flutter physical keys to W3C `KeyboardEvent.code` names.
final Map<PhysicalKeyboardKey, String> kW3cCodes = () {
  final m = <PhysicalKeyboardKey, String>{};
  const letters = [
    PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.keyB, PhysicalKeyboardKey.keyC, PhysicalKeyboardKey.keyD,
    PhysicalKeyboardKey.keyE, PhysicalKeyboardKey.keyF, PhysicalKeyboardKey.keyG, PhysicalKeyboardKey.keyH,
    PhysicalKeyboardKey.keyI, PhysicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyK, PhysicalKeyboardKey.keyL,
    PhysicalKeyboardKey.keyM, PhysicalKeyboardKey.keyN, PhysicalKeyboardKey.keyO, PhysicalKeyboardKey.keyP,
    PhysicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyR, PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.keyT,
    PhysicalKeyboardKey.keyU, PhysicalKeyboardKey.keyV, PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.keyX,
    PhysicalKeyboardKey.keyY, PhysicalKeyboardKey.keyZ,
  ];
  for (var i = 0; i < letters.length; i++) {
    m[letters[i]] = 'Key${String.fromCharCode(65 + i)}';
  }
  const digits = [
    PhysicalKeyboardKey.digit0, PhysicalKeyboardKey.digit1, PhysicalKeyboardKey.digit2, PhysicalKeyboardKey.digit3,
    PhysicalKeyboardKey.digit4, PhysicalKeyboardKey.digit5, PhysicalKeyboardKey.digit6, PhysicalKeyboardKey.digit7,
    PhysicalKeyboardKey.digit8, PhysicalKeyboardKey.digit9,
  ];
  for (var i = 0; i < 10; i++) {
    m[digits[i]] = 'Digit$i';
  }
  const fkeys = [
    PhysicalKeyboardKey.f1, PhysicalKeyboardKey.f2, PhysicalKeyboardKey.f3, PhysicalKeyboardKey.f4,
    PhysicalKeyboardKey.f5, PhysicalKeyboardKey.f6, PhysicalKeyboardKey.f7, PhysicalKeyboardKey.f8,
    PhysicalKeyboardKey.f9, PhysicalKeyboardKey.f10, PhysicalKeyboardKey.f11, PhysicalKeyboardKey.f12,
  ];
  for (var i = 0; i < 12; i++) {
    m[fkeys[i]] = 'F${i + 1}';
  }
  const numpad = [
    PhysicalKeyboardKey.numpad0, PhysicalKeyboardKey.numpad1, PhysicalKeyboardKey.numpad2, PhysicalKeyboardKey.numpad3,
    PhysicalKeyboardKey.numpad4, PhysicalKeyboardKey.numpad5, PhysicalKeyboardKey.numpad6, PhysicalKeyboardKey.numpad7,
    PhysicalKeyboardKey.numpad8, PhysicalKeyboardKey.numpad9,
  ];
  for (var i = 0; i < 10; i++) {
    m[numpad[i]] = 'Numpad$i';
  }
  m.addAll({
    PhysicalKeyboardKey.enter: 'Enter',
    PhysicalKeyboardKey.escape: 'Escape',
    PhysicalKeyboardKey.backspace: 'Backspace',
    PhysicalKeyboardKey.tab: 'Tab',
    PhysicalKeyboardKey.space: 'Space',
    PhysicalKeyboardKey.minus: 'Minus',
    PhysicalKeyboardKey.equal: 'Equal',
    PhysicalKeyboardKey.bracketLeft: 'BracketLeft',
    PhysicalKeyboardKey.bracketRight: 'BracketRight',
    PhysicalKeyboardKey.backslash: 'Backslash',
    PhysicalKeyboardKey.semicolon: 'Semicolon',
    PhysicalKeyboardKey.quote: 'Quote',
    PhysicalKeyboardKey.backquote: 'Backquote',
    PhysicalKeyboardKey.comma: 'Comma',
    PhysicalKeyboardKey.period: 'Period',
    PhysicalKeyboardKey.slash: 'Slash',
    PhysicalKeyboardKey.capsLock: 'CapsLock',
    PhysicalKeyboardKey.printScreen: 'PrintScreen',
    PhysicalKeyboardKey.scrollLock: 'ScrollLock',
    PhysicalKeyboardKey.pause: 'Pause',
    PhysicalKeyboardKey.insert: 'Insert',
    PhysicalKeyboardKey.home: 'Home',
    PhysicalKeyboardKey.pageUp: 'PageUp',
    PhysicalKeyboardKey.delete: 'Delete',
    PhysicalKeyboardKey.end: 'End',
    PhysicalKeyboardKey.pageDown: 'PageDown',
    PhysicalKeyboardKey.arrowRight: 'ArrowRight',
    PhysicalKeyboardKey.arrowLeft: 'ArrowLeft',
    PhysicalKeyboardKey.arrowDown: 'ArrowDown',
    PhysicalKeyboardKey.arrowUp: 'ArrowUp',
    PhysicalKeyboardKey.numLock: 'NumLock',
    PhysicalKeyboardKey.numpadDivide: 'NumpadDivide',
    PhysicalKeyboardKey.numpadMultiply: 'NumpadMultiply',
    PhysicalKeyboardKey.numpadSubtract: 'NumpadSubtract',
    PhysicalKeyboardKey.numpadAdd: 'NumpadAdd',
    PhysicalKeyboardKey.numpadEnter: 'NumpadEnter',
    PhysicalKeyboardKey.numpadDecimal: 'NumpadDecimal',
    PhysicalKeyboardKey.contextMenu: 'ContextMenu',
    PhysicalKeyboardKey.controlLeft: 'ControlLeft',
    PhysicalKeyboardKey.shiftLeft: 'ShiftLeft',
    PhysicalKeyboardKey.altLeft: 'AltLeft',
    PhysicalKeyboardKey.metaLeft: 'MetaLeft',
    PhysicalKeyboardKey.controlRight: 'ControlRight',
    PhysicalKeyboardKey.shiftRight: 'ShiftRight',
    PhysicalKeyboardKey.altRight: 'AltRight',
    PhysicalKeyboardKey.metaRight: 'MetaRight',
  });
  return m;
}();
