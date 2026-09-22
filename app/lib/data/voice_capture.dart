import '../models/relic.dart';

class VoiceCaptureResult {
  final Relic relic;
  final bool created;
  final bool promotionRefused;
  const VoiceCaptureResult(
    this.relic, {
    required this.created,
    required this.promotionRefused,
  });
}
