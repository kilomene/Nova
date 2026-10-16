// App-wide configuration. Edit apiBaseUrl after deploying the backend
// (see docs/SETUP.md). Empty = demo mode: everything runs locally with
// seeded data and clear "demo" labeling in Settings.

class AppConfig {
  static const String apiBaseUrl = '';

  static bool get demoMode => apiBaseUrl.isEmpty;

  // v1 scope notes (honest labels, also in README):
  // - Duet/Stitch: not built in v1.
  // - LIVE: realtime room (chat/gifts/viewers) is built; RTMP/WebRTC video
  //   ingest is phase 2.

  // Money movement policy: testnet default. Mainnet sends are compiled
  // behind this flag AND a per-transaction confirmation screen.
  static const bool mainnetEnabled = false;

  static const String appName = 'Nova';
  static const String packageName = 'com.nova.app';

  // Seeded demo feed (public Google sample videos; original Nova captions).
  static const List<Map<String, String>> seedVideos = [
    {
      'id': 'seed-1',
      'handle': 'nova_studios',
      'displayName': 'Nova Studios',
      'caption': 'POV: your money moves as fast as your For You feed',
      'hashtags': 'nova,fintech,africa',
      'sound': 'original sound - nova_studios',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
    },
    {
      'id': 'seed-2',
      'handle': 'afrobeats_daily',
      'displayName': 'Afrobeats Daily',
      'caption': 'New drop friday. Who is outside?',
      'hashtags': 'afrobeats,music,lagos',
      'sound': 'original sound - afrobeats_daily',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
    },
    {
      'id': 'seed-3',
      'handle': 'houston_hustle',
      'displayName': 'Houston Hustle',
      'caption': 'Day 1 of building in public. No budget, all heart.',
      'hashtags': 'buildinpublic,startup',
      'sound': 'original sound - houston_hustle',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
    },
    {
      'id': 'seed-4',
      'handle': 'satoshi_szn',
      'displayName': 'Satoshi Szn',
      'caption': 'Stablecoins explained in 30 seconds. Save this.',
      'hashtags': 'crypto,usdc,learn',
      'sound': 'original sound - satoshi_szn',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
    },
    {
      'id': 'seed-5',
      'handle': 'market_mama',
      'displayName': 'Market Mama',
      'caption': 'Fresh ankara prints just landed in my store. Link in profile.',
      'hashtags': 'marketplace,fashion,ankara',
      'sound': 'original sound - market_mama',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
    },
    {
      'id': 'seed-6',
      'handle': 'dev_diaries',
      'displayName': 'Dev Diaries',
      'caption': 'x402 lets APIs charge per request. The future is programmable money.',
      'hashtags': 'x402,ai,builders',
      'sound': 'original sound - dev_diaries',
      'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    },
  ];

  static const List<String> supportedAssets = ['BTC', 'ETH', 'USDT', 'USDC'];
  static const List<String> fiatCurrencies = ['USD', 'NGN', 'GHS', 'KES', 'EUR', 'GBP'];
}
