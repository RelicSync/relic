// Tag-intent resolution for vault search — a port of the desktop's
// tag_synonyms.dart (kTagSynonyms + tagIntentOf). A query term that
// unambiguously NAMES a tag ("link" -> url) marks type-word intent: items
// that ARE that type should outrank items whose text merely says the word.
// Keep this map in sync with app/lib/data/tag_synonyms.dart when tags or
// synonyms change there.

const TAG_SYNONYMS: Record<string, string[]> = {
  number: ["numeric", "digits", "num", "figure", "integer", "decimal", "count", "quantity", "nunber", "nubmer"],
  url: ["link", "website", "hyperlink", "web", "uri", "href", "webpage", "permalink", "weblink", "shortlink", "www", "wesbite", "hyperlnk"],
  email: ["address", "contact", "mail", "e-mail", "inbox", "sender", "recipient", "gmail", "outlook", "cc", "bcc", "emial", "emai", "e-mial"],
  phone: ["telephone", "mobile", "cell", "contact", "tel", "cellphone", "landline", "callback", "dial", "phne", "fone", "phon"],
  ip: ["network", "ipv4", "ipaddress", "ipv6", "host", "hostname", "subnet", "gateway", "localhost", "ipadress"],
  color: ["colour", "hex", "swatch", "rgb", "rgba", "hsl", "hexcode", "tint", "shade", "palette", "hue", "collor", "colur", "coler"],
  uuid: ["guid", "identifier", "uid", "ulid", "uniqueid", "correlationid", "uudi", "uiid"],
  date: ["day", "calendar", "timestamp", "deadline", "due", "schedule", "when", "datestamp", "isodate", "dtae", "adte"],
  time: ["clock", "hour", "timestamp", "oclock", "moment", "hourminute", "tiem", "itme"],
  duration: ["elapsed", "interval", "length", "period", "timespan", "timer", "runtime", "howlong", "uptime", "downtime", "leadtime", "span", "duratoin", "duraton"],
  version: ["semver", "release", "build", "revision", "rev", "patch", "changelog", "versioning", "verison", "vesion", "versoin"],
  path: ["file", "directory", "folder", "location", "filepath", "filename", "dir", "pathname", "fullpath", "subfolder", "breadcrumb", "direcotry", "folfer"],
  mac: ["hardware", "macaddress", "macaddr", "physicaladdress", "hardwareaddress", "ethernet", "nic", "bssid", "macadress"],
  hash: ["checksum", "digest", "fingerprint", "md5", "sha", "sha1", "sha256", "sha512", "crc", "hashsum", "signature", "hsah", "cheksum"],
  geo: ["coordinates", "location", "latitude", "longitude", "gps", "coords", "lat", "long", "lng", "waypoint", "geolocation", "geotag", "cordinates", "coordinats", "lattitude"],
  card: ["credit", "creditcard", "payment", "debit", "visa", "mastercard", "amex", "discover", "ccn", "pan", "bankcard", "cardnumber", "crdit", "creditcrad"],
  jwt: ["token", "credential", "auth", "bearer", "jsonwebtoken", "accesstoken", "idtoken", "refreshtoken", "oauth", "jtw", "jwr"],
  secret: ["password", "credential", "key", "token", "apikey", "passwd", "pwd", "pw", "creds", "api-key", "passphrase", "keypair", "privatekey", "sshkey", "accesskey", "secretkey", "clientsecret", "auth", "passowrd", "crednetial", "pasword"],
  ssn: ["social", "socialsecurity", "tin", "taxid"],
  json: ["data", "object", "dataformat", "payload", "keyvalue", "dict", "structured", "apiresponse", "jason", "jsno", "jsom"],
  markdown: ["md", "formatted", "markup", "readme", "mdown", "commonmark", "richtext", "markdwon", "mardown"],
  code: ["source", "snippet", "program", "sourcecode", "script", "syntax", "programming", "dev", "codeblock", "function", "cdoe", "coed"],
  todo: ["task", "checklist", "checkbox", "to-do", "todoitem", "actionitem", "action", "reminder", "tasklist", "punchlist", "backlog", "todu", "tdoo"],
  sql: ["query", "database", "db", "postgres", "mysql", "sqlite", "dbquery", "resultset", "squel", "seequel", "sqll"],
  xml: ["markup", "xhtml", "rss", "soap", "feed", "xmlfile", "xlm", "mxl"],
  html: ["markup", "webpage", "htm", "dom", "hypertext", "template", "htmlfile", "markuplanguage", "hmtl", "htlm", "hrml"],
  error: ["exception", "stacktrace", "traceback", "crash", "bug", "panic", "fault", "failure", "err", "backtrace", "coredump", "errormessage", "warning", "eror", "errror", "erorr"],
  command: ["shell", "terminal", "cli", "bash", "cmd", "powershell", "zsh", "console", "oneliner", "commandline", "script", "comand", "commnd", "commmand"],
  tracking: ["shipment", "package", "parcel", "delivery", "courier", "shipping", "carrier", "waybill", "consignment", "ups", "fedex", "usps", "dhl", "trackingnumber", "traking", "trackign", "shippment"],
  otp: ["code", "verification", "twofactor", "onetime", "2fa", "mfa", "totp", "passcode", "securitycode", "authcode", "pincode", "pin", "verificationcode", "onetimepassword", "opt"],
  receipt: ["money", "price", "cost", "payment", "purchase", "invoice", "bill", "order", "transaction", "checkout", "expense", "itemized", "salesreceipt", "proofofpurchase", "reciept", "recipt", "receit"],
  address: ["location", "street", "mailing", "postal", "zip", "zipcode", "addr", "residence", "shippingaddress", "homeaddress", "adress", "addres", "adres"],
  graph: ["diagram", "chart", "flowchart", "mermaid", "graphviz", "dot", "erd", "uml", "plot", "visualization", "networkdiagram", "sequencediagram", "grpah", "grahp"],
  currency: ["money", "price", "cost", "amount", "payment", "cash", "fee", "salary", "wage", "income", "revenue", "charge", "spend", "dollar", "euro", "pound", "usd", "eur", "gbp", "curency", "curreny", "currancy"],
  percent: ["percentage", "rate", "ratio", "discount", "off", "pct", "proportion", "apr", "markup", "interestrate", "precent", "percnet", "persent"],
  measurement: ["measure", "dimension", "size", "unit", "weight", "length", "distance", "height", "width", "volume", "mass", "metric", "imperial", "measurment", "mesurement", "meausrement"],
  handle: ["mention", "username", "social", "atsign", "at-sign", "screenname", "alias", "nickname", "account", "twitter", "instagram", "handel", "hanlde"],
  hashtag: ["topic", "social", "trend", "trending", "keyword", "poundsign", "category", "hashtga", "hastag", "hashtahg"],
  doi: ["paper", "academic", "citation", "research"],
  arxiv: ["paper", "preprint", "academic", "research"],
  orcid: ["researcher", "author", "academic", "identifier"],
  iban: ["bank", "account", "banking", "payment"],
  location: ["geo", "coordinates", "place", "gps", "map"],
  table: ["tabular", "grid", "spreadsheet", "rows", "columns"],
  isbn: ["book", "publication"],
  book: ["isbn", "publication", "reading"],
  vin: ["vehicle", "car", "automobile"],
  vehicle: ["car", "automobile", "auto"],
  postcode: ["postal", "zip", "zipcode", "address"],
  swift: ["bic", "bank", "banking", "wire"],
  commit: ["revision", "sha", "git", "changeset"],
  port: ["socket", "host", "network", "endpoint"],
  base64: ["encoded", "blob", "data"],
  hexdump: ["hex", "binary", "dump", "bytes"],
  env: ["config", "variable", "dotenv", "settings", "environment"],
  ticket: ["issue", "jira", "bug", "story"],
  issue: ["ticket", "bug", "problem"],
  math: ["equation", "formula", "latex", "expression"],
  csv: ["spreadsheet", "data", "tabular", "rows"],
  routing: ["bank", "aba", "account", "banking"],
  coupon: ["promo", "discount", "voucher", "offer"],
  wallet: ["crypto", "blockchain", "ethereum", "bitcoin"],
  crypto: ["wallet", "cryptocurrency", "blockchain", "coin", "web3"],
  diff: ["patch", "changes", "gitdiff"],
  paper: ["research", "academic", "publication", "article", "preprint"],
  bank: ["banking", "account", "finance", "financial"],
  photo: ["picture", "image", "pic", "snapshot", "photograph", "selfie", "jpeg", "jpg", "png", "img", "gif", "animation", "wallpaper", "avatar", "icon", "phto", "phoot"],
  screenshot: ["capture", "screen", "screengrab", "screencap", "snip", "printscreen", "screencapture", "screenshto", "screnshot"],
  qrcode: ["qr", "barcode", "scancode", "upc", "ean", "matrixcode", "qrcdoe"],
  chart: ["graph", "plot", "barchart", "piechart", "linechart", "infographic", "dashboard", "visualization", "cahrt", "chrat"],
  diagram: ["chart", "flowchart", "schematic", "wireframe", "uml", "mindmap", "blueprint", "illustration", "diagramm", "digram", "diagam"],
  chrome: ["browser", "web"],
  edge: ["browser", "web"],
  firefox: ["browser", "web"],
  brave: ["browser", "web"],
  opera: ["browser", "web"],
  vivaldi: ["browser", "web"],
  arc: ["browser", "web"],
  safari: ["browser", "web"],
  vscode: ["editor", "ide"],
  visualstudio: ["editor", "ide"],
  intellij: ["editor", "ide"],
  pycharm: ["editor", "ide"],
  webstorm: ["editor", "ide"],
  androidstudio: ["editor", "ide"],
  terminal: ["shell", "console", "commandline"],
  slack: ["chat", "messaging"],
  discord: ["chat", "messaging"],
  teams: ["chat", "meeting"],
  telegram: ["chat", "messaging"],
  whatsapp: ["chat", "messaging"],
  word: ["document"],
  excel: ["spreadsheet"],
  powerpoint: ["presentation", "slides", "deck"],
  outlook: ["mail"],
  notion: ["notes"],
  obsidian: ["notes"],
  mail: ["email", "message", "correspondence", "inbox"],
  chat: ["conversation", "message", "messages", "dm", "thread"],
  note: ["notes", "memo", "jotting"],
  log: ["logs", "logfile", "output", "trace"],
  people: ["person", "faces", "group", "portrait"],
  meme: ["funny", "joke", "humor"],
  scan: ["scanned", "scanner", "scanning"],
};

