#!/usr/bin/env python3
"""Build the relic-sift evaluation corpus (spec §14 golden set).

Generates labeled items across all three modalities:
- text strings (secrets, urls, code, logs, chat, email, prose, configs, PII)
- documents (pdf, docx, html, md, json, csv, yaml, zip, raw binary)
- images (real + synthetic screenshots, downloaded photos, rendered
  receipts / document scans / diagrams / memes)

Photos come from Lorem Picsum (free, seeded → reproducible). All secrets are
documented example values (AWS docs key, etc.) — nothing real.

Run:  python make_corpus.py            (writes into this directory)
"""

import io
import json
import os
import random
import struct
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).parent
TEXT = ROOT / "text"
FILES = ROOT / "files"
IMAGES = ROOT / "images"
for d in (TEXT, FILES, IMAGES):
    d.mkdir(parents=True, exist_ok=True)

MANIFEST = []


def add(path: Path, kind: str, primary: str, any_of=None, labels=None, relic_tags=None, note=""):
    MANIFEST.append(
        {
            "path": path.relative_to(ROOT).as_posix(),
            "kind": kind,
            "gold": {
                "primary": primary,
                "any_of": any_of or [],
                "labels": labels or [],
                "relic_tags": relic_tags or [],
            },
            "note": note,
        }
    )


def text_item(name, content, primary, **kw):
    p = TEXT / name
    p.write_text(content, encoding="utf-8", newline="\n")
    add(p, "string", primary, **kw)


# ---------------------------------------------------------------------------
# 1. Text strings
# ---------------------------------------------------------------------------

# secrets — all documented example/placeholder values
text_item("aws_key.txt", "AKIAIOSFODNN7EXAMPLE", "api_key", relic_tags=["secret"])
text_item(
    "github_token.txt",
    "ghp_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
    "api_key",
    relic_tags=["secret"],
)
text_item(
    "stripe_key.txt", "sk_test_4eC39HqLyjWDarjtT1zdp7dc", "api_key", relic_tags=["secret"]
)
text_item(
    "google_api_key.txt",
    "AIzaSyA1bC2dE3fG4hI5jK6lM7nO8pQ9rS0tUvW",
    "api_key",
    relic_tags=["secret"],
)
text_item(
    "slack_token.txt",
    "xoxb-210987654321-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",
    "api_key",
    relic_tags=["secret"],
)
text_item(
    "jwt.txt",
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    "secret_other",
    relic_tags=["secret"],
)
text_item(
    "pem_key.txt",
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA7Zw9vJxQ2kYfL1mN3pQ5rS7tU9vW1xY3zA5cE7gI9kM1oQ3s\nU5wY7aC9eG1iK3mO5qS7uW9yA1cE3gI5kM7oQ9sU1wY3aC5eG7iK9mO1qS3uW5y\n-----END RSA PRIVATE KEY-----",
    "secret_other",
    relic_tags=["secret"],
)
text_item(
    "high_entropy_token.txt", "xK9mP2vQ7rT4wY8zB3nF6hJ1dL5gC0aS", "secret_other", relic_tags=["secret"]
)
text_item(
    "env_file.txt",
    "DB_HOST=localhost\nDB_PORT=5432\nAPI_KEY=q7zP2vXr9kT4wY8mB3nF6hJ1dL5gC0aS\nDEBUG=false\n",
    "api_key",
    relic_tags=["secret"],
    note="assigned secret inside an .env blob",
)

# urls
text_item("url_plain.txt", "https://news.ycombinator.com/item?id=39281472", "url", relic_tags=["url"])
text_item(
    "url_long_query.txt",
    "https://www.google.com/maps/place/Golden+Gate+Bridge/@37.8199286,-122.4804438,17z/data=!3m1!4b1",
    "url",
    relic_tags=["url"],
)

# structural one-liners — primary is honest "unsorted"; the relic tag is the point
STRUCTURAL_ANY = ["chat_message", "note_prose", "structured_data", "log_line"]
text_item(
    "email_address.txt",
    "jane.doe+newsletter@example.co.uk",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    labels=["pii_present"],
    relic_tags=["email"],
)
text_item(
    "phone_number.txt",
    "+1 (555) 123-4567",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    labels=["pii_present"],
    relic_tags=["phone"],
)
text_item("ipv4.txt", "192.168.50.114", "unsorted", any_of=STRUCTURAL_ANY, relic_tags=["ip"])
text_item("hex_color.txt", "#7C3AED", "unsorted", any_of=STRUCTURAL_ANY, relic_tags=["color"])
text_item(
    "win_path.txt",
    r"C:\Users\jorda\Documents\taxes\2025_return_final.pdf",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    relic_tags=["path"],
)

