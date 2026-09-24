"""Bounded NDJSON on inherited pipes. No listener, transcript logs or audio files."""
import argparse
import json
import queue
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from engine import Engine
from model_store import ensure_models
from recorder import MAX_SECONDS, Recorder, input_devices
from live_decode import LiveDecode

MAX_LINE = 256 * 1024
output_lock = threading.Lock()


def emit(event, **fields):
    with output_lock:
        print(json.dumps({'event': event, **fields}, ensure_ascii=True), flush=True)


def serve(folder):
    commands = queue.Queue(maxsize=64)
    quit_event = threading.Event()

    def read():
        try:
            while line := sys.stdin.buffer.readline(MAX_LINE + 1):
                if len(line) > MAX_LINE:
                    break
                commands.put(json.loads(line), timeout=2)
        except Exception:
            pass
        finally:
            quit_event.set()

    threading.Thread(target=read, daemon=True).start()
    emit('hello', protocol=1, recognition_bias=False, backend='cpu')
    engine, recorder, active, future, live = None, Recorder(), None, None, None
    pool = ThreadPoolExecutor(max_workers=1)
    try:
        folder = ensure_models(folder, lambda **p: emit('download', **p), quit_event.is_set)
        if quit_event.is_set():
            return
        emit('loading')
        engine = Engine(folder)
        emit('ready', devices=[{'id': i, 'name': name} for i, name in input_devices()], max_seconds=MAX_SECONDS)
        last_level = 0.0
        while not quit_event.is_set():
            try:
                command = commands.get(timeout=0.04)
            except queue.Empty:
                command = None
            if command:
                op, sid = command.get('op'), command.get('id')
                if op == 'shutdown':
                    break
                if op == 'start' and active is None and future is None:
                    if not isinstance(sid, str) or len(sid) > 80:
                        continue
                    active = command
                    try:
                        recorder.start(command.get('device'))
                        live = LiveDecode(engine, pool, recorder.rate, command.get('settings'), command.get('app', ''))
                    except Exception:
                        emit('error', id=sid, message='Could not open microphone. Check Voice settings and microphone access.')
                        active = None
                elif op == 'cancel' and active and active['id'] == sid:
                    recorder.stop()
                    recorder.blocks.clear()
                    if live:
                        live.cancel()
                    future, live, active = None, None, None
                    emit('canceled', id=sid)
                    emit('idle')
                elif op == 'stop' and active and active['id'] == sid and future is None:
                    active['stop'] = True
            if active and future is None:
                sid = active['id']
                live.observe(recorder.blocks)
                # Drop the blocks the decoder has taken, so a long note keeps
                # about one phrase of audio in memory. Blocks the microphone
                # adds meanwhile land after the cut and stay unseen.
                del recorder.blocks[:live.seen_blocks]
                live.seen_blocks = 0
                if recorder.frames and not active.get('started'):
                    active['started'] = True
                    emit('audio_started', id=sid)
                if active.get('stop') or recorder.limit_reached:
                    stopping = time.perf_counter()
                    _, _, warnings = recorder.stop()
                    live.observe(recorder.blocks)
                    recorder.blocks.clear()
                    stop_ms = round((time.perf_counter() - stopping) * 1000)
                    if warnings:
                        emit('error', id=sid, message='Microphone audio was interrupted. Please try again.')
                        live.cancel()
                        future, live, active = None, None, None
                        continue
                    active['stop_ms'] = stop_ms
                    emit('processing', id=sid)
                    future = (sid, live.finish())
                elif time.monotonic() - last_level > 0.12:
                    last_level = time.monotonic()
                    emit('level', id=sid, level=recorder.level, seconds=recorder.frames / recorder.rate)
                    if recorder.stream and not recorder.stream.active and not recorder.limit_reached:
                        recorder.stop()
                        recorder.blocks.clear()
                        emit('error', id=sid, message='Microphone disconnected. Please try again.')
                        live.cancel()
                        future, live, active = None, None, None
            if future and future[1].done():
                sid, job = future
                if active and active['id'] == sid:
                    try:
                        emit('result', id=sid, stop_ms=active.get('stop_ms', 0), **job.result())
                    except Exception:
                        emit('error', id=sid, message='Transcription failed. Please try again.')
                future, active, live = None, None, None
                emit('idle')
    except InterruptedError:
        pass
    except Exception as exc:
        # Never print arbitrary native exception text or a transcript.
        emit('error', message='Voice setup failed. Retry in Voice settings.', category=type(exc).__name__)
    finally:
        quit_event.set()
        recorder.stop()
        pool.shutdown(wait=True, cancel_futures=True)
        if engine:
            engine.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--models', required=True, type=Path)
    parser.add_argument('--transcribe-file', type=Path, nargs='+', help='Explicit local audio evaluation; emits JSON results and exits')
    args = parser.parse_args()
    if args.transcribe_file:
        import soundfile as sf
        folder = ensure_models(args.models, lambda **p: emit('download', **p))
        engine = Engine(folder)
        try:
            for path in args.transcribe_file:
                audio, rate = sf.read(path, dtype='float32')
                emit('result', file=path.name, **engine.transcribe(audio, rate))
        finally:
            engine.close()
    else:
        serve(args.models)
