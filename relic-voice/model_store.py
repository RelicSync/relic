"""Pinned R2 assets. Partial files never become loadable models."""
import hashlib
import json
import os
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent
MANIFEST = json.loads((ROOT / 'models.json').read_text(encoding='utf-8'))


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
        with urllib.request.urlopen(request, timeout=45) as response:
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
