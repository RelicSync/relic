# ONNX Runtime's native library looks up its Java classes by name over JNI
# (ai/onnxruntime/TensorInfo and friends). R8 cannot see those uses, so in
# release builds it removed TensorInfo and renamed others. The first search
# by meaning then aborted the app with "JNI DETECTED ERROR: java_class ==
# null" in convertToTensorInfo (Play vitals, 1.0.61+79, 2026-10-21).
# Keep the whole package exactly as shipped.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