# code
text_item(
    "python_code.txt",
    "import asyncio\n\nasync def fetch_all(urls):\n    async with aiohttp.ClientSession() as session:\n        tasks = [fetch(session, u) for u in urls]\n        return await asyncio.gather(*tasks)\n",
    "code",
    relic_tags=["code", "python"],
)
text_item(
    "rust_code.txt",
    "fn parse_header(input: &[u8]) -> Result<Header, ParseError> {\n    let magic = u32::from_le_bytes(input[..4].try_into()?);\n    if magic != MAGIC {\n        return Err(ParseError::BadMagic);\n    }\n    Ok(Header { magic, version: input[4] })\n}\n",
    "code",
    relic_tags=["code", "rust"],
)
text_item(
    "js_code.txt",
    "const debounce = (fn, ms) => {\n  let timer;\n  return (...args) => {\n    clearTimeout(timer);\n    timer = setTimeout(() => fn(...args), ms);\n  };\n};\n",
    "code",
    relic_tags=["code", "javascript"],
)
text_item(
    "sql_query.txt",
    "SELECT u.id, u.email, COUNT(o.id) AS order_count\nFROM users u\nLEFT JOIN orders o ON o.user_id = u.id\nWHERE u.created_at > '2026-01-01'\nGROUP BY u.id, u.email\nHAVING COUNT(o.id) > 5\nORDER BY order_count DESC;\n",
    "code",
    relic_tags=["sql"],
)

# logs
text_item(
    "log_server.txt",
    "2026-06-11T14:23:01Z ERROR api.server request failed: connection reset by peer (retry 3/5)\n2026-06-11T14:23:02Z WARN  api.server circuit breaker open for upstream billing\n2026-06-11T14:23:04Z INFO  api.server retry succeeded after 2.1s\n",
    "log_line",
    relic_tags=["log"],
)
text_item(
    "log_syslog.txt",
    "Jun 11 03:12:44 web01 sshd[1023]: Failed password for invalid user admin from 203.0.113.7 port 53121 ssh2\nJun 11 03:12:46 web01 sshd[1023]: Connection closed by invalid user admin 203.0.113.7 port 53121 [preauth]\n",
    "log_line",
    relic_tags=["log"],
)
text_item(
    "stack_trace_python.txt",
    'Traceback (most recent call last):\n  File "app.py", line 42, in <module>\n    main()\n  File "app.py", line 31, in main\n    cfg = load_config(path)\nValueError: invalid literal for int() with base 10: \'abc\'\n',
    "log_line",
    any_of=["code"],
    relic_tags=["log"],
)

# chat
text_item("chat_short.txt", "omg no way 😂 ok ok see you at 8, bring marco", "chat_message", relic_tags=["chat"])
text_item(
    "chat_thread.txt",
    "[10:42] mike: did you push the fix yet\n[10:43] ana: yeah it's on main\n[10:43] mike: nice, deploying now\n[10:45] ana: 🤞\n",
    "chat_message",
    relic_tags=["chat"],
)

# email bodies
text_item(
    "email_body_work.txt",
    "Hi Sarah,\n\nThanks for sending over the revised contract. I went through the redlines and everything looks good except clause 7.2 — can we keep the original termination notice period?\n\nCould we do a quick call Thursday morning to close this out?\n\nBest,\nMark",
    "email_body",
    relic_tags=["mail"],
)
text_item(
    "email_body_support.txt",
    "Hello support team,\n\nMy order #48213 arrived yesterday but the box was damaged and the mug inside is cracked. I'd like a replacement or a refund. I've attached photos of the packaging.\n\nThank you,\nEmily Carter",
    "email_body",
    relic_tags=["mail"],
)

# notes / prose
text_item(
    "note_meeting.txt",
    "Meeting takeaways: budget approved for Q3, hiring freeze lifted for infra roles only. Sarah owns the migration plan, first draft due Friday. Office space decision deferred again.",
    "note_prose",
    relic_tags=["note"],
)
text_item(
    "note_grocery.txt",
    "eggs, oat milk, basil, chicken thighs, parmesan, sourdough, olive oil, lemons",
    "note_prose",
    any_of=["chat_message", "todo_list"],
    relic_tags=["note"],
)
text_item(
    "note_essay.txt",
    "Over the past decade, cities have quietly rebuilt themselves around delivery logistics rather than people. Curb space that once held trees and benches now stages vans; ground-floor retail gives way to dark stores. The shift happened without a single vote being cast on it.",
    "note_prose",
    relic_tags=["note"],
)
text_item(
    "markdown_doc.txt",
    "# Migration plan\n\n## Phase 1\n\n- Freeze schema changes\n- Snapshot prod into staging\n\n## Phase 2\n\n- Dual-write for one week\n- Cut over reads, watch [dashboards](https://grafana.example.com/d/abc)\n",
    "note_prose",
    relic_tags=["markdown", "note"],
)