// term -> the one tag it names. Tag words map to themselves and win over a
// same-spelled synonym of another tag; a synonym listed under several tags
// is dropped entirely (map-order luck must not pick a winner). Same rule as
// the Dart kSynonymExpansions/_kTagIntents.
const TAG_INTENTS: Map<string, string> = (() => {
  const seen = new Set<string>();
  const ambiguous = new Set<string>();
  for (const syns of Object.values(TAG_SYNONYMS)) {
    for (const s of syns) {
      if (seen.has(s)) ambiguous.add(s);
      seen.add(s);
    }
  }
  const m = new Map<string, string>();
  for (const tag of Object.keys(TAG_SYNONYMS)) m.set(tag, tag);
  for (const [tag, syns] of Object.entries(TAG_SYNONYMS)) {
    for (const s of syns) {
      if (!ambiguous.has(s) && !m.has(s)) m.set(s, tag);
    }
  }
  return m;
})();

/** The single tag a query term unambiguously names ("link" -> url,
 * "links" -> url via the singular), or null. */
export function tagIntentOf(term: string): string | null {
  const t = term.toLowerCase();
  const hit = TAG_INTENTS.get(t);
  if (hit) return hit;
  if (t.length > 3 && t.endsWith("s")) return TAG_INTENTS.get(t.slice(0, -1)) ?? null;
  return null;
}
