// Search matching that ignores case and diacritics, the way people type on
// a phone: "tieng viet" finds "Tiếng Việt", "d" finds "đ", and text typed in
// decomposed form (NFD: "e" + U+0302 + U+0301, as some keyboards / macOS
// send it) matches the precomposed spelling too.

/// Precomposed Latin letters (Vietnamese first of all) and their base letter.
const String _from =
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďđēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏőŕŗřśŝşšţťũūŭůűųŵŷźżžơưǎǐǒǔǖǘǚǜǟǡǧǩǫǭǰǵǹǻȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧȩȫȭȯȱȳḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭḯḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ';
const String _to =
    'aaaaaaceeeeiiiinooooouuuuyyaaaccccddeeeeegggghiiiijklllnnnooorrrssssttuuuuuuwyzzzouaiouuuuuaagkoojgnaaaeeiioorruusthaeooooyabbbcdddddeeeeefghhhhhiikkkllllmmmnnnnoooopprrrrsssssttttuuuuuvvwwwwwxxyzzzhtwyaaaaaaaaaaaaeeeeeeeeiioooooooooooouuuuuuuyyyy';

final Map<int, int> _map = {for (var i = 0; i < _from.length; i++) _from.codeUnitAt(i): _to.codeUnitAt(i)};

/// Combining marks (U+0300–U+036F): what NFD text carries its accents in.
bool _combining(int c) => c >= 0x0300 && c <= 0x036F;

/// Lowercase, without diacritics: "Tiếng Việt" -> "tieng viet", "ĐÀ" -> "da".
/// Everything else (spaces, digits, other scripts, emoji) is kept as is.
String foldText(String s) {
  if (s.isEmpty) return s;
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    if (_combining(r)) continue;
    b.writeCharCode(_map[r] ?? r);
  }
  return b.toString();
}

/// [text] contains [query], ignoring case and diacritics ([query] may be
/// already folded). An empty query matches everything.
bool foldContains(String text, String query) {
  final q = foldText(query.trim());
  return q.isEmpty || foldText(text).contains(q);
}
