"""Pinned R2 assets. Partial files never become loadable models."""
import hashlib
import json
import os
from pathlib import Path
import ssl
import urllib.request

ROOT = Path(__file__).resolve().parent
MANIFEST = json.loads((ROOT / 'models.json').read_text(encoding='utf-8'))


def tls_context():
    """Verified TLS wherever the frozen worker runs. Windows Python reads the
    system store; the python.org build on macOS ships no roots at all, so an
    empty default store falls back to certifi, then the OS bundle."""
    context = ssl.create_default_context()
    if context.cert_store_stats().get('x509', 0):
        return context
    candidates = []
    try:
        import certifi
        candidates.append(certifi.where())
    except Exception:
        pass
    candidates += ['/etc/ssl/cert.pem', '/etc/ssl/certs/ca-certificates.crt']
    for bundle in candidates:
        try:
            if os.path.isfile(bundle):
                context.load_verify_locations(bundle)
                return context
        except Exception:
            continue
    return context


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def ensure_models(folder, progress=lambda **kw: None, canceled=lambda: False):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    total = sum(f['bytes'] for f in MANIFEST['files'])
    complete = 0
    for spec in MANIFEST['files']:
        if canceled():
            raise InterruptedError('Download canceled')
        final = folder / spec['name']
        if final.exists() and final.stat().st_size == spec['bytes'] and digest(final) == spec['sha256']:
            complete += spec['bytes']
            progress(received=complete, total=total)
            continue
        partial = final.with_name(final.name + '.partial')
        offset = partial.stat().st_size if partial.exists() else 0
        if offset >= spec['bytes']:
            partial.unlink()
            offset = 0
        headers = {'User-Agent': 'RelicVoice/1'}
        if offset:
            headers['Range'] = f'bytes={offset}-'
        request = urllib.request.Request(MANIFEST['base_url'] + '/' + spec['name'], headers=headers)
        with urllib.request.urlopen(request, timeout=45, context=tls_context()) as response:
            if response.status != 206:
                offset = 0
            elif not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                raise ValueError('Invalid model download range')
            with partial.open('ab' if offset else 'wb') as stream:
                received = offset
                while block := response.read(1024 * 1024):
                    if canceled():
                        raise InterruptedError('Download canceled')
                    received += len(block)
                    if received > spec['bytes']:
                        raise ValueError('Model download exceeds expected size')
                    stream.write(block)
                    progress(received=complete + received, total=total)
                stream.flush()
                os.fsync(stream.fileno())
        if partial.stat().st_size != spec['bytes'] or digest(partial) != spec['sha256']:
            partial.unlink(missing_ok=True)
            raise ValueError('Model checksum failed. Retry the download.')
        partial.replace(final)
        complete += spec['bytes']
    return folder