# structured data
text_item(
    "json_payload.txt",
    '{"user": {"id": 4821, "name": "Ana", "roles": ["admin", "dev"]}, "active": true, "last_login": "2026-06-10T22:14:03Z"}',
    "structured_data",
    relic_tags=["json", "data"],
)
text_item(
    "yaml_config.txt",
    "server:\n  host: 0.0.0.0\n  port: 8080\nlogging:\n  level: info\n  format: json\nfeatures:\n  dark_mode: true\n",
    "structured_data",
    relic_tags=["data", "yaml"],
)
text_item(
    "xml_snippet.txt",
    '<configuration>\n  <appSettings>\n    <add key="timeout" value="30"/>\n    <add key="retries" value="3"/>\n  </appSettings>\n</configuration>',
    "structured_data",
    relic_tags=["data", "xml"],
)
text_item(
    "csv_table.txt",
    "id,name,email,signup_date\n1,Ana,ana@example.com,2026-01-15\n2,Ben,ben@example.com,2026-02-20\n3,Iris,iris@example.com,2026-03-08\n",
    "structured_data",
    labels=["pii_present"],
    relic_tags=["data", "csv"],
)

# PII in prose
text_item(
    "credit_card_note.txt",
    "Card on file for the booking: 4111 1111 1111 1111, exp 12/28. Cancel before the 14th to avoid the fee.",
    "note_prose",
    any_of=["chat_message", "unsorted", "structured_data"],
    labels=["pii_present"],
)

# ---------------------------------------------------------------------------
# 1b. Granular v1.2: tracking, otp, address, todo, structural shapes
# ---------------------------------------------------------------------------

text_item("tracking_ups.txt", "1Z999AA10123456784", "tracking_number", relic_tags=["tracking"])
text_item(
    "tracking_usps.txt",
    "Your package is on the way! USPS tracking: 9405511206218889777712 - expected Thursday.",
    "tracking_number",
    relic_tags=["tracking"],
)
text_item(
    "otp_sms.txt",
    "Your Relic verification code is 482913. It expires in 10 minutes. Don't share it with anyone.",
    "otp_code",
    relic_tags=["otp"],
)
text_item("otp_bare.txt", "739204", "otp_code", any_of=["unsorted"], relic_tags=["otp"])
text_item(
    "address_office.txt",
    "1600 Amphitheatre Parkway, Mountain View, CA 94043",
    "address",
    any_of=["note_prose", "unsorted"],
    relic_tags=["address"],
)
text_item(
    "address_shipping.txt",
    "Ship to:\nMarcus Webb\n318 Juniper Court, Unit 12\nBoulder, CO 80302",
    "address",
    any_of=["note_prose", "structured_data"],
    relic_tags=["address"],
)
text_item(
    "todo_checkbox.txt",
    "- [ ] book flights\n- [ ] renew passport before May\n- [x] request time off\n- [ ] travel insurance quotes",
    "todo_list",
    any_of=["note_prose"],
    relic_tags=["todo"],
)
text_item(
    "todo_numbered.txt",
    "1. send the invoice to Carlton\n2. follow up with the vendor about the late shipment\n3. update the budget spreadsheet\n4. archive closed tickets",
    "todo_list",
    any_of=["note_prose"],
    relic_tags=["todo"],
)
text_item(
    "uuid.txt",
    "550e8400-e29b-41d4-a716-446655440000",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    relic_tags=["uuid"],
    note="must NOT tag secret (public identifier)",
)
text_item("version_string.txt", "v2.14.3", "unsorted", any_of=STRUCTURAL_ANY, relic_tags=["version"])
text_item(
    "eth_address.txt",
    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    relic_tags=["crypto"],
    note="must NOT tag secret (public address)",
)
text_item("geo_coords.txt", "37.8199, -122.4804", "unsorted", any_of=STRUCTURAL_ANY, relic_tags=["geo"])
text_item(
    "iban.txt",
    "GB82WEST12345698765432",
    "unsorted",
    any_of=STRUCTURAL_ANY,
    labels=["pii_present"],
    relic_tags=["iban"],
)

# ---------------------------------------------------------------------------
# 2. Documents / files
# ---------------------------------------------------------------------------


