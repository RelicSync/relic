/// Text transforms for the row "Copy as" menu. Pure functions, kept out of
/// the UI so they can be unit tested.
library;

final _letter = RegExp(r'\p{L}', unicode: true);

String upperCase(String t) => t.toUpperCase();

String lowerCase(String t) => t.toLowerCase();

/// Every word starts uppercase, the rest lowered. Only whitespace starts a
/// new word — letters consume the boundary and other characters leave it
/// untouched, so "(hello" capitalizes but "it's" and "foo-bar" stay one word.
String titleCase(String t) {
  final b = StringBuffer();
  var boundary = true;
  for (var i = 0; i < t.length; i++) {
    final ch = t[i];
    if (_letter.hasMatch(ch)) {
      b.write(boundary ? ch.toUpperCase() : ch.toLowerCase());
      boundary = false;
    } else {
      b.write(ch);
      if (ch.trim().isEmpty) boundary = true;
    }
  }
  return b.toString();
}

/// Collapse all whitespace runs (including newlines) to single spaces.
String singleLine(String t) => t.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Identity. Exists so "Plain text" can sit in the Copy-as menu next to the
/// real transforms: the whole menu routes through `putTextOnClipboard`, which
/// never carries the HTML/RTF flavors, so copying through this is exactly
/// "give me this clip with the formatting stripped".
String plainText(String t) => t;

/// The menu entries, in display order.
const copyAsTransforms = <(String, String Function(String))>[
  ('Plain text', plainText),
  ('UPPERCASE', upperCase),
  ('lowercase', lowerCase),
  ('Title Case', titleCase),
  ('Single line', singleLine),
];
