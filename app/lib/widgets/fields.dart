import 'package:flutter/material.dart'
    show EdgeInsets, InputBorder, InputDecoration;

/// The decoration for a [TextField] that sits inside a container which already
/// draws its own ground, hairline and radius — the app's normal field shape.
///
/// `border: InputBorder.none` on its own is not enough. Material merges an
/// [InputDecoration] with the ambient `inputDecorationTheme`, and in each
/// state the theme's `enabledBorder` / `focusedBorder` win over `border`. Left
/// unset they paint a *second* outline (and a second fill) inside the wrapper:
/// a stray pill hairline floating in the middle of the field, and a gold ring
/// on focus. Every state has to be silenced explicitly, which is what this is.
const InputDecoration kBareField = InputDecoration(
  isCollapsed: true,
  filled: false,
  contentPadding: EdgeInsets.zero,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
);