def make_pdf(path: Path, lines):
    """Minimal but valid single-page PDF with Helvetica text."""

    def esc(s):
        return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

    content = "BT /F1 12 Tf 14 TL 72 720 Td\n"
    for ln in lines:
        content += f"({esc(ln)}) Tj T*\n"
    content += "ET"
    content_b = content.encode("latin-1", "replace")

    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(content_b)).encode() + b" >>\nstream\n" + content_b + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(out.tell())
        out.write(f"{i} 0 obj\n".encode())
        out.write(body)
        out.write(b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objs)+1}\n".encode())
    out.write(b"0000000000 65535 f \n")
    for off in offsets:
        out.write(f"{off:010d} 00000 n \n".encode())
    out.write(
        f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF".encode()
    )
    path.write_bytes(out.getvalue())


make_pdf(
    FILES / "report.pdf",
    [
        "Quarterly retrospective - June 2026",
        "",
        "The migration finished two weeks ahead of schedule. Error budgets",
        "held through the cutover and support volume stayed flat, which",
        "suggests the dual-write rehearsal was worth the extra sprint.",
        "Next quarter we focus on deleting the legacy read path entirely.",
    ],
)
add(FILES / "report.pdf", "file", "note_prose", any_of=["email_body", "file_pdf"], note="prose pdf")

make_pdf(
    FILES / "letter.pdf",
    [
        "Dear Ms. Alvarez,",
        "",
        "Thank you for your application. We are pleased to confirm your",
        "appointment has been scheduled for June 24th at 10:30 AM at our",
        "Market Street office. Please bring a valid photo ID.",
        "",
        "Kind regards,",
        "Records Department",
    ],
)
add(FILES / "letter.pdf", "file", "email_body", any_of=["note_prose", "file_pdf"], note="letter pdf")


def make_docx(path: Path, paragraphs):
    doc_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        + "".join(f"<w:p><w:r><w:t>{p}</w:t></w:r></w:p>" for p in paragraphs)
        + "</w:body></w:document>"
    )
    ct = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        "</Relationships>"
    )
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", doc_xml)


make_docx(
    FILES / "spec.docx",
    [
        "Design note: capture pipeline",
        "The watcher batches clipboard events and debounces duplicates within a two second window.",
        "Each captured item is classified locally before encryption; nothing leaves the device unencrypted.",
        "Open question: should file copies above 25 MB be skipped or chunked?",
    ],
)
add(FILES / "spec.docx", "file", "note_prose", any_of=["email_body", "file_office"], note="docx prose")

(FILES / "page.html").write_text(
    """<!doctype html>
<html><head><title>Sourdough, slower</title><style>body{font:16px serif}</style>
<script>console.log("hi");</script></head>
<body><h1>Sourdough, slower</h1>
<p>Most recipes rush the levain. Give it a full twelve hours at room
temperature and the crumb opens up without any change to hydration.
The second proof can then happen overnight in the fridge, which makes
the morning bake almost effortless.</p>
<p>Scoring matters less than people think; oven steam matters more.</p>
</body></html>""",
    encoding="utf-8",
)
add(FILES / "page.html", "file", "note_prose", any_of=["email_body"], note="html article")

(FILES / "readme.md").write_text(
    "# capture-tool\n\nSmall utility for relic development.\n\n## Usage\n\n- `capture --watch` to start the clipboard watcher\n- `capture --dump` to print the local queue\n\nSee [docs](https://example.com/docs) for the full flag list.\n",
    encoding="utf-8",
)
add(FILES / "readme.md", "file", "note_prose", any_of=["code", "structured_data"], relic_tags=["markdown"], note="markdown readme")

(FILES / "config.json").write_text(
    '{\n  "sync": {"endpoint": "https://relic.example.com", "interval_s": 30},\n  "capture": {"max_bytes": 26214400, "skip_apps": ["KeePass", "1Password"]},\n  "ui": {"hotkey": "Ctrl+Shift+V", "theme": "dark"}\n}\n',
    encoding="utf-8",
)
add(FILES / "config.json", "file", "structured_data", relic_tags=["json", "data"], note="json config file")

(FILES / "data.csv").write_text(
    "sku,description,qty,unit_price\nA-1041,USB-C cable 2m,140,6.50\nA-1042,USB-C cable 0.5m,80,4.10\nB-2200,Wall charger 65W,55,24.00\nB-2201,Wall charger 30W,120,15.50\n",
    encoding="utf-8",
)
add(FILES / "data.csv", "file", "structured_data", relic_tags=["data", "csv"], note="csv inventory")

(FILES / "app_config.yaml").write_text(
    "database:\n  url: postgres://localhost:5432/relic\n  pool_size: 8\ncache:\n  backend: redis\n  ttl_seconds: 600\nworkers: 4\n",
    encoding="utf-8",
)
add(FILES / "app_config.yaml", "file", "structured_data", relic_tags=["data", "yaml"], note="yaml config")

