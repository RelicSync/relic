import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../app_globals.dart';
import '../data/repo.dart';
import '../models/relic.dart';
import '../util/blob_open.dart';

/// Makes a result row an OS drag source (desktop): text rows drag as plain
/// text, photos as a named image file plus PNG bytes (Explorer takes the
/// file, Word/Paint take the bitmap), file rows as the real file with its
/// original name. Windows-native feel: whole-row mouse drag — mice don't
/// drag-scroll Flutter lists, and taps/double-taps/modifier-clicks all
/// resolve on tap-up, so the existing gestures keep working untouched.
///
/// All representations are LAZY so drag-start is instant; blob
/// materialization is kicked off eagerly in the provider and the lazy
/// callbacks await the shared future (worst case the DROP waits, never the
/// UI). Temp files land in the relic_view cache and are pruned by age —
/// never deleted on drop, because targets may read after the drag returns.
class RelicDragSource extends StatelessWidget {
  final Relic relic;
  final RelicRepo repo;
  final bool enabled;
  final Widget child;
  const RelicDragSource({
    super.key,
    required this.relic,
    required this.repo,
    required this.enabled,
    required this.child,
  });

  Future<DragItem?> _provideItem(DragItemRequest request) async {
    final r = relic;
    // Keep the popup alive while the OS drag runs: blur-to-hide would kill
    // the drag source mid-flight. Cleared on completion (drop OR cancel) +
    // a watchdog so a wedged session can't permanently defeat click-away.
    gDragOutActive = true;
    void end() {
      gDragOutActive = false;
      gDragOutEndedAt = DateTime.now();
    }

    late final VoidCallback onDone;
    onDone = () {
      if (request.session.dragCompleted.value != null) {
        request.session.dragCompleted.removeListener(onDone);
        end();
      }
    };
    request.session.dragCompleted.addListener(onDone);
    Timer(const Duration(seconds: 60), () {
      if (gDragOutActive) end(); // watchdog: session never completed
    });

    final (base, ext) = relicNameAndExt(r);
    final item = DragItem(
      localData: r.uid,
      suggestedName: r.blobKey != null ? '$base.$ext' : null,
    );
    switch (r.kind) {
      case Kind.string:
        item.add(Formats.plainText.lazy(() async {
          final t = await repo.textOf(r);
          return t ?? '';
        }));
      case Kind.photo:
        // Kick materialization now (async) so the lazy callbacks — which run
        // when the drop target actually requests the format — usually find
        // the file ready.
        final fileF = materializeRelicFile(repo, r);
        item.add(Formats.fileUri.lazy(() async {
          final path = await fileF;
          if (path == null) throw StateError('blob unavailable');
          return Uri.file(path);
        }));
        item.add(Formats.png.lazy(() async {
          final bytes = await repo.blobBytes(r);
          if (bytes == null) throw StateError('blob unavailable');
          return bytes;
        }));
      case Kind.file:
        final fileF = materializeRelicFile(repo, r);
        item.add(Formats.fileUri.lazy(() async {
          final path = await fileF;
          if (path == null) throw StateError('blob unavailable');
          return Uri.file(path);
        }));
      case Kind.other:
        item.add(Formats.plainText.lazy(() async {
          final t = await repo.textOf(r);
          return t ?? '';
        }));
    }
    return item;
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux) ||
        // No native drag plugin under flutter_test: DragItemWidget's engine
        // handshake throws an async MissingPluginException that fails tests.
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return child;
    }
    return DragItemWidget(
      allowedOperations: () => const [DropOperation.copy],
      canAddItemToExistingSession: false,
      dragItemProvider: _provideItem,
      child: DraggableWidget(child: child),
    );
  }
}
