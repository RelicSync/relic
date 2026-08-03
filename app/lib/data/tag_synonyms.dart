/// Curated tag → concept-synonym terms, indexed into the FTS/trigram body so
/// concept queries ("numeric", "link", "password", "money") hit offline even
/// with ML off. Mirrors `fileTypeSearchTerms` (file_types.dart) in shape.
///
/// The literal tag word itself is already indexed (via relic_db's `_tagText`
/// into the FTS `tags` column and the trigram body), so these lists only add
/// the *other* words a user might search for — never the tag word itself (a
/// test enforces that). Includes a curated set of common misspellings, so a
/// mistyped *query* still matches. Aggressive/floody terms (id, code, key,
/// reference, sms, login) are deliberately excluded.
library;

const Map<String, List<String>> kTagSynonyms = {
  // structural values
  'number': [
    'numeric', 'digits', 'num', 'figure', 'integer', 'decimal', 'count',
    'quantity', 'nunber', 'nubmer',
  ],
  'url': [
    'link', 'website', 'hyperlink', 'web', 'uri', 'href', 'webpage',
    'permalink', 'weblink', 'shortlink', 'www', 'wesbite', 'hyperlnk',
  ],
  'email': [
    'address', 'contact', 'mail', 'e-mail', 'inbox', 'sender', 'recipient',
    'gmail', 'outlook', 'cc', 'bcc', 'emial', 'emai', 'e-mial',
  ],
  'phone': [
    'telephone', 'mobile', 'cell', 'contact', 'tel', 'cellphone', 'landline',
    'callback', 'dial', 'phne', 'fone', 'phon',
  ],
  'ip': [
    'network', 'ipv4', 'ipaddress', 'ipv6', 'host', 'hostname', 'subnet',
    'gateway', 'localhost', 'ipadress',
  ],
  'color': [
    'colour', 'hex', 'swatch', 'rgb', 'rgba', 'hsl', 'hexcode', 'tint',
    'shade', 'palette', 'hue', 'collor', 'colur', 'coler',
  ],
  'uuid': [
    'guid', 'identifier', 'uid', 'ulid', 'uniqueid', 'correlationid', 'uudi',
    'uiid',
  ],
  'date': [
    'day', 'calendar', 'timestamp', 'deadline', 'due', 'schedule', 'when',
    'datestamp', 'isodate', 'dtae', 'adte',
  ],
  'time': [
    'clock', 'hour', 'timestamp', 'oclock', 'moment', 'hourminute', 'tiem',
    'itme',
  ],
  'duration': [
    'elapsed', 'interval', 'length', 'period', 'timespan', 'timer', 'runtime',
    'howlong', 'uptime', 'downtime', 'leadtime', 'span', 'duratoin', 'duraton',
  ],
  'version': [
    'semver', 'release', 'build', 'revision', 'rev', 'patch', 'changelog',
    'versioning', 'verison', 'vesion', 'versoin',
  ],
  'path': [
    'file', 'directory', 'folder', 'location', 'filepath', 'filename', 'dir',
    'pathname', 'fullpath', 'subfolder', 'breadcrumb', 'direcotry', 'folfer',
  ],
  'mac': [
    'hardware', 'macaddress', 'macaddr', 'physicaladdress', 'hardwareaddress',
    'ethernet', 'nic', 'bssid', 'macadress',
  ],
  'hash': [
    'checksum', 'digest', 'fingerprint', 'md5', 'sha', 'sha1', 'sha256',
    'sha512', 'crc', 'hashsum', 'signature', 'hsah', 'cheksum',
  ],
  'geo': [
    'coordinates', 'location', 'latitude', 'longitude', 'gps', 'coords', 'lat',
    'long', 'lng', 'waypoint', 'geolocation', 'geotag', 'cordinates',
    'coordinats', 'lattitude',
  ],
  'card': [
    'credit', 'creditcard', 'payment', 'debit', 'visa', 'mastercard', 'amex',
    'discover', 'ccn', 'pan', 'bankcard', 'cardnumber', 'crdit', 'creditcrad',
  ],
  // secret-class
  'jwt': [
    'token', 'credential', 'auth', 'bearer', 'jsonwebtoken', 'accesstoken',
    'idtoken', 'refreshtoken', 'oauth', 'jtw', 'jwr',
  ],
  'secret': [
    'password', 'credential', 'key', 'token', 'apikey', 'passwd', 'pwd', 'pw',
    'creds', 'api-key', 'passphrase', 'keypair', 'privatekey', 'sshkey',
    'accesskey', 'secretkey', 'clientsecret', 'auth', 'passowrd', 'crednetial',
    'pasword',
  ],
  'ssn': ['social', 'socialsecurity', 'tin', 'taxid'],
  // content shapes
  'json': [
    'data', 'object', 'dataformat', 'payload', 'keyvalue', 'dict', 'structured',
    'apiresponse', 'jason', 'jsno', 'jsom',
  ],
  'markdown': [
    'md', 'formatted', 'markup', 'readme', 'mdown', 'commonmark', 'richtext',
    'markdwon', 'mardown',
  ],
  'code': [
    'source', 'snippet', 'program', 'sourcecode', 'script', 'syntax',
    'programming', 'dev', 'codeblock', 'function', 'cdoe', 'coed',
  ],
  'todo': [
    'task', 'checklist', 'checkbox', 'to-do', 'todoitem', 'actionitem',
    'action', 'reminder', 'tasklist', 'punchlist', 'backlog', 'todu', 'tdoo',
  ],
  'sql': [
    'query', 'database', 'db', 'postgres', 'mysql', 'sqlite', 'dbquery',
    'resultset', 'squel', 'seequel', 'sqll',
  ],
  'xml': ['markup', 'xhtml', 'rss', 'soap', 'feed', 'xmlfile', 'xlm', 'mxl'],
  'html': [
    'markup', 'webpage', 'htm', 'dom', 'hypertext', 'template', 'htmlfile',
    'markuplanguage', 'hmtl', 'htlm', 'hrml',
  ],
  'error': [
    'exception', 'stacktrace', 'traceback', 'crash', 'bug', 'panic', 'fault',
    'failure', 'err', 'backtrace', 'coredump', 'errormessage', 'warning',
    'eror', 'errror', 'erorr',
  ],
  'command': [
    'shell', 'terminal', 'cli', 'bash', 'cmd', 'powershell', 'zsh', 'console',
    'oneliner', 'commandline', 'script', 'comand', 'commnd', 'commmand',
  ],
  'tracking': [
    'shipment', 'package', 'parcel', 'delivery', 'courier', 'shipping',
    'carrier', 'waybill', 'consignment', 'ups', 'fedex', 'usps', 'dhl',
    'trackingnumber', 'traking', 'trackign', 'shippment',
  ],
  'otp': [
    'code', 'verification', 'twofactor', 'onetime', '2fa', 'mfa', 'totp',
    'passcode', 'securitycode', 'authcode', 'pincode', 'pin',
    'verificationcode', 'onetimepassword', 'opt',
  ],
  'receipt': [
    'money', 'price', 'cost', 'payment', 'purchase', 'invoice', 'bill', 'order',
    'transaction', 'checkout', 'expense', 'itemized', 'salesreceipt',
    'proofofpurchase', 'reciept', 'recipt', 'receit',
  ],
  'address': [
    'location', 'street', 'mailing', 'postal', 'zip', 'zipcode', 'addr',
    'residence', 'shippingaddress', 'homeaddress', 'adress', 'addres', 'adres',
  ],
  'graph': [
    'diagram', 'chart', 'flowchart', 'mermaid', 'graphviz', 'dot', 'erd', 'uml',
    'plot', 'visualization', 'networkdiagram', 'sequencediagram', 'grpah',
    'grahp',
  ],
  // semantic value shapes
  'currency': [
    'money', 'price', 'cost', 'amount', 'payment', 'cash', 'fee', 'salary',
    'wage', 'income', 'revenue', 'charge', 'spend', 'dollar', 'euro', 'pound',
    'usd', 'eur', 'gbp', 'curency', 'curreny', 'currancy',
  ],
  'percent': [
    'percentage', 'rate', 'ratio', 'discount', 'off', 'pct', 'proportion',
    'apr', 'markup', 'interestrate', 'precent', 'percnet', 'persent',
  ],
  'measurement': [
    'measure', 'dimension', 'size', 'unit', 'weight', 'length', 'distance',
    'height', 'width', 'volume', 'mass', 'metric', 'imperial', 'measurment',
    'mesurement', 'meausrement',
  ],
  'handle': [
    'mention', 'username', 'social', 'atsign', 'at-sign', 'screenname', 'alias',
    'nickname', 'account', 'twitter', 'instagram', 'handel', 'hanlde',
  ],
  'hashtag': [
    'topic', 'social', 'trend', 'trending', 'keyword', 'poundsign', 'category',
    'hashtga', 'hastag', 'hashtahg',
  ],
  // new detector tags (see heuristic_tags.dart)
  'doi': ['paper', 'academic', 'citation', 'research'],
  'arxiv': ['paper', 'preprint', 'academic', 'research'],
  'orcid': ['researcher', 'author', 'academic', 'identifier'],
  'iban': ['bank', 'account', 'banking', 'payment'],
  'location': ['geo', 'coordinates', 'place', 'gps', 'map'],
  'table': ['tabular', 'grid', 'spreadsheet', 'rows', 'columns'],
  'isbn': ['book', 'publication'],
  'book': ['isbn', 'publication', 'reading'],
  'vin': ['vehicle', 'car', 'automobile'],
  'vehicle': ['car', 'automobile', 'auto'],
  'postcode': ['postal', 'zip', 'zipcode', 'address'],
  'swift': ['bic', 'bank', 'banking', 'wire'],
  'commit': ['revision', 'sha', 'git', 'changeset'],
  'port': ['socket', 'host', 'network', 'endpoint'],
  'base64': ['encoded', 'blob', 'data'],
  'hexdump': ['hex', 'binary', 'dump', 'bytes'],
  'env': ['config', 'variable', 'dotenv', 'settings', 'environment'],
  'ticket': ['issue', 'jira', 'bug', 'story'],
  'issue': ['ticket', 'bug', 'problem'],
  'math': ['equation', 'formula', 'latex', 'expression'],
  'csv': ['spreadsheet', 'data', 'tabular', 'rows'],
  'routing': ['bank', 'aba', 'account', 'banking'],
  'coupon': ['promo', 'discount', 'voucher', 'offer'],
  'wallet': ['crypto', 'blockchain', 'ethereum', 'bitcoin'],
  'crypto': ['wallet', 'cryptocurrency', 'blockchain', 'coin', 'web3'],
  'diff': ['patch', 'changes', 'gitdiff'],
  // chip-unifying tags (doi/arxiv → paper; iban/swift/routing → bank)
  'paper': ['research', 'academic', 'publication', 'article', 'preprint'],
  'bank': ['banking', 'account', 'finance', 'financial'],
  // media / kind tags (from sift / file classification)
  'photo': [
    'picture', 'image', 'pic', 'snapshot', 'photograph', 'selfie', 'jpeg',
    'jpg', 'png', 'img', 'gif', 'animation', 'wallpaper', 'avatar', 'icon',
    'phto', 'phoot',
  ],
  'screenshot': [
    'capture', 'screen', 'screengrab', 'screencap', 'snip', 'printscreen',
    'screencapture', 'screenshto', 'screnshot',
  ],
  'qrcode': ['qr', 'barcode', 'scancode', 'upc', 'ean', 'matrixcode', 'qrcdoe'],
  'chart': [
    'graph', 'plot', 'barchart', 'piechart', 'linechart', 'infographic',
    'dashboard', 'visualization', 'cahrt', 'chrat',
  ],
  'diagram': [
    'chart', 'flowchart', 'schematic', 'wireframe', 'uml', 'mindmap',
    'blueprint', 'illustration', 'diagramm', 'digram', 'diagam',
  ],
  // source-app tags (stamped at capture from the foreground process), so
  // "the link I copied from my browser" resolves without naming the app
  'chrome': ['browser', 'web'],
  'edge': ['browser', 'web'],
  'firefox': ['browser', 'web'],
  'brave': ['browser', 'web'],
  'opera': ['browser', 'web'],
  'vivaldi': ['browser', 'web'],
  'arc': ['browser', 'web'],
  'safari': ['browser', 'web'],
  'vscode': ['editor', 'ide'],
  'visualstudio': ['editor', 'ide'],
  'intellij': ['editor', 'ide'],
  'pycharm': ['editor', 'ide'],
  'webstorm': ['editor', 'ide'],
  'androidstudio': ['editor', 'ide'],
  'terminal': ['shell', 'console', 'commandline'],
  'slack': ['chat', 'messaging'],
  'discord': ['chat', 'messaging'],
  'teams': ['chat', 'meeting'],
  'telegram': ['chat', 'messaging'],
  'whatsapp': ['chat', 'messaging'],
  'word': ['document'],
  'excel': ['spreadsheet'],
  'powerpoint': ['presentation', 'slides', 'deck'],
  'outlook': ['mail'],
  'notion': ['notes'],
  'obsidian': ['notes'],
  // sift category / image tags — the literal tag word is indexed already;
  // these add the concept words a user would actually type
  'mail': ['email', 'message', 'correspondence', 'inbox'],
  'chat': ['conversation', 'message', 'messages', 'dm', 'thread'],
  'note': ['notes', 'memo', 'jotting'],
  'log': ['logs', 'logfile', 'output', 'trace'],
  'people': ['person', 'faces', 'group', 'portrait'],
  'meme': ['funny', 'joke', 'humor'],
  'scan': ['scanned', 'scanner', 'scanning'],
};