with zipfile.ZipFile(FILES / "archive.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("notes/todo.txt", "ship it")
    z.writestr("notes/done.txt", "scaffolded")
add(FILES / "archive.zip", "file", "file_archive", relic_tags=["file", "archive"], note="zip archive")

rng = random.Random(42)
(FILES / "random.bin").write_bytes(bytes([0xFF, 0xFE]) + bytes(rng.randrange(256) for _ in range(4096)))
add(FILES / "random.bin", "file", "file_binary", relic_tags=["file"], note="opaque binary")

# ---------------------------------------------------------------------------
# 3. Images
# ---------------------------------------------------------------------------

FONTS = "C:/Windows/Fonts"


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def save(img, name):
    img.save(IMAGES / name)
    return IMAGES / name


# real screenshot was captured separately; register it if present
shot = IMAGES / "screenshot_desktop_full.png"
if shot.exists():
    add(shot, "image", "screenshot", relic_tags=["screenshot"], note="real full-desktop capture")


def synth_code_editor():
    w, h = 1600, 1000
    img = Image.new("RGB", (w, h), (30, 30, 30))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 36], fill=(50, 50, 54))  # title bar
    d.text((12, 9), "main.rs — relic-sift — Visual Studio Code", font=font("segoeui.ttf", 15), fill=(200, 200, 200))
    d.rectangle([0, 36, 64, h], fill=(40, 40, 44))  # activity bar
    d.rectangle([64, 36, 320, h], fill=(37, 37, 40))  # explorer
    files = ["src", "  lib.rs", "  pipeline.rs", "  fusion.rs", "  taxonomy.rs", "Cargo.toml", "README.md"]
    for i, f in enumerate(files):
        d.text((84, 60 + i * 26), f, font=font("segoeui.ttf", 14), fill=(170, 170, 175))
    code = [
        ("pub fn fuse(votes: &[Vote], taxonomy: &Taxonomy) -> Outcome {", (220, 220, 170)),
        ("    let mut combined: BTreeMap<String, f32> = BTreeMap::new();", (156, 220, 254)),
        ("    for v in votes {", (197, 134, 192)),
        ("        let p = combined.entry(v.category.clone()).or_insert(0.0);", (156, 220, 254)),
        ("        *p = 1.0 - (1.0 - *p) * (1.0 - v.score);", (181, 206, 168)),
        ("    }", (212, 212, 212)),
        ("    // deterministic rules win outright at >= 0.95", (106, 153, 85)),
        ("    let rule = votes.iter().filter(|v| v.is_rule()).max();", (156, 220, 254)),
        ("    Outcome::from(combined, rule)", (220, 220, 170)),
        ("}", (212, 212, 212)),
    ]
    mono = font("consola.ttf", 18)
    for i, (line, color) in enumerate(code):
        d.text((344, 64 + i * 28), f"{i+1:>3}", font=mono, fill=(120, 120, 120))
        d.text((404, 64 + i * 28), line, font=mono, fill=color)
    d.rectangle([0, h - 28, w, h], fill=(0, 122, 204))  # status bar
    d.text((12, h - 24), "main*  Rust  UTF-8  Ln 9, Col 5", font=font("segoeui.ttf", 13), fill=(255, 255, 255))
    return save(img, "screenshot_code_editor.png")


add(synth_code_editor(), "image", "screenshot", any_of=["api_key"], relic_tags=["screenshot"], note="synthetic IDE screenshot")


