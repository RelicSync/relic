// GENERATED (icon choices via subagent, validated against the package).
// Maps a file-type category to a Lucide icon for the result-row kind tile.
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/file_types.dart';

const Map<String, IconData> kCategoryIcon = {
  'Image': LucideIcons.image,
  'Photo': LucideIcons.camera,
  'Vector': LucideIcons.penTool,
  'Video': LucideIcons.video,
  'Video Project': LucideIcons.clapperboard,
  'Audio': LucideIcons.music,
  'Audio Project': LucideIcons.audioWaveform,
  'Document': LucideIcons.fileText,
  'Spreadsheet': LucideIcons.fileSpreadsheet,
  'Presentation': LucideIcons.presentation,
  'PDF': LucideIcons.fileText,
  'Ebook': LucideIcons.bookOpen,
  'Archive': LucideIcons.fileArchive,
  'Disk Image': LucideIcons.disc,
  'Backup': LucideIcons.databaseBackup,
  'Code': LucideIcons.code,
  'Web': LucideIcons.globe,
  'Config': LucideIcons.settings,
  'Data': LucideIcons.braces,
  'Database': LucideIcons.database,
  'Notebook': LucideIcons.notebook,
  '3D': LucideIcons.box,
  'CAD': LucideIcons.draftingCompass,
  'Design': LucideIcons.swatchBook,
  'Font': LucideIcons.fileType,
  'Installer': LucideIcons.download,
  'Executable': LucideIcons.terminal,
  'Plugin': LucideIcons.plug,
  'System': LucideIcons.cpu,
  'Shortcut': LucideIcons.externalLink,
  'Log': LucideIcons.scrollText,
  'GIS': LucideIcons.mapPinned,
  'Scientific': LucideIcons.flaskConical,
  'AI Model': LucideIcons.brain,
  'Email': LucideIcons.mail,
  'Calendar': LucideIcons.calendar,
  'Contact': LucideIcons.contact,
  'Subtitle': LucideIcons.captions,
  'Security': LucideIcons.keyRound,
  'Game': LucideIcons.gamepad2,
  'Torrent': LucideIcons.magnet,
  'Mobile App': LucideIcons.smartphone,
};

/// Lucide icon for a file, chosen by its extension's category; a generic file
/// glyph for unknown types.
IconData fileIconFor(String? filename) {
  final ft = fileTypeFor(filename);
  if (ft != null) {
    final ic = kCategoryIcon[ft.category];
    if (ic != null) return ic;
  }
  return LucideIcons.file;
}

/// Icons for the deterministic content tags (`_detectTags` vocabulary) so a
/// chip reads at a glance — a link for urls, an @ for emails, a key for tokens.
const Map<String, IconData> kContentTagIcon = {
  'url': LucideIcons.link,
  'email': LucideIcons.atSign,
  'ip': LucideIcons.network,
  'color': LucideIcons.palette,
  'uuid': LucideIcons.fingerprint,
  'date': LucideIcons.calendar,
  'version': LucideIcons.tag,
  'path': LucideIcons.folderTree,
  'address': LucideIcons.mapPin,
  'phone': LucideIcons.phone,
  'jwt': LucideIcons.keyRound,
  'secret': LucideIcons.lock,
  'json': LucideIcons.braces,
  'markdown': LucideIcons.hash,
  'code': LucideIcons.code,
  'mac': LucideIcons.network,
  'hash': LucideIcons.fingerprint,
  'geo': LucideIcons.navigation,
  'card': LucideIcons.creditCard,
  'todo': LucideIcons.listChecks,
  'sql': LucideIcons.database,
  'xml': LucideIcons.code,
  'html': LucideIcons.code,
  'error': LucideIcons.circleAlert,
  'command': LucideIcons.terminal,
  'tracking': LucideIcons.truck,
  'otp': LucideIcons.shieldCheck,
  'receipt': LucideIcons.receipt,
  'graph': LucideIcons.chartNetwork,
  // semantic value tags (v4)
  'number': LucideIcons.binary,
  'currency': LucideIcons.banknote,
  'percent': LucideIcons.percent,
  'duration': LucideIcons.timer,
  'time': LucideIcons.clock,
  'measurement': LucideIcons.ruler,
  'handle': LucideIcons.atSign,
  'hashtag': LucideIcons.hash,
  // entity tags (v6)
  'doi': LucideIcons.newspaper,
  'arxiv': LucideIcons.newspaper,
  'paper': LucideIcons.newspaper,
  'orcid': LucideIcons.badgeCheck,
  'iban': LucideIcons.landmark,
  'bank': LucideIcons.landmark,
  'swift': LucideIcons.landmark,
  'routing': LucideIcons.landmark,
  'ssn': LucideIcons.shieldAlert, // sensitive, not "verified"
  'vin': LucideIcons.car,
  'vehicle': LucideIcons.car,
  'postcode': LucideIcons.mapPin,
  'location': LucideIcons.mapPin,
  'base64': LucideIcons.binary,
  'hexdump': LucideIcons.binary,
  'table': LucideIcons.table,
  'csv': LucideIcons.table,
  'isbn': LucideIcons.book,
  'book': LucideIcons.book,
  'commit': LucideIcons.gitCommitHorizontal,
  'port': LucideIcons.plug,
  'env': LucideIcons.settings,
  'math': LucideIcons.sigma,
  'ticket': LucideIcons.ticket,
  'coupon': LucideIcons.tag,
  'wallet': LucideIcons.bitcoin,
  'crypto': LucideIcons.bitcoin,
  'diff': LucideIcons.gitCompareArrows,
  // capture seeds + sift category/image tags (mirrors the browse-chip icons)
  'photo': LucideIcons.image,
  'screenshot': LucideIcons.monitor,
  'note': LucideIcons.notebook,
  'chat': LucideIcons.messageSquare,
  'mail': LucideIcons.mail,
  'log': LucideIcons.scrollText,
  'data': LucideIcons.braces,
  'scan': LucideIcons.scanLine,
  'meme': LucideIcons.laugh,
  'people': LucideIcons.users,
  'qrcode': LucideIcons.qrCode,
  'chart': LucideIcons.chartColumn,
  'diagram': LucideIcons.workflow,
};

