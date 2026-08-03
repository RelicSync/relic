"""Validates relic-core/relics.sql: FTS search behaviors, triggers, index consistency.

Run: python scripts/test_schema.py
Stand-in until relic-core's Rust tests exist (rusqlite bundles the same FTS5).
"""
import sqlite3
import sys
from pathlib import Path

SQL = (Path(__file__).parent.parent / "relic-core" / "relics.sql").read_text()

results = []


def check(name, ok):
    results.append((name, ok))
    print(("PASS  " if ok else "FAIL  ") + name)


def insert(db, uid, kind, content, preview, **kw):
    cols = dict(
        uid=uid, created_at=kw.get("created_at", 1000), updated_at=kw.get("updated_at", 1000),
        kind=kind, source=kw.get("source", "clipboard"), promoted=kw.get("promoted", 0),
        byte_size=len(content or ""), filename=kw.get("filename"), tags=kw.get("tags", ""),
        user_tags=kw.get("user_tags", ""), title=kw.get("title"), collection=kw.get("collection"),
        note=kw.get("note"), content=content, preview=preview,
    )
    db.execute(
        f"INSERT INTO relics ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
        list(cols.values()),
    )


def search(db, query, extra="", params=()):
    return [r[0] for r in db.execute(
        "SELECT r.uid FROM relics_fts f JOIN relics r ON r.id = f.rowid "
        f"WHERE relics_fts MATCH ? {extra} ORDER BY bm25(relics_fts)", (query, *params))]


def main():
    db = sqlite3.connect(":memory:")
    db.executescript(SQL)

    insert(db, "u1", "string", "the quick brown fox jumps", "the quick brown…", created_at=100)
    insert(db, "u2", "string", "SELECT * FROM users WHERE quicksand", "SELECT * FROM…",
           tags="code,sql", created_at=200)
    insert(db, "u3", "photo", None, "screenshot.png", filename="screenshot-quarterly.png",
           created_at=300)
    insert(db, "u4", "file", None, "report.pdf", filename="quarterly-report.pdf",
           promoted=1, title="Q2 board report", note="sent to finance", created_at=400)
    insert(db, "u5", "string", "https://example.com/quick-start", "https://example.com…",
           tags="url", created_at=500)

    check("prefix search across kinds", set(search(db, "quick*")) >= {"u1", "u2", "u5"})
    check("kind filter", search(db, "quarterly*", "AND r.kind = ?", ("file",)) == ["u4"])
    check("boolean AND", search(db, "quick AND fox") == ["u1"])
    check("phrase query", search(db, '"quick brown fox"') == ["u1"])
    check("filename search", set(search(db, "screenshot*")) == {"u3"})
    check("title/note search", search(db, "board OR finance") == ["u4"])
    check("tag search", search(db, "tags:url") == ["u5"])
    check("stream view excludes vault", [r[0] for r in db.execute(
        "SELECT uid FROM relics WHERE promoted=0 ORDER BY created_at DESC")] == ["u5", "u3", "u2", "u1"])

    # update trigger: promote u1 + retitle, then search the new title
    db.execute("UPDATE relics SET promoted=1, title='fox pangram', updated_at=600 WHERE uid='u1'")
    check("update trigger reindexes", search(db, "pangram") == ["u1"])

    # delete + index consistency (the prune path)
    db.execute("DELETE FROM relics WHERE uid='u2'")
    check("delete removes from fts", search(db, "quicksand") == [])

    try:
        db.execute("INSERT INTO relics_fts(relics_fts) VALUES('integrity-check')")
        check("fts external-content integrity", True)
    except sqlite3.DatabaseError as e:
        check(f"fts external-content integrity ({e})", False)

    sys.exit(1 if any(not ok for _, ok in results) else 0)


if __name__ == "__main__":
    main()