/// Concept synonyms for a machine tag (empty when none mapped).
List<String> tagSearchTerms(String tag) => kTagSynonyms[tag] ?? const [];

/// Reverse lookup for QUERY-side expansion: a query term that is a known
/// synonym/misspelling/abbreviation maps to up to two canonical words — the
/// tag's first-listed (most canonical) synonym and the tag word itself, so
/// "pw" → [password, secret] and "reciept" → [money, receipt]. relic_db uses
/// this only as a fallback rung AFTER the literal query found nothing, so it
/// adds recall without costing precision on queries that already hit.
///
/// A synonym listed under MORE THAN ONE tag is dropped entirely: which tag
/// "wins" would be map-order luck, and the wrong pick is actively harmful
/// ("social" is listed under both ssn and handle — expanding a social-media
/// search into SSN relics is not a good look).
final Map<String, List<String>> kSynonymExpansions = () {
  final seen = <String>{};
  final ambiguous = <String>{};
  for (final e in kTagSynonyms.entries) {
    for (final s in e.value) {
      if (!seen.add(s)) ambiguous.add(s);
    }
  }
  final m = <String, List<String>>{};
  for (final e in kTagSynonyms.entries) {
    final canon = e.value.first;
    for (final s in e.value) {
      if (ambiguous.contains(s)) continue;
      final exp = <String>[
        if (canon != s) canon,
        if (e.key != s && e.key != canon) e.key,
      ];
      if (exp.isNotEmpty) m[s] = exp;
    }
  }
  return m;
}();

