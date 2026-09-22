"""Real human audio through the frozen shipping worker, with aggregate results."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import time


def words(text):
    return re.findall(r"[\w]+(?:'[\w]+)*", text.casefold())


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        row = [i]
        for j, hyp in enumerate(hypothesis, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j-1] + (ref != hyp)))
        previous = row
    return previous[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.fixtures / 'manifest.json').read_text(encoding='utf-8'))
    entries = manifest.get('clips', manifest.get('entries', []))
    if not entries:
        raise ValueError('No human audio fixtures')
    started = time.perf_counter()
    process = subprocess.run([str(args.worker.resolve()), '--models', str(args.models.resolve()),
        '--transcribe-file', *[str((args.fixtures / e['audio']).resolve()) for e in entries]],
        capture_output=True, text=True, encoding='utf-8', timeout=300,
        creationflags=subprocess.CREATE_NO_WINDOW)
    if process.returncode:
        raise RuntimeError('Packaged worker failed: ' + process.stderr[-2000:])
    results = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
    results = {r['file']: r for r in results if r.get('event') == 'result'}
    assert len(results) == len(entries)
    errors, count, mutation, times, duration = 0, 0, 0, [], 0
    for entry in entries:
        result = results[entry['audio']]
        ref, hyp = words(entry['reference']), words(result['text'])
        errors += distance(ref, hyp)
        count += len(ref)
        mutation += words(result['raw']) != hyp
        times.append(result['processing_ms'])
        duration += result['duration_ms']
    report = {'worker': 'packaged Windows AVX2 CPU', 'model_source': 'Relic R2, SHA-256 verified',
        'clips': len(entries), 'reference_words': count, 'word_errors': errors, 'wer': errors/count,
        'audio_seconds': duration/1000, 'median_processing_ms': statistics.median(times),
        'p95_processing_ms': sorted(times)[int(len(times)*.95)], 'punctuation_word_mutations': mutation,
        'total_wall_seconds': time.perf_counter()-started}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    assert errors/count < .15 and mutation == 0


if __name__ == '__main__': main()
