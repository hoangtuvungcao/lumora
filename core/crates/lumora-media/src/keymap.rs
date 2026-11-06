//! Mapping from W3C `KeyboardEvent.code` strings to native key codes.
//!
//! `code` identifies a *physical* key position (US-QWERTY naming), so it is layout
//! independent — exactly what remote-desktop input needs. Each entry carries:
//! * Linux evdev `KEY_*` code (also used for X11: X keycode = evdev + 8),
//! * Windows virtual-key code (+ whether the key needs `KEYEVENTF_EXTENDEDKEY`),
//! * macOS `kVK_*` virtual key code.

/// Marker for "no native equivalent".
pub const NONE: u16 = 0xFFFF;

/// One row of the key table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEntry {
    pub code: &'static str,
    pub evdev: u16,
    pub win_vk: u16,
    pub win_extended: bool,
    pub mac: u16,
}

macro_rules! k {
    ($code:literal, $ev:expr, $vk:expr, $ext:expr, $mac:expr) => {
        KeyEntry { code: $code, evdev: $ev, win_vk: $vk, win_extended: $ext, mac: $mac }
    };
}

/// The full table. Sorted by nothing in particular; lookups go through [`lookup`].
pub static KEYS: &[KeyEntry] = &[
    // Letters
    k!("KeyA", 30, 0x41, false, 0x00),
    k!("KeyB", 48, 0x42, false, 0x0B),
    k!("KeyC", 46, 0x43, false, 0x08),
    k!("KeyD", 32, 0x44, false, 0x02),
    k!("KeyE", 18, 0x45, false, 0x0E),
    k!("KeyF", 33, 0x46, false, 0x03),
    k!("KeyG", 34, 0x47, false, 0x05),
    k!("KeyH", 35, 0x48, false, 0x04),
    k!("KeyI", 23, 0x49, false, 0x22),
    k!("KeyJ", 36, 0x4A, false, 0x26),
    k!("KeyK", 37, 0x4B, false, 0x28),
    k!("KeyL", 38, 0x4C, false, 0x25),
    k!("KeyM", 50, 0x4D, false, 0x2E),
    k!("KeyN", 49, 0x4E, false, 0x2D),
    k!("KeyO", 24, 0x4F, false, 0x1F),
    k!("KeyP", 25, 0x50, false, 0x23),
    k!("KeyQ", 16, 0x51, false, 0x0C),
    k!("KeyR", 19, 0x52, false, 0x0F),
    k!("KeyS", 31, 0x53, false, 0x01),
    k!("KeyT", 20, 0x54, false, 0x11),
    k!("KeyU", 22, 0x55, false, 0x20),
    k!("KeyV", 47, 0x56, false, 0x09),
    k!("KeyW", 17, 0x57, false, 0x0D),
    k!("KeyX", 45, 0x58, false, 0x07),
    k!("KeyY", 21, 0x59, false, 0x10),
    k!("KeyZ", 44, 0x5A, false, 0x06),
    // Digit row
    k!("Digit1", 2, 0x31, false, 0x12),
    k!("Digit2", 3, 0x32, false, 0x13),
    k!("Digit3", 4, 0x33, false, 0x14),
    k!("Digit4", 5, 0x34, false, 0x15),
    k!("Digit5", 6, 0x35, false, 0x17),
    k!("Digit6", 7, 0x36, false, 0x16),
    k!("Digit7", 8, 0x37, false, 0x1A),
    k!("Digit8", 9, 0x38, false, 0x1C),
    k!("Digit9", 10, 0x39, false, 0x19),
    k!("Digit0", 11, 0x30, false, 0x1D),
    // Punctuation
    k!("Minus", 12, 0xBD, false, 0x1B),
    k!("Equal", 13, 0xBB, false, 0x18),
    k!("BracketLeft", 26, 0xDB, false, 0x21),
    k!("BracketRight", 27, 0xDD, false, 0x1E),
    k!("Backslash", 43, 0xDC, false, 0x2A),
    k!("Semicolon", 39, 0xBA, false, 0x29),
    k!("Quote", 40, 0xDE, false, 0x27),
    k!("Backquote", 41, 0xC0, false, 0x32),
    k!("Comma", 51, 0xBC, false, 0x2B),
    k!("Period", 52, 0xBE, false, 0x2F),
    k!("Slash", 53, 0xBF, false, 0x2C),
    k!("IntlBackslash", 86, 0xE2, false, 0x0A),
    k!("IntlRo", 89, 0xC1, false, 0x5E),
    k!("IntlYen", 124, 0xDC, false, 0x5D),
    // Whitespace / editing
    k!("Escape", 1, 0x1B, false, 0x35),
    k!("Backspace", 14, 0x08, false, 0x33),
    k!("Tab", 15, 0x09, false, 0x30),
    k!("Enter", 28, 0x0D, false, 0x24),
    k!("Space", 57, 0x20, false, 0x31),
    k!("CapsLock", 58, 0x14, false, 0x39),
    // Modifiers
    k!("ShiftLeft", 42, 0xA0, false, 0x38),
    k!("ShiftRight", 54, 0xA1, false, 0x3C),
    k!("ControlLeft", 29, 0xA2, false, 0x3B),
    k!("ControlRight", 97, 0xA3, true, 0x3E),
    k!("AltLeft", 56, 0xA4, false, 0x3A),
    k!("AltRight", 100, 0xA5, true, 0x3D),
    k!("MetaLeft", 125, 0x5B, true, 0x37),
    k!("MetaRight", 126, 0x5C, true, 0x36),
    k!("OSLeft", 125, 0x5B, true, 0x37),
    k!("OSRight", 126, 0x5C, true, 0x36),
    k!("ContextMenu", 127, 0x5D, true, 0x6E),
    // Function keys
    k!("F1", 59, 0x70, false, 0x7A),
    k!("F2", 60, 0x71, false, 0x78),
    k!("F3", 61, 0x72, false, 0x63),
    k!("F4", 62, 0x73, false, 0x76),
    k!("F5", 63, 0x74, false, 0x60),
    k!("F6", 64, 0x75, false, 0x61),
    k!("F7", 65, 0x76, false, 0x62),
    k!("F8", 66, 0x77, false, 0x64),
    k!("F9", 67, 0x78, false, 0x65),
    k!("F10", 68, 0x79, false, 0x6D),
    k!("F11", 87, 0x7A, false, 0x67),
    k!("F12", 88, 0x7B, false, 0x6F),
    k!("F13", 183, 0x7C, false, 0x69),
    k!("F14", 184, 0x7D, false, 0x6B),
    k!("F15", 185, 0x7E, false, 0x71),
    k!("F16", 186, 0x7F, false, 0x6A),
    k!("F17", 187, 0x80, false, 0x40),
    k!("F18", 188, 0x81, false, 0x4F),
    k!("F19", 189, 0x82, false, 0x50),
    k!("F20", 190, 0x83, false, 0x5A),
    k!("F21", 191, 0x84, false, NONE),
    k!("F22", 192, 0x85, false, NONE),
    k!("F23", 193, 0x86, false, NONE),
    k!("F24", 194, 0x87, false, NONE),
    // Navigation
    k!("PrintScreen", 99, 0x2C, true, NONE),
    k!("ScrollLock", 70, 0x91, false, NONE),
    k!("Pause", 119, 0x13, false, NONE),
    k!("Insert", 110, 0x2D, true, 0x72),
    k!("Home", 102, 0x24, true, 0x73),
    k!("PageUp", 104, 0x21, true, 0x74),
    k!("Delete", 111, 0x2E, true, 0x75),
    k!("End", 107, 0x23, true, 0x77),
    k!("PageDown", 109, 0x22, true, 0x79),
    k!("ArrowRight", 106, 0x27, true, 0x7C),
    k!("ArrowLeft", 105, 0x25, true, 0x7B),
    k!("ArrowDown", 108, 0x28, true, 0x7D),
    k!("ArrowUp", 103, 0x26, true, 0x7E),
    // Numpad
    k!("NumLock", 69, 0x90, true, 0x47),
    k!("NumpadDivide", 98, 0x6F, true, 0x4B),
    k!("NumpadMultiply", 55, 0x6A, false, 0x43),
    k!("NumpadSubtract", 74, 0x6D, false, 0x4E),
    k!("NumpadAdd", 78, 0x6B, false, 0x45),
    k!("NumpadEnter", 96, 0x0D, true, 0x4C),
    k!("NumpadDecimal", 83, 0x6E, false, 0x41),
    k!("NumpadEqual", 117, NONE, false, 0x51),
    k!("NumpadComma", 121, 0x6C, false, 0x5F),
    k!("Numpad0", 82, 0x60, false, 0x52),
    k!("Numpad1", 79, 0x61, false, 0x53),
    k!("Numpad2", 80, 0x62, false, 0x54),
    k!("Numpad3", 81, 0x63, false, 0x55),
    k!("Numpad4", 75, 0x64, false, 0x56),
    k!("Numpad5", 76, 0x65, false, 0x57),
    k!("Numpad6", 77, 0x66, false, 0x58),
    k!("Numpad7", 71, 0x67, false, 0x59),
    k!("Numpad8", 72, 0x68, false, 0x5B),
    k!("Numpad9", 73, 0x69, false, 0x5C),
    // Media
    k!("AudioVolumeMute", 113, 0xAD, true, 0x4A),
    k!("AudioVolumeDown", 114, 0xAE, true, 0x49),
    k!("AudioVolumeUp", 115, 0xAF, true, 0x48),
    k!("MediaTrackNext", 163, 0xB0, true, NONE),
    k!("MediaPlayPause", 164, 0xB3, true, NONE),
    k!("MediaTrackPrevious", 165, 0xB1, true, NONE),
    k!("MediaStop", 166, 0xB2, true, NONE),
    // Language keys (Korean/Japanese IMEs)
    k!("Lang1", 122, 0x15, false, 0x68),
    k!("Lang2", 123, 0x19, false, 0x66),
];

