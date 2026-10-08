/// Where a copy came from: the window title, the page link and the words
/// around the selection, read at the moment of the copy
/// (platform/copy_context.dart).
///
/// Kept on the capturing device only (RelicDb's `copy_context` table) and
/// handed to relic-sift with the item, which uses it to title the copy in place
/// and to add two search chunks (relic-sift/src/context.rs).
class CopyContext {
  const CopyContext({this.title, this.url, this.before = '', this.after = ''});

  final String? title;
  final String? url;
  final String before;
  final String after;

  /// Words kept on each side. The models read at most 50; a little more lets
  /// a later model use a wider window without a re-capture.
  static const int keepWords = 60;

  bool get isEmpty =>
      (title ?? '').trim().isEmpty &&
      (url ?? '').trim().isEmpty &&
      before.trim().isEmpty &&
      after.trim().isEmpty;

  bool get hasWords => before.trim().isNotEmpty || after.trim().isNotEmpty;

  /// The same context with the surrounding text trimmed to [keepWords] on
  /// each side (the nearest ones) and every field length-capped.
  CopyContext trimmed() {
    String lastWords(String s) {
      final w = s.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
      return w.sublist(w.length > keepWords ? w.length - keepWords : 0).join(' ');
    }

    String firstWords(String s) => s
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty)
        .take(keepWords)
        .join(' ');
    String? cap(String? s, int n) {
      final t = s?.trim();
      if (t == null || t.isEmpty) return null;
      return t.length > n ? t.substring(0, n) : t;
    }

    return CopyContext(
      title: cap(title, 300),
      url: cap(url, 600),
      before: cap(lastWords(before), 1500) ?? '',
      after: cap(firstWords(after), 1500) ?? '',
    );
  }

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Whether a control's current selection [selection] is the text that was
  /// just copied: equal once whitespace is collapsed, or holding it with only
  /// a little extra (editors often select a trailing newline). Anything else
  /// means the selection moved on or the control isn't the source, and the
  /// words around it would describe some other text.
  static bool sameSelection(String selection, String copied) {
    final s = _norm(selection), c = _norm(copied);
    if (c.isEmpty || s.isEmpty) return false;
    if (s == c) return true;
    return s.contains(c) && s.length <= c.length + 20;
  }

  /// Split a control's whole text around [copied] when it occurs exactly
  /// once (a second occurrence makes the position a guess). Null otherwise.
  static CopyContext? splitAround(String full, String copied) {
    final c = copied.trim();
    if (c.isEmpty || full.length > 2000000) return null;
    final at = full.indexOf(c);
    if (at < 0 || full.indexOf(c, at + 1) >= 0) return null;
    final ctx = CopyContext(
      before: full.substring(0, at),
      after: full.substring(at + c.length),
    ).trimmed();
    return ctx.hasWords ? ctx : null;
  }

  CopyContext withUrl(String? u) =>
      CopyContext(title: title, url: u ?? url, before: before, after: after);

  /// The shape relic-sift's serve protocol reads (`context` in a request).
  Map<String, Object?> toJson() => {
        if (title != null) 'title': title,
        if (url != null) 'url': url,
        'before': before,
        'after': after,
      };

  /// Shape only, never the text: titles, links and nearby words can be private.
  @override
  String toString() => 'CopyContext(title: ${title?.length ?? 0} chars, '
      'url: ${url == null ? 'none' : 'yes'}, before: ${before.length} chars, '
      'after: ${after.length} chars)';
}
