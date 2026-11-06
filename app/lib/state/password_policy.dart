// Password rules for the data password and backup-file passwords. Both can
// be attacked offline (a copied data folder or backup file), so length alone
// is not enough: the most common passwords and trivial patterns are refused
// too (OWASP ASVS 2.1: at least 8 characters, checked against common
// passwords, no composition rules).

/// Minimum length (characters) for new passwords.
const int kMinPasswordLength = 8;

/// Most common passwords (global + Vietnamese), lower-case, compared after
/// removing spaces, dashes and dots and trailing digits / "!".
const Set<String> _common = {
  'password', 'passw0rd', 'p@ssword', 'p@ssw0rd', 'qwerty', 'qwertyuiop', 'asdfgh', 'asdfghjkl', 'zxcvbnm', 'iloveyou',
  'admin', 'administrator', 'welcome', 'letmein', 'monkey', 'dragon', 'football', 'baseball', 'princess', 'sunshine',
  'master', 'shadow', 'superman', 'batman', 'trustno', 'whatever', 'starwars', 'computer', 'internet', 'secret',
  'login', 'access', 'hello', 'freedom', 'michael', 'charlie', 'jennifer', 'jordan', 'hunter', 'killer', 'soccer',
  'abc', 'abcd', 'abcde', 'abcdef', 'abc123', 'qazwsx', 'zaq1', 'zaq12wsx', '1q2w3e', '1q2w3e4r', '1qaz2wsx',
  'changeme', 'default', 'guest', 'test', 'user', 'root', 'lumora', 'lumorapass', 'matkhau', 'mat khau', 'anhyeuem',
  'emyeuanh', 'yeuem', 'yeuanh', 'iloveu', 'vietnam', 'saigon', 'hanoi', 'congchua', 'hoangtu', 'thienthan',
  'matkhaucuatoi', 'baomat', 'xinchao', 'tinhyeu', 'muadong', 'muaxuan',
};

/// Problem with [pw] as an l10n key (`pass_too_short`, `pass_too_weak`), or
/// null when it is acceptable.
String? passwordProblem(String pw, {int minLength = kMinPasswordLength}) {
  final chars = pw.runes.toList();
  if (chars.length < minLength) return 'pass_too_short';
  final low = pw.toLowerCase();
  final squashed = low.replaceAll(RegExp(r'[\s\-_.]'), '');
  // one character repeated, or a short unit repeated ("abcabcabc", "121212")
  for (var unit = 1; unit <= 4; unit++) {
    if (squashed.length >= unit * 2 && squashed.length % unit == 0 && squashed == squashed.substring(0, unit) * (squashed.length ~/ unit)) {
      return 'pass_too_weak';
    }
  }
  // straight runs: 12345678, 87654321, abcdefgh, keyboard rows
  const runs = ['0123456789', 'abcdefghijklmnopqrstuvwxyz', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm', '1qaz2wsx3edc4rfv', 'qazwsxedcrfv'];
  for (final r in runs) {
    final rev = r.split('').reversed.join();
    if ((r.contains(squashed) || rev.contains(squashed)) && squashed.isNotEmpty) return 'pass_too_weak';
  }
  // only digits up to 8 long: dates, phone tails, PINs
  if (RegExp(r'^\d+$').hasMatch(squashed) && squashed.length <= 8) return 'pass_too_weak';
  // a common word with a number / "!" stuck on (Password1, matkhau123, iloveyou!)
  final core = squashed.replaceAll(RegExp(r'[\d!@#$%^&*?]+$'), '').replaceAll(RegExp(r'^[\d!@#$%^&*?]+'), '');
  if (_common.contains(squashed) || _common.contains(core) || core.isEmpty) return 'pass_too_weak';
  return null;
}
