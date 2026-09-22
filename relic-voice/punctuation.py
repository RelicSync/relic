"""Local punctuation/case restoration with word-preservation checks.

Uses the published PCS English ONNX tensor contract. Inference is CPU-only;
only original tokenizer surfaces are emitted, never generated replacement words.
Model card: https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_english
"""
import time
import numpy as np
import onnxruntime as ort
from sentencepiece import SentencePieceProcessor
from corrections import words
from model_store import MANIFEST
PUNCTUATION_REVISION = "b26fd1c40e88678859048898218ea4edcc24c84a"
PUNCTUATION_FILES = {f["name"]: f["sha256"] for f in MANIFEST["files"]}

class Punctuator:
    def __init__(self, folder, threads=4):
        started = time.perf_counter()
        model = folder / "punct_cap_seg_en.onnx"
        tokenizer = folder / "spe_32k_lc_en.model"
        if not model.is_file() or not tokenizer.is_file():
            raise FileNotFoundError("Punctuation model missing. Run setup.ps1 first.")
        options = ort.SessionOptions()
        options.intra_op_num_threads = min(4, max(1, threads))
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        options.add_session_config_entry("session.inter_op.allow_spinning", "0")
        self.session = ort.InferenceSession(str(model), sess_options=options,
                                           providers=["CPUExecutionProvider"])
        if self.session.get_providers() != ["CPUExecutionProvider"]:
            raise RuntimeError("Punctuation model must use CPU only.")
        self.tokenizer = SentencePieceProcessor(model_file=str(tokenizer))
        self.load_seconds = time.perf_counter() - started

    def restore(self, text):
        started = time.perf_counter()
        metadata = {"model": "punctuation_fullstop_truecase_english",
                    "revision": PUNCTUATION_REVISION,
                    "model_sha256": PUNCTUATION_FILES["punct_cap_seg_en.onnx"],
                    "provider": "CPUExecutionProvider", "load_seconds": self.load_seconds,
                    "word_preservation_passed": True, "warning": None}
        if not text.strip():
            return "", {**metadata, "seconds": 0.0}
        # Preserve original surfaces, including unknown names and numbers.
        proto = self.tokenizer.encode(text.lower(), out_type="immutable_proto")
        pieces = list(proto.pieces)
        predictions = [None] * len(pieces)
        scores = [-1] * len(pieces)
        # 254 content tokens + BOS/EOS; 32-token overlap gives both sides context.
        for start in range(0, len(pieces), 222):
            stop = min(start + 254, len(pieces))
            chunk = pieces[start:stop]
            ids = [self.tokenizer.bos_id()] + [p.id for p in chunk] + [self.tokenizer.eos_id()]
            _, post, caps, boundaries = self.session.run(
                None, {"input_ids": np.asarray([ids], dtype=np.int64)})
            for local in range(len(chunk)):
                # Prefer the window where the token is farther from a seam.
                quality = min(local + 1 if start else 254,
                              len(chunk) - local if stop < len(pieces) else 254)
                absolute = start + local
                if quality > scores[absolute]:
                    predictions[absolute] = (int(post[0, local+1]), caps[0, local+1], int(boundaries[0, local+1]))
                    scores[absolute] = quality
            if stop == len(pieces):
                break
        output = []
        for index, piece in enumerate(pieces):
            label, capitalization, boundary = predictions[index]
            encoded = piece.piece
            surface = piece.surface
            leading_space = encoded.startswith("\u2581")
            # The leading SentencePiece whitespace marker has its own case index.
            offset = 1 if leading_space else 0
            content = surface.lstrip() if leading_space else surface
            if leading_space and output and not output[-1].endswith(" "):
                output.append(" ")
            letters = []
            for char_index, char in enumerate(content):
                cap_index = char_index + offset
                letters.append(char.upper() if cap_index < len(capitalization) and capitalization[cap_index] else char)
            output.append("".join(letters))
            word_end = index + 1 == len(pieces) or pieces[index+1].piece.startswith("\u2581")
            # Keep acronyms as one word instead of splitting "us" into "U.S.".
            mark = {2: ".", 3: ",", 4: "?"}.get(label)
            if word_end and mark and content and content[-1] not in ".,?!":
                output.append(mark)
        formatted = "".join(output).strip()
        if formatted:
            formatted = formatted[0].upper() + formatted[1:]
            if formatted.endswith(","):
                formatted = formatted[:-1] + "."
            elif formatted[-1] not in ".?!":
                formatted += "."
        if words(formatted) != words(text):
            metadata["word_preservation_passed"] = False
            metadata["warning"] = "Punctuation changed word boundaries; raw text retained."
            formatted = text
        metadata["seconds"] = time.perf_counter() - started
        return formatted, metadata
