/// Process-wide transient flags shared across the widget tree without threading
/// callbacks through every layer.
library;

/// True while a native OS modal (the file picker) is open. The frameless popup's
/// click-away-to-close (`onWindowBlur` → hide) checks this so opening a file
/// dialog doesn't dismiss the window underneath it.
bool gNativeModalOpen = false;

/// True while an OS drag-out session started from a result row is live.
/// desktop.dart's onWindowBlur checks this so dragging content out of the
/// frameless popup doesn't hide the window mid-drag.
bool gDragOutActive = false;

/// When the last drag-out ended. onWindowBlur swallows the blur that the drop
/// target's activation fires immediately after the drop (mirrors the summon
/// grace window).
DateTime? gDragOutEndedAt;