def synth_chat_app():
    w, h = 750, 1334  # iPhone-ish portrait
    img = Image.new("RGB", (w, h), (242, 242, 247))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 110], fill=(248, 248, 250))
    d.text((w // 2 - 40, 50), "Marco", font=font("segoeuib.ttf", 30), fill=(20, 20, 20))
    msgs = [
        ("hey, dinner still on for tonight?", False),
        ("yes! luigi's at 8", True),
        ("should I book or you got it", False),
        ("already booked, table for 4", True),
        ("perfect 👌 see you there", False),
        ("bring the cable you borrowed btw", True),
        ("lol fine", False),
    ]
    y = 150
    f = font("segoeui.ttf", 24)
    for text, mine in msgs:
        tw = d.textlength(text, font=f)
        bw = tw + 36
        x0 = w - bw - 20 if mine else 20
        color = (0, 122, 255) if mine else (229, 229, 234)
        tcol = (255, 255, 255) if mine else (20, 20, 20)
        d.rounded_rectangle([x0, y, x0 + bw, y + 56], 24, fill=color)
        d.text((x0 + 18, y + 13), text, font=f, fill=tcol)
        y += 76
    d.rounded_rectangle([20, h - 90, w - 20, h - 34], 26, outline=(200, 200, 205), width=2)
    d.text((40, h - 78), "iMessage", font=f, fill=(160, 160, 165))
    return save(img, "screenshot_chat_app.png")


add(synth_chat_app(), "image", "screenshot", any_of=["chat_message"], relic_tags=["screenshot"], note="synthetic phone chat screenshot")


def synth_terminal_secret():
    w, h = 1200, 700
    img = Image.new("RGB", (w, h), (12, 12, 16))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 34], fill=(40, 40, 46))
    d.text((12, 8), "PowerShell", font=font("segoeui.ttf", 14), fill=(210, 210, 210))
    mono = font("consola.ttf", 24)
    lines = [
        ("PS C:\\work> cat .\\deploy\\secrets.env", (220, 220, 220)),
        ("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", (250, 250, 250)),
        ("AWS_REGION=us-west-2", (190, 190, 190)),
        ("BUCKET=relic-blobs-prod", (190, 190, 190)),
        ("PS C:\\work> aws s3 ls s3://relic-blobs-prod | head", (220, 220, 220)),
        ("2026-06-01 11:02:13   84213 blob_01HZX4.bin", (140, 200, 140)),
        ("2026-06-01 11:02:15   90112 blob_01HZX5.bin", (140, 200, 140)),
    ]
    for i, (line, color) in enumerate(lines):
        d.text((24, 60 + i * 40), line, font=mono, fill=color)
    return save(img, "screenshot_terminal_apikey.png")


add(
    synth_terminal_secret(),
    "image",
    "api_key",
    any_of=["secret_other"],
    relic_tags=["secret"],
    note="spec §6.2: a screenshot of an API key must still be caught as api_key (OCR → Stage A)",
)


