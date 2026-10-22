/// AdSense platform view for the web feed ad pages. On IO platforms this
/// is a stub (mobile uses AdMob); on web it exports the real view.
export 'adsense_view_stub.dart'
    if (dart.library.js_interop) 'adsense_view_web.dart';
