/// Shared screen chrome that `danaview_editor` (Projects screen, settings rows) reuses so it looks
/// like the rest of the library screens. Entry point: `package:danaview_features/chrome.dart`.
///
/// `danaview_features` never imports editor packages; this file only re-exports widgets that
/// already live here.
library danaview_features_chrome;

export 'src/library/library_widgets.dart'
    show
        DanaviewInlineEmpty,
        DanaviewLibraryFrame,
        DanaviewLibraryGroup,
        DanaviewLibrarySectionHeader,
        DanaviewLibraryTopBar,
        DanaviewRefreshOnReturn,
        danaviewLibraryInsets;
