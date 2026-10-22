import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Full-screen AdMob native ad page inside the For You feed.
///
/// Shows a real native ad when Google fills one. Until the account/app
/// finish Google's verification (or whenever an ad fails to load), it
/// renders a Nova house card instead — the feed never shows a blank page.
class FeedAdPage extends StatefulWidget {
  const FeedAdPage({super.key});

  @override
  State<FeedAdPage> createState() => _FeedAdPageState();
}

class _FeedAdPageState extends State<FeedAdPage> {
  static const _unitId = 'ca-app-pub-2431202994591245/7805240268';

  NativeAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return; // web is covered by AdSense; slots aren't inserted there
    _ad = NativeAd(
      adUnitId: _unitId,
      request: const AdRequest(),
      nativeTemplateStyle: NativeTemplateStyle(
        templateType: TemplateType.medium,
        mainBackgroundColor: const Color(0xFF0A0A0A),
        callToActionTextStyle: NativeTemplateTextStyle(
          textColor: Colors.black,
          backgroundColor: const Color(0xFFD4AF37),
          style: NativeTemplateFontStyle.bold,
          size: 16,
        ),
        primaryTextStyle: NativeTemplateTextStyle(
          textColor: Colors.white,
          style: NativeTemplateFontStyle.bold,
          size: 18,
        ),
        secondaryTextStyle: NativeTemplateTextStyle(
          textColor: const Color(0xFFCCCCCC),
          size: 14,
        ),
        tertiaryTextStyle: NativeTemplateTextStyle(
          textColor: const Color(0xFF999999),
          size: 12,
        ),
      ),
      listener: NativeAdListener(
        onAdLoaded: (ad) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (mounted) setState(() => _ad = null);
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _ad != null) {
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: AdWidget(ad: _ad!)),
            Positioned(
              left: 12,
              bottom: 96,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFD4AF37), width: 0.7),
                ),
                child: const Text('Ad',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      );
    }
    // House card fallback: shown while loading, on no-fill, and until
    // Google finishes verifying the account/app.
    return ColoredBox(
      color: const Color(0xFF0A0A0A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('ℕ',
                  style: TextStyle(color: Color(0xFFD4AF37), fontSize: 84, fontWeight: FontWeight.w700)),
              const SizedBox(height: 18),
              const Text('Your video belongs here',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              const Text(
                'Promote a video from your profile and it appears in the For You feed for everyone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFD4AF37), width: 0.7),
                ),
                child: const Text('Ad',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