/// The single tag a query term unambiguously NAMES: the tag word itself
/// ("url"), a synonym/misspelling listed under exactly one tag ("link" →
/// url), or the singular of either ("links" → url). Null when the term names
/// nothing — or names more than one tag, where map-order luck must not pick
/// a winner. Powers the tag-intent ranking leg: "relic link" means items
/// that ARE links about relic, not items whose text merely says "link".
String? tagIntentOf(String term) {
  final t = term.toLowerCase();
  final hit = _kTagIntents[t];
  if (hit != null) return hit;
  if (t.length > 3 && t.endsWith('s')) {
    return _kTagIntents[t.substring(0, t.length - 1)];
  }
  return null;
}

/// term → the one tag it names. Tag words map to themselves and win over a
/// same-spelled synonym of another tag ("chart" is a tag AND a synonym under
/// graph — it stays chart); ambiguous synonyms are dropped entirely, same
/// rule as [kSynonymExpansions].
final Map<String, String> _kTagIntents = () {
  final seen = <String>{};
  final ambiguous = <String>{};
  for (final e in kTagSynonyms.entries) {
    for (final s in e.value) {
      if (!seen.add(s)) ambiguous.add(s);
    }
  }
  final m = <String, String>{for (final t in kTagSynonyms.keys) t: t};
  for (final e in kTagSynonyms.entries) {
    for (final s in e.value) {
      if (!ambiguous.contains(s) && !m.containsKey(s)) m[s] = e.key;
    }
  }
  return m;
}();
