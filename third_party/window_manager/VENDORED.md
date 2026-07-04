# Vendored: window_manager (Linux plugin disabled)

`window_manager` is pulled in *transitively* (yaru → yaru_window →
yaru_window_manager → window_manager) but Clickscope never uses it. Its native
Linux plugin, however, auto-registers and hooks the GTK toplevel; on window
close after the surface has idled, its window-state handler calls
`gtk_widget_get_toplevel` / `gdk_window_get_state` on the already-freed FlView
and **segfaults**.

This is an unmodified copy of window_manager 0.4.3 (MIT) with **one change**:
the `linux:` entry removed from `flutter: plugin: platforms:` in pubspec.yaml,
so Flutter does not register its Linux plugin. The Dart API is untouched, so
yaru_window_manager still compiles (it is never exercised on Linux — yaru_window
uses the native yaru_window_linux there). Wired via `dependency_overrides`.
