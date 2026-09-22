# Relic Voice third-party components

The app downloads pinned model files from Relic's R2 mirror when Voice is enabled.
Audio is processed locally. The model files are not executable updates.

| Component | License | Source |
|---|---|---|
| IBM Granite Speech 5.0 470M Turbo CTC | Apache-2.0 | https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc |
| Granite Q8 GGUF conversion | Apache-2.0 | https://huggingface.co/handy-computer/granite-speech-5.0-470m-turboctc-GGUF |
| English punctuation and capitalization | Apache-2.0 | https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_english |
| transcribe.cpp and ggml | MIT | https://github.com/handy-computer/transcribe.cpp |
| ONNX Runtime | MIT | https://github.com/microsoft/onnxruntime |
| SentencePiece | Apache-2.0 | https://github.com/google/sentencepiece |
| Python | PSF | https://www.python.org/psf/license/ |
| NumPy | BSD-3-Clause | https://numpy.org/ |
| python-sounddevice, PortAudio | MIT | https://python-sounddevice.readthedocs.io/ |
| PyInstaller bootloader | GPL-2.0 with distribution exception | https://pyinstaller.org/en/stable/license.html |

Runtime revision: ed3468f3881abb9e7b6c7d404f75049aecccb04f.
Windows x64 builds target AVX2, FMA and F16C. AVX-512 and machine-native tuning are disabled.
macOS builds are arm64 (Apple Silicon), CPU only, with machine-native tuning disabled.
The macOS bundle also carries certifi (MPL-2.0, https://github.com/certifi/python-certifi) for the model download's root store.
The bundled worker includes its Python runtime; end users do not install Python or packages.
