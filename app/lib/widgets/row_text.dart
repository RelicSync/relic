// What a list row says: its title, and under it the start of what was
// actually copied. A generated title tells you what a thing is; when you
// copied it three minutes ago you remember what it said, so the row shows
// both. Pure functions, no widgets, so the rules are unit-tested.
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../models/relic.dart';

/// The lines a row shows. [secondary] is null when the row has one line: no
/// title (titling off, or not titled yet), or a title that already says what
/// the content says. Secrets never put their value in either line.
typedef RowLines = ({
  String primary,
  String? secondary,
  bool primaryMono,
  bool secondaryMono,
});

const _monoTags = {'url', 'code', 'json', 'path'};
const _glanceCap = 200;

/// Mono reads better for machine text: links, code, json, paths, files.
bool _monoContent(Relic r) =>
    r.kind == Kind.file || r.kind == Kind.other || r.tags.any(_monoTags.contains);

RowLines rowLines(Relic r) {
  final title = r.title?.trim();
  final hasTitle = title != null && title.isNotEmpty;
  if (r.isSecret) {
    return (
      primary: r.safeTitle,
      secondary: null,
      primaryMono: false,
      secondaryMono: true,
    );
  }
  final glance = contentGlance(r);
  final mono = _monoContent(r);
  if (!hasTitle) {
    // Titling off, or the title hasn't landed: the content is the row, as it
    // always was.
    return (
      primary: glance ?? r.displayTitle,
      secondary: null,
      primaryMono: mono,
      secondaryMono: mono,
    );
  }
  return (
    primary: title,
    secondary: glance == null || sameGist(title, glance) ? null : glance,
    primaryMono: false,
    secondaryMono: mono,
  );
}

/// The start of what was copied, cleaned up for one line. Null for secrets
/// and for items with no text to show.
String? contentGlance(Relic r) {
  if (r.isSecret) return null;
  String? out;
  final text = r.content ?? r.preview;
  if (r.kind == Kind.file) {
    final f = r.filename;
    if (f != null && f.isNotEmpty && f != r.title?.trim()) {
      out = f;
    } else if (text != null) {
      out = _firstLine(text);
    }
  } else if (r.tags.contains('url') && text != null && !text.contains('\n')) {
    out = shortUrl(text.trim());
  } else if (r.tags.contains('path') && text != null && !text.contains('\n')) {
    out = shortPath(text.trim().replaceAll('"', ''));
  } else if ((r.tags.contains('code') || r.tags.contains('json')) &&
      text != null) {
    out = _firstLine(text);
  } else if (r.hasAttachments && (text == null || text.trim().isEmpty)) {
    out = r.attachments.map((a) => a.name).join(', ');
  } else if (text != null) {
    out = cleanDisplayText(text);
  }
  if (out == null || out.trim().isEmpty) return null;
  return out.length > _glanceCap ? out.substring(0, _glanceCap) : out;
}

String _firstLine(String s) => s
    .split('\n')
    .map((l) => l.trim())
    .firstWhere((l) => l.isNotEmpty, orElse: () => '');

/// `https://www.example.com/a/` → `example.com/a`.
String shortUrl(String url) {
  var s = url.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  s = s.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  try {
    s = Uri.decodeFull(s);
  } catch (_) {/* not valid percent-encoding: show it as it is */}
  return s;
}

/// The home folder becomes `~`, and a long path keeps its last three parts
/// (the file and its folders) behind `…`, so the end you recognize survives.
String shortPath(String path, {String? home, int max = 36}) {
  home ??= Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  var s = path;
  if (home != null &&
      home.isNotEmpty &&
      s.toLowerCase().startsWith(home.toLowerCase())) {
    s = '~${s.substring(home.length)}';
  }
  if (s.length <= max) return s;
  final sep = s.contains('\\') ? '\\' : '/';
  final parts = s.split(sep);
  if (parts.length <= 4) return s;
  return [parts.first, '…', ...parts.sublist(parts.length - 3)].join(sep);
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// Whether a title and a content line say the same thing, so showing both
/// would only repeat it: equal once case and punctuation go, or one holds
/// the other and they differ by under 15 characters.
bool sameGist(String title, String glance) {
  final a = _norm(title);
  final b = _norm(glance);
  if (a.isEmpty || b.isEmpty) return a == b;
  if (a == b) return true;
  return (a.contains(b) || b.contains(a)) && (a.length - b.length).abs() < 15;
}

/// Lowercased search words worth marking: operators (`tag:`, `kind:`) and
/// negations dropped, two letters minimum.
List<String> highlightTerms(String query) => [
      for (final t in query.toLowerCase().split(RegExp(r'\s+')))
        if (t.length >= 2 && !t.contains(':') && !t.startsWith('-'))
          t.replaceAll('"', ''),
    ];

/// [text] with the search words the [title] doesn't already explain marked
/// with a soft wash. When the first mark sits past [lead] characters, the
/// line starts a few words before it with `…`, so a hit deep in a long text
/// is still on screen.
TextSpan highlightSpan(
  String text,
  List<String> terms,
  TextStyle style,
  Color wash, {
  String? title,
  int lead = 28,
}) {
  final t = title?.toLowerCase() ?? '';
  final marks = [
    for (final w in terms)
      if (!t.contains(w)) w,
  ];
  if (marks.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase();
  final ranges = <(int, int)>[];
  for (final w in marks) {
    var i = lower.indexOf(w);
    while (i >= 0) {
      ranges.add((i, i + w.length));
      i = lower.indexOf(w, i + w.length);
    }
  }
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  var start = 0;
  if (ranges.first.$1 > lead) {
    // Back up to a word boundary about a dozen characters before the hit.
    start = ranges.first.$1 - 12;
    final space = text.lastIndexOf(' ', ranges.first.$1 - 1);
    if (space > start - 12 && space >= 0) start = space + 1;
    if (start < 0) start = 0;
  }
  final marked = style.copyWith(background: Paint()..color = wash);
  final spans = <TextSpan>[if (start > 0) TextSpan(text: '…', style: style)];
  var at = start;
  for (final (a, b) in ranges) {
    if (b <= at) continue;
    final from = a < at ? at : a;
    if (from > at) spans.add(TextSpan(text: text.substring(at, from), style: style));
    spans.add(TextSpan(text: text.substring(from, b), style: marked));
    at = b;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: style));
  return TextSpan(children: spans, style: style);
}