def receipt(name, store, items, note="Thank you for shopping!"):
    w = 480
    h = 220 + 34 * (len(items) + 5)
    img = Image.new("RGB", (w, h), (252, 252, 250))
    d = ImageDraw.Draw(img)
    big = font("consolab.ttf", 28)
    mono = font("consola.ttf", 22)
    y = 30
    d.text((w // 2 - d.textlength(store, font=big) // 2, y), store, font=big, fill=(10, 10, 10))
    y += 50
    d.text((30, y), "2026-06-11 17:42   REG 04", font=mono, fill=(60, 60, 60))
    y += 44
    d.text((30, y), "-" * 32, font=mono, fill=(120, 120, 120))
    y += 34
    subtotal = 0.0
    for label, price in items:
        subtotal += price
        d.text((30, y), label[:20], font=mono, fill=(20, 20, 20))
        p = f"{price:.2f}"
        d.text((w - 30 - d.textlength(p, font=mono), y), p, font=mono, fill=(20, 20, 20))
        y += 34
    tax = round(subtotal * 0.0825, 2)
    d.text((30, y), "-" * 32, font=mono, fill=(120, 120, 120))
    y += 34
    for label, val in [("SUBTOTAL", subtotal), ("TAX 8.25%", tax), ("TOTAL", subtotal + tax)]:
        v = f"${val:.2f}"
        d.text((30, y), label, font=mono, fill=(10, 10, 10))
        d.text((w - 30 - d.textlength(v, font=mono), y), v, font=mono, fill=(10, 10, 10))
        y += 34
    d.text((30, y), "VISA  ****1111   APPROVED", font=mono, fill=(60, 60, 60))
    y += 44
    d.text((w // 2 - d.textlength(note, font=mono) // 2, y), note, font=mono, fill=(90, 90, 90))
    return save(img, name)


add(
    receipt(
        "receipt_grocery.png",
        "GREENLEAF MARKET",
        [("ORGANIC EGGS 12CT", 5.99), ("OAT MILK 1L", 4.49), ("BASIL FRESH", 2.99), ("CHICKEN THIGH LB", 8.47), ("PARMESAN WEDGE", 9.99), ("SOURDOUGH LOAF", 6.50)],
    ),
    "image",
    "receipt",
    any_of=["document_scan"],
    relic_tags=["receipt"],
)
add(
    receipt("receipt_cafe.png", "CORNER CAFE", [("CAPPUCCINO LG", 5.25), ("ALMOND CROISSANT", 4.75), ("DRIP REFILL", 1.50)]),
    "image",
    "receipt",
    any_of=["document_scan"],
    relic_tags=["receipt"],
)
add(
    receipt(
        "receipt_hardware.png",
        "ACE HARDWARE #214",
        [("WOOD SCREWS 100PK", 9.99), ("DRILL BIT SET", 24.99), ("PAINTERS TAPE 2IN", 6.49), ("SANDPAPER ASST", 7.99)],
        note="Returns within 30 days",
    ),
    "image",
    "receipt",
    any_of=["document_scan"],
    relic_tags=["receipt"],
)


def scan(name, title, paragraphs):
    w, h = 1240, 1754  # A4 @150dpi
    img = Image.new("RGB", (w, h), (250, 249, 246))
    d = ImageDraw.Draw(img)
    serif = font("georgia.ttf", 30)
    serif_b = font("georgiab.ttf", 40)
    y = 140
    d.text((120, y), title, font=serif_b, fill=(15, 15, 15))
    y += 110
    import textwrap

    for para in paragraphs:
        for line in textwrap.wrap(para, width=62):
            d.text((120, y), line, font=serif, fill=(25, 25, 25))
            y += 46
        y += 30
    # scanner artifacts: slight rotation + noise + soft blur
    img = img.rotate(-1.1, expand=True, fillcolor=(245, 244, 240), resample=Image.BICUBIC)
    px = img.load()
    r = random.Random(7)
    for _ in range(14000):
        x, yy = r.randrange(img.width), r.randrange(img.height)
        g = r.randrange(180, 235)
        px[x, yy] = (g, g, g)
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    return save(img, name)


add(
    scan(
        "scan_letter.png",
        "NOTICE OF ANNUAL INSPECTION",
        [
            "Dear resident, this letter is to inform you that the annual fire safety inspection for your building has been scheduled for Monday, June 29th, between 9:00 AM and 1:00 PM.",
            "Access to each unit is required. If you will not be home, please arrange key access with the building manager no later than June 25th.",
            "Smoke detectors will be tested and replaced where necessary at no cost to the resident. Please ensure hallways and exits are clear of obstructions.",
            "Thank you for your cooperation. Questions may be directed to the management office during regular business hours.",
        ],
    ),
    "image",
    "document_scan",
    any_of=["screenshot", "receipt"],
    relic_tags=["scan"],
)
add(
    scan(
        "scan_recipe.png",
        "GRANDMA'S PEACH COBBLER",
        [
            "Preheat the oven to 375 degrees. Melt one stick of butter directly in the baking dish while the oven warms.",
            "Whisk one cup of flour, one cup of sugar, and a tablespoon of baking powder with a pinch of salt. Stir in one cup of milk until just combined.",
            "Pour the batter over the melted butter without stirring. Spoon four cups of sliced peaches over the top, then sprinkle with cinnamon sugar.",
            "Bake forty five minutes until the edges are deep golden and the center springs back. Rest twenty minutes before serving.",
        ],
    ),
    "image",
    "document_scan",
    any_of=["screenshot", "receipt"],
    relic_tags=["scan"],
)


def diagram_flowchart():
    w, h = 1200, 800
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    f = font("segoeui.ttf", 22)
    fb = font("segoeuib.ttf", 26)
    d.text((30, 24), "sift classification pipeline", font=fb, fill=(20, 20, 20))

    def box(x, y, label, fill=(232, 240, 254), outline=(66, 103, 178)):
        bw, bh = 230, 80
        d.rounded_rectangle([x, y, x + bw, y + bh], 12, fill=fill, outline=outline, width=3)
        tw = d.textlength(label, font=f)
        d.text((x + (bw - tw) / 2, y + 26), label, font=f, fill=(20, 20, 20))
        return (x + bw, y + bh // 2, x + bw // 2, y + bh, x, y + bh // 2)

    def arrow(x0, y0, x1, y1):
        d.line([x0, y0, x1, y1], fill=(70, 70, 70), width=4)
        import math

        a = math.atan2(y1 - y0, x1 - x0)
        for da in (2.6, -2.6):
            d.line([x1, y1, x1 - 18 * math.cos(a + da) * -1 * -1, y1 - 18 * math.sin(a + da)], fill=(70, 70, 70), width=4)

    box(60, 140, "raw item")
    arrow(290, 180, 380, 180)
    box(380, 140, "normalize")
    arrow(610, 180, 700, 180)
    box(700, 140, "Stage A rules", fill=(254, 240, 215), outline=(202, 138, 4))
    arrow(815, 220, 815, 330)
    box(700, 330, "Stage B models", fill=(254, 226, 226), outline=(185, 28, 28))
    arrow(815, 410, 815, 520)
    box(700, 520, "fusion + gate", fill=(220, 252, 231), outline=(22, 101, 52))
    arrow(700, 560, 350, 560)
    box(120, 520, "record", fill=(237, 233, 254), outline=(109, 40, 217))
    return save(img, "diagram_flowchart.png")


add(diagram_flowchart(), "image", "diagram", any_of=["screenshot"], relic_tags=["diagram"])


def diagram_barchart():
    w, h = 1100, 750
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    fb = font("segoeuib.ttf", 28)
    f = font("segoeui.ttf", 20)
    d.text((60, 30), "Capture volume by week", font=fb, fill=(20, 20, 20))
    d.line([90, 650, 1040, 650], fill=(60, 60, 60), width=3)
    d.line([90, 650, 90, 100], fill=(60, 60, 60), width=3)
    vals = [120, 180, 165, 240, 310, 290, 405, 380]
    for i, v in enumerate(vals):
        x = 130 + i * 112
        bh = int(v * 1.3)
        d.rectangle([x, 650 - bh, x + 70, 650], fill=(59, 130, 246))
        d.text((x + 10, 660), f"W{i+1}", font=f, fill=(60, 60, 60))
        d.text((x + 8, 650 - bh - 30), str(v), font=f, fill=(40, 40, 40))
    return save(img, "diagram_barchart.png")


add(diagram_barchart(), "image", "diagram", any_of=["screenshot"], relic_tags=["diagram"])


def fetch_photo(name, seed, w=1200, hgt=900):
    dest = IMAGES / name
    if dest.exists() and dest.stat().st_size > 30_000:
        return dest
    url = f"https://picsum.photos/seed/{seed}/{w}/{hgt}.jpg"
    req = urllib.request.Request(url, headers={"User-Agent": "relic-sift-corpus/0.1"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as out:
        out.write(r.read())
    return dest


PHOTO_SEEDS = ["relic-mountain", "relic-city", "relic-forest", "relic-coast", "relic-meadow", "relic-river"]
for i, seed in enumerate(PHOTO_SEEDS, 1):
    p = fetch_photo(f"photo_{i:02d}_{seed.split('-')[1]}.jpg", seed)
    # seed relic-mountain happens to be a photo of two dachshunds — the one
    # content-tag gold we can assert (we've looked at it)
    tags = ["photo", "animal"] if seed == "relic-mountain" else ["photo"]
    add(p, "image", "photo", relic_tags=tags, note=f"picsum seed {seed}")


def meme(name, seed, top, bottom):
    base = fetch_photo(f"_meme_base_{seed}.jpg", seed, 900, 700)
    img = Image.open(base).convert("RGB")
    d = ImageDraw.Draw(img)
    f = font("impact.ttf", 84)

    def caption(text, y_anchor):
        tw = d.textlength(text, font=f)
        x = (img.width - tw) / 2
        y = 20 if y_anchor == "top" else img.height - 120
        for dx in (-3, 0, 3):
            for dy in (-3, 0, 3):
                d.text((x + dx, y + dy), text, font=f, fill=(0, 0, 0))
        d.text((x, y), text, font=f, fill=(255, 255, 255))

    caption(top, "top")
    caption(bottom, "bottom")
    out = IMAGES / name
    img.save(out)
    base.unlink(missing_ok=True)
    return out


add(
    meme("meme_deploy.png", "relic-meme1", "DEPLOYED ON FRIDAY", "SEE YOU MONDAY"),
    "image",
    "meme",
    any_of=["photo"],
    relic_tags=["meme"],
)
add(
    meme("meme_classifier.png", "relic-meme2", "ONE MORE REGEX", "IT'LL FIX EVERYTHING"),
    "image",
    "meme",
    any_of=["photo"],
    relic_tags=["meme"],
)

def qr_image():
    try:
        import qrcode
    except ImportError:
        print("qrcode lib missing (pip install qrcode); skipping QR item")
        return None
    qr = qrcode.QRCode(box_size=12, border=4)
    qr.add_data("https://relic.example.com/pair?device=desktop-01")
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    out = IMAGES / "qr_pairing.png"
    img.save(out)
    return out


p = qr_image()
if p:
    add(
        p,
        "image",
        "unsorted",
        any_of=["screenshot", "diagram", "meme", "document_scan", "photo"],
        relic_tags=["qrcode"],
        note="content tag is the point; the category of a bare QR is honestly ambiguous",
    )

# ---------------------------------------------------------------------------

(ROOT / "manifest.json").write_text(json.dumps({"items": MANIFEST}, indent=2), encoding="utf-8")
kinds = {}
for m in MANIFEST:
    kinds[m["kind"]] = kinds.get(m["kind"], 0) + 1
print(f"corpus: {len(MANIFEST)} items {kinds}")
print(f"manifest: {(ROOT / 'manifest.json')}")
