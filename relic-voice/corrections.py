"""Explicit replacements and preferred spelling. No acoustic bias or fuzzy guesses."""
import re
import unicodedata

WORD = re.compile(r"[^\W_]+(?:['\u2019][^\W_]+)*", re.UNICODE)


def words(text):
    return [unicodedata.normalize('NFKC', m.group()).casefold().replace('\u2019', "'") for m in WORD.finditer(text)]


def apply_rules(text, rules, app=''):
    compiled = []
    for index, rule in enumerate(rules[:500]):
        heard, replacement = rule.get('heard', '').strip(), rule.get('replacement', '').strip()
        scope = rule.get('app', '').strip().casefold()
        if not rule.get('enabled', True) or not heard or not replacement or (scope and scope != app.casefold()):
            continue
        if len(heard) > 160 or len(replacement) > 160:
            continue
        pattern = r"(?<![\w'\u2019])" + r'\s+'.join(re.escape(p) for p in heard.split()) + r"(?![\w'\u2019])"
        compiled.append((re.compile(pattern, re.IGNORECASE), replacement, bool(scope), index))
    candidates = []
    for pattern, replacement, scoped, index in compiled:
        for match in pattern.finditer(text):
            candidates.append((match.start(), -(match.end() - match.start()), -int(scoped), index, match.end(), replacement))
    out, cursor, applied, protected = [], 0, [], []
    for start, _, _, index, end, replacement in sorted(candidates):
        if start < cursor:
            continue
        out.extend((text[cursor:start], replacement))
        cursor = end
        applied.append(index)
        protected.append(replacement)
    out.append(text[cursor:])
    return ''.join(out), applied, protected


def finish_text(raw, settings, punctuator=None, app=''):
    corrected, applied, protected = apply_rules(raw, settings.get('corrections', []), app)
    text, warning = corrected, None
    if settings.get('punctuation', True) and punctuator and text:
        try:
            text, details = punctuator.restore(corrected)
            warning = details.get('warning')
        except Exception:
            warning = 'Punctuation unavailable; original words kept.'
    if words(text) != words(corrected):
        text, warning = corrected, 'Punctuation changed words; original words kept.'
    # Replacement spelling wins over vocabulary spelling, including overlapping phrases.
    spellings = protected + settings.get('vocabulary', [])[:500]
    text, _, _ = apply_rules(text, [{'heard': s, 'replacement': s} for s in spellings if isinstance(s, str) and len(s) <= 160])
    return text, applied, warning