/// Look up a W3C `KeyboardEvent.code`. Also accepts the legacy Firefox names
/// `"VolumeMute"`, `"VolumeDown"`, `"VolumeUp"`.
pub fn lookup(code: &str) -> Option<&'static KeyEntry> {
    let code = match code {
        "VolumeMute" => "AudioVolumeMute",
        "VolumeDown" => "AudioVolumeDown",
        "VolumeUp" => "AudioVolumeUp",
        c => c,
    };
    KEYS.iter().find(|e| e.code == code)
}

/// Every evdev key code used by the table (deduplicated), for declaring the
/// capabilities of a virtual keyboard.
pub fn all_evdev_codes() -> Vec<u16> {
    let mut v: Vec<u16> = KEYS.iter().map(|e| e.evdev).filter(|&c| c != NONE).collect();
    v.sort_unstable();
    v.dedup();
    v
}

/// Map a printable ASCII character to the US-QWERTY key that produces it,
/// plus whether Shift must be held. Returns `None` for non-ASCII characters.
pub fn ascii_to_code(c: char) -> Option<(&'static str, bool)> {
    const LETTERS: [&str; 26] = [
        "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM",
        "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ",
    ];
    const DIGITS: [&str; 10] =
        ["Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9"];
    Some(match c {
        'a'..='z' => (LETTERS[(c as u8 - b'a') as usize], false),
        'A'..='Z' => (LETTERS[(c as u8 - b'A') as usize], true),
        '0'..='9' => (DIGITS[(c as u8 - b'0') as usize], false),
        ' ' => ("Space", false),
        '\n' | '\r' => ("Enter", false),
        '\t' => ("Tab", false),
        '!' => ("Digit1", true),
        '@' => ("Digit2", true),
        '#' => ("Digit3", true),
        '$' => ("Digit4", true),
        '%' => ("Digit5", true),
        '^' => ("Digit6", true),
        '&' => ("Digit7", true),
        '*' => ("Digit8", true),
        '(' => ("Digit9", true),
        ')' => ("Digit0", true),
        '-' => ("Minus", false),
        '_' => ("Minus", true),
        '=' => ("Equal", false),
        '+' => ("Equal", true),
        '[' => ("BracketLeft", false),
        '{' => ("BracketLeft", true),
        ']' => ("BracketRight", false),
        '}' => ("BracketRight", true),
        '\\' => ("Backslash", false),
        '|' => ("Backslash", true),
        ';' => ("Semicolon", false),
        ':' => ("Semicolon", true),
        '\'' => ("Quote", false),
        '"' => ("Quote", true),
        '`' => ("Backquote", false),
        '~' => ("Backquote", true),
        ',' => ("Comma", false),
        '<' => ("Comma", true),
        '.' => ("Period", false),
        '>' => ("Period", true),
        '/' => ("Slash", false),
        '?' => ("Slash", true),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_unique() {
        let mut names: Vec<_> = KEYS.iter().map(|e| e.code).collect();
        names.sort_unstable();
        let n = names.len();
        names.dedup();
        assert_eq!(n, names.len(), "duplicate W3C code in table");
    }

    #[test]
    fn spot_checks() {
        let a = lookup("KeyA").unwrap();
        assert_eq!((a.evdev, a.win_vk, a.mac), (30, 0x41, 0x00));
        let e = lookup("Enter").unwrap();
        assert_eq!((e.evdev, e.win_vk, e.mac), (28, 0x0D, 0x24));
        let l = lookup("ArrowLeft").unwrap();
        assert_eq!(l.evdev, 105);
        assert!(l.win_extended);
        assert_eq!(lookup("MetaLeft").unwrap().evdev, 125);
        assert_eq!(lookup("F12").unwrap().evdev, 88);
        assert_eq!(lookup("VolumeUp").unwrap().evdev, 115);
        assert!(lookup("NotAKey").is_none());
    }

    #[test]
    fn every_ascii_printable_maps_to_known_key() {
        for b in 0x20u8..0x7F {
            let c = b as char;
            let (code, _) = ascii_to_code(c).unwrap_or_else(|| panic!("no mapping for {c:?}"));
            assert!(lookup(code).is_some(), "{c:?} maps to unknown code {code}");
        }
        assert_eq!(ascii_to_code('A'), Some(("KeyA", true)));
        assert_eq!(ascii_to_code('?'), Some(("Slash", true)));
        assert_eq!(ascii_to_code('ế'), None);
    }

    #[test]
    fn evdev_codes_in_range() {
        for c in all_evdev_codes() {
            assert!(c > 0 && c < 0x2ff);
        }
    }
}