/// The icon for a tag chip: the Capitalized file-type category glyphs first
/// (exact case — an "Email" FILE chip must get the envelope, not the atSign
/// the lowercase `email` content tag uses), then the content-tag glyphs.
/// Null when the tag has no icon (e.g. a user's freeform tag).
IconData? tagIconFor(String tag) =>
    kCategoryIcon[tag] ?? kContentTagIcon[tag.toLowerCase()];

/// Priority order for picking THE representative icon of a text relic from
/// its tags. Stored order is emission order (whole-value facts → content
/// shapes → scan-anywhere entities), which lets an incidental entity relabel
/// a whole clip — a note mentioning "localhost:8080" is not a plug. Ranked:
/// identity-defining whole-value tags, then content shapes (code before
/// markdown: a `#`-commented script is code), then value shapes, then
/// weak scan-anywhere entities, then provenance seeds.
const List<String> kIconTagPriority = [
  // whole-value identity
  'secret', 'jwt', 'url', 'email', 'phone', 'card', 'ssn', 'iban', 'vin',
  'wallet', 'ip', 'mac', 'uuid', 'hash', 'path', 'geo', 'color', 'date',
  'version', 'address', 'postcode', 'base64', 'hexdump',
  // strong content shapes
  'error', 'diff', 'todo', 'table', 'csv', 'sql', 'json', 'code', 'command',
  'xml', 'html', 'markdown', 'graph',
  // purposeful entities
  'receipt', 'tracking', 'otp', 'coupon', 'doi', 'arxiv', 'paper', 'isbn',
  'book', 'orcid', 'swift', 'routing', 'bank', 'ticket',
  // value shapes (near-naked values)
  'currency', 'percent', 'duration', 'time', 'measurement', 'number',
  'handle', 'hashtag', 'location', 'vehicle',
  // weak scan-anywhere entities — last among content, so they can't hijack
  'commit', 'port', 'env', 'math',
  // sift categories + provenance seeds
  'note', 'chat', 'mail', 'log', 'data', 'meme', 'scan', 'people', 'qrcode',
  'chart', 'diagram', 'photo', 'screenshot',
];

final Map<String, int> _iconRank = {
  for (var i = 0; i < kIconTagPriority.length; i++) kIconTagPriority[i]: i,
};

/// The representative icon for a tag list: the highest-priority icon-bearing
/// tag wins; unranked tags fall behind ranked ones in stored order. Null when
/// no tag has an icon.
IconData? primaryTagIcon(List<String> tags) {
  String? best;
  var bestRank = 1 << 30;
  for (var i = 0; i < tags.length; i++) {
    final t = tags[i];
    if (tagIconFor(t) == null) continue;
    final rank = _iconRank[t.toLowerCase()] ?? (1 << 20) + i;
    if (rank < bestRank) {
      bestRank = rank;
      best = t;
    }
  }
  return best == null ? null : tagIconFor(best);
}
