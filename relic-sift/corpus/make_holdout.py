#!/usr/bin/env python3
"""Held-out golden set (spec §14): items generated AFTER threshold/prototype
tuning, evaluated with no further tuning. Fresh secrets, fresh photo seeds,
fresh renders — same generators style as make_corpus.py but distinct content.
"""

import io
import json
import os
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).parent
HOLD = ROOT / "holdout"
(HOLD / "text").mkdir(parents=True, exist_ok=True)
(HOLD / "files").mkdir(parents=True, exist_ok=True)
(HOLD / "images").mkdir(parents=True, exist_ok=True)

MANIFEST = []


def add(path, kind, primary, any_of=None, labels=None, relic_tags=None, note=""):
    MANIFEST.append(
        {
            "path": path.relative_to(HOLD).as_posix(),
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
    p = HOLD / "text" / name
    p.write_text(content, encoding="utf-8", newline="\n")
    add(p, "string", primary, **kw)


text_item("gitlab_pat.txt", "glpat-zY9xW7vU5tS3rQ1pN8mK", "api_key", relic_tags=["secret"])
text_item(
    "sendgrid_key.txt",
    "SG.mK3nP5qR7tV9xZ1bD4fH.jL6nQ8sU0wY2aC4eG6iK8mO0qS2uW4yA6cE8gI0kM",
    "api_key",
    relic_tags=["secret"],
)
text_item(
    "ssh_private_key.txt",
    "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nQyNTUxOQAAACBkZmFrZWtleWZha2VrZXlmYWtla2V5ZmFrZWtleWZha2VrZXk\n-----END OPENSSH PRIVATE KEY-----",
    "secret_other",
    relic_tags=["secret"],
)
text_item(
    "go_code.txt",
    'func walk(root string, ch chan<- string) error {\n\treturn filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {\n\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n\t\tif !d.IsDir() {\n\t\t\tch <- p\n\t\t}\n\t\treturn nil\n\t})\n}\n',
    "code",
    relic_tags=["code"],
)
text_item(
    "nginx_log.txt",
    '203.0.113.42 - - [11/Jun/2026:14:55:02 +0000] "GET /api/v1/relics?cursor=abc HTTP/1.1" 200 4821 "-" "relic-app/0.1"\n203.0.113.42 - - [11/Jun/2026:14:55:09 +0000] "POST /api/v1/relics HTTP/1.1" 201 89 "-" "relic-app/0.1"\n',
    "log_line",
    any_of=["structured_data", "code"],
    relic_tags=["log"],
    note="nginx access log has no ISO-timestamp line starts — harder",
)
text_item(
    "whatsapp_chat.txt",
    "u up? the game starts in 20\nyeah omw, grabbing snacks\nget the spicy ones 🌶️\nobviously\n",
    "chat_message",
    relic_tags=["chat"],
)
text_item(
    "email_reply.txt",
    "Hi Tom,\n\nGood catch — the figures in column C were stale. I've refreshed the export and re-shared the sheet, so the totals should reconcile now.\n\nOn the renewal question: legal wants one more pass, expect redlines Monday.\n\nThanks,\nRuth",
    "email_body",
    relic_tags=["mail"],
)
text_item(
    "recipe_note.txt",
    "Brine the chicken at least four hours, overnight is better. Dry well before it hits the pan or the skin never crisps. Finish with the lemon butter off heat so it doesn't split.",
    "note_prose",
    relic_tags=["note"],
)
text_item(
    "toml_config.txt",
    '[package]\nname = "relic-sift"\nedition = "2021"\n\n[dependencies]\nserde = { version = "1", features = ["derive"] }\nregex = "1"\n',
    "structured_data",
    any_of=["code"],
    relic_tags=["data"],
)
text_item(
    "url_fragment.txt",
    "https://doc.rust-lang.org/book/ch16-03-shared-state.html#atomic-reference-counting-with-arct",
    "url",
    relic_tags=["url"],
)
text_item(
    "address_pii.txt",
    "Shipping: Dana Whitfield, 442 Alder Lane, Portland OR 97214. Phone 503-555-0142. Leave at side door.",
    "note_prose",
    any_of=["chat_message", "structured_data", "unsorted", "address"],
    labels=["pii_present"],
    relic_tags=["pii"],
)

# --- files ---


def make_pdf(path, lines):
    def esc(s):
        return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

    content = "BT /F1 12 Tf 14 TL 72 720 Td\n" + "".join(f"({esc(l)}) Tj T*\n" for l in lines) + "ET"
    cb = content.encode("latin-1", "replace")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(cb)).encode() + b" >>\nstream\n" + cb + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offs = []
    for i, body in enumerate(objs, 1):
        offs.append(out.tell())
        out.write(f"{i} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objs)+1}\n".encode() + b"0000000000 65535 f \n")
    for o in offs:
        out.write(f"{o:010d} 00000 n \n".encode())
    out.write(f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF".encode())
    path.write_bytes(out.getvalue())


p = HOLD / "files" / "minutes.pdf"
make_pdf(
    p,
    [
        "Town hall minutes - June 9, 2026",
        "",
        "Attendance was the highest this year. The committee approved the",
        "park renovation budget by a wide margin and tabled the parking",
        "ordinance until traffic counts are available in September.",
        "Public comment ran long; three residents raised drainage issues",
        "on Alder Lane which were referred to public works.",
    ],
)
add(p, "file", "note_prose", any_of=["email_body", "file_pdf"], note="held-out pdf")

# --- images ---

FONTS = "C:/Windows/Fonts"


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def fetch_photo(name, seed, w=1400, hgt=1050):
    dest = HOLD / "images" / name
    if dest.exists() and dest.stat().st_size > 30_000:
        return dest
    url = f"https://picsum.photos/seed/{seed}/{w}/{hgt}.jpg"
    req = urllib.request.Request(url, headers={"User-Agent": "relic-sift-corpus/0.1"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as out:
        out.write(r.read())
    return dest


for i, seed in enumerate(["relic-h-alpha", "relic-h-beta", "relic-h-gamma"], 1):
    add(fetch_photo(f"photo_h{i}.jpg", seed), "image", "photo", relic_tags=["photo"], note=f"holdout picsum {seed}")


def receipt_pharmacy():
    w, h = 460, 560
    img = Image.new("RGB", (w, h), (253, 253, 251))
    d = ImageDraw.Draw(img)
    big = font("consolab.ttf", 26)
    mono = font("consola.ttf", 21)
    y = 26
    d.text((110, y), "CITY PHARMACY", font=big, fill=(10, 10, 10))
    y += 46
    d.text((28, y), "STORE 0142  2026-06-08 09:14", font=mono, fill=(60, 60, 60))
    y += 40
    for label, price in [("IBUPROFEN 200MG", 7.99), ("BAND-AID ASST", 4.29), ("VITAMIN D3 90CT", 11.49)]:
        d.text((28, y), label, font=mono, fill=(20, 20, 20))
        d.text((w - 90, y), f"{price:.2f}", font=mono, fill=(20, 20, 20))
        y += 32
    y += 8
    for label, val in [("SUBTOTAL", 23.77), ("TAX", 0.00), ("TOTAL", 23.77)]:
        d.text((28, y), label, font=mono, fill=(10, 10, 10))
        d.text((w - 110, y), f"${val:.2f}", font=mono, fill=(10, 10, 10))
        y += 32
    d.text((28, y), "CASH TENDER   $25.00", font=mono, fill=(60, 60, 60))
    y += 32
    d.text((28, y), "CHANGE         $1.23", font=mono, fill=(60, 60, 60))
    out = HOLD / "images" / "receipt_pharmacy.png"
    img.save(out)
    return out


add(receipt_pharmacy(), "image", "receipt", any_of=["document_scan"], relic_tags=["receipt"])


def browser_screenshot():
    w, h = 1920, 1080
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 44], fill=(222, 225, 230))  # tab strip
    d.rounded_rectangle([10, 8, 320, 40], 10, fill=(245, 246, 248))
    d.text((28, 14), "Relic — private capture", font=font("segoeui.ttf", 15), fill=(50, 50, 50))
    d.rectangle([0, 44, w, 92], fill=(243, 244, 246))  # url bar
    d.rounded_rectangle([180, 52, w - 180, 84], 16, fill=(255, 255, 255), outline=(210, 212, 216))
    d.text((204, 58), "https://relic.example.com/vault", font=font("segoeui.ttf", 17), fill=(70, 70, 70))
    d.text((140, 160), "Your vault", font=font("segoeuib.ttf", 46), fill=(17, 17, 17))
    f = font("segoeui.ttf", 22)
    rows = [
        ("API keys", "12 items - updated today"),
        ("Receipts 2026", "38 items - updated yesterday"),
        ("Trip ideas", "9 items - updated last week"),
    ]
    y = 260
    for title, sub in rows:
        d.rounded_rectangle([140, y, w - 140, y + 110], 14, fill=(248, 249, 251), outline=(228, 230, 234))
        d.text((170, y + 22), title, font=font("segoeuib.ttf", 26), fill=(20, 20, 20))
        d.text((170, y + 62), sub, font=f, fill=(110, 110, 115))
        y += 136
    out = HOLD / "images" / "screenshot_browser.png"
    img.save(out)
    return out


add(browser_screenshot(), "image", "screenshot", relic_tags=["screenshot"], note="synthetic browser screenshot")

(HOLD / "manifest.json").write_text(json.dumps({"items": MANIFEST}, indent=2), encoding="utf-8")
print(f"holdout: {len(MANIFEST)} items -> {HOLD / 'manifest.json'}")
