import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/coin_service.dart';
import '../services/kyc_service.dart';
import '../services/push_service.dart';
import '../services/sync_service.dart';
import '../services/wallet_service.dart';

/// Central app state. Talks to the Workers API when configured, otherwise
/// runs a labeled local demo store (seeded feed, local ledger).
class AppState extends ChangeNotifier {
  final AuthService auth;
  final ApiClient api;
  final KycService kyc;
  final WalletService wallet;
  final CoinService coins;
  final SyncService sync;
  final PushService push;

  AppState({
    required this.auth,
    required this.api,
    required this.kyc,
    required this.wallet,
    required this.coins,
    required this.sync,
    required this.push,
  });

  NovaUser? me;
  bool followersLoaded = false;
  int myFollowerCount = 0;
  final Set<String> followingUids = {};

  List<NovaVideo> feed = [];
  bool feedLoading = false;

  List<P2POffer> offers = [];
  List<Listing> listings = [];
  List<ChatThread> threads = [];
  List<LiveSession> liveSessions = [];

  bool verificationActive = false;
  String verificationExpiry = '';

  // Device identity (repeat-offender tracking) + VPN detection.
  String deviceId = '';
  bool vpnDetected = false;
  bool networkBlocked = false;

  // Moderation state for the current user.
  List<StrikeRecord> strikes = [];
  String accountStatus = 'active';

  // Creator earnings wallet (separate from the Nova Coin purchase wallet).
  int earningsBalance = 0;
  double earningsUsd = 0;
  int earningsLifetime = 0;

  // Seller onboarding state.
  SellerProfile sellerProfile = SellerProfile(status: 'none');

  bool get isDemo => api.isDemo;

  /// Persistent app-instance ID (v1; a hardware device ID needs
  /// device_info_plus — documented in SETUP.md).
  Future<String> _ensureDeviceId() async {
    if (deviceId.isNotEmpty) return deviceId;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('nova_device_id');
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('nova_device_id', id);
    }
    deviceId = id;
    return id;
  }

  /// Client-side VPN/proxy interface check (Android layer of the anti-VPN wall).
  /// Looks for tunnel interfaces (tun0, ppp0, ...). Server-side egress-IP
  /// blacklist + IP reputation are enforced by the backend.
  Future<void> checkVpnInterface() async {
    try {
      final ifs = await NetworkInterface.list();
      vpnDetected = ifs.any((i) {
        final n = i.name.toLowerCase();
        return n.contains('tun') || n.contains('ppp') || n.contains('pptp') || n.contains('ipsec') || n.contains('tap');
      });
    } catch (_) {
      vpnDetected = false;
    }
    notifyListeners();
  }

  /// Phase 1 boot: Firebase + device id + client VPN check. Makes NO
  /// authenticated API calls, so it is safe to run with no signed-in user
  /// (the auth gate runs right after this).
  Future<void> boot() async {
    await auth.init();
    await _ensureDeviceId();
    await checkVpnInterface();
  }

  Future<void> init() async {
    await boot();
    if (isDemo) {
      me = NovaUser(uid: auth.uid, handle: 'you', displayName: 'You');
      _seedDemo();
    } else {
      try {
        final r = await api.post('/api/users/sync', {
          'handle': 'user_${auth.uid.substring(0, 8)}',
          'displayName': auth.email ?? '',
          'email': auth.email ?? '',
          'deviceId': deviceId,
        });
        me = NovaUser.fromJson((r['user'] as Map).cast<String, dynamic>());
        accountStatus = me?.status ?? 'active';
      } catch (_) {
        me = NovaUser(uid: auth.uid, handle: 'you', displayName: 'You');
      }
      // Server-side egress check (VPN/proxy/Tor blacklist).
      try {
        await api.get('/api/security/network-check');
        networkBlocked = false;
      } on ApiException catch (e) {
        if (e.status == 403) networkBlocked = true;
      } catch (_) {}
      await _refreshVerification();
      try {
        final u = await api.get('/api/users/${auth.uid}');
        myFollowerCount = (((u['counts'] as Map?)?['followers'] ?? 0) as int);
      } catch (_) {}
      await refreshEarnings();
      await refreshSeller();
    }
    await wallet.load(api);
    await kyc.refresh(api);
    await coins.refresh(api);
    await loadFeed();
    if (!isDemo) {
      final wsBase = AppConfig.apiBaseUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
      await sync.connect(wsBase: wsBase, tokenProvider: () => auth.idToken());
      sync.events.listen(_onSyncEvent);
      await push.init(api);
    }
    notifyListeners();
  }

  void _onSyncEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'message':
        loadThreads();
        break;
      case 'coins':
        coins.refresh(api);
        break;
      case 'kyc':
        kyc.refresh(api);
        break;
      case 'escrow':
      case 'order':
        break;
    }
  }

  // ---------------- feed ----------------

  Future<void> loadFeed({bool following = false}) async {
    feedLoading = true;
    notifyListeners();
    try {
      if (isDemo) {
        final seeds = AppConfig.seedVideos.map((s) {
          final tags = '${s['hashtags']}'.split(',').where((t) => t.isNotEmpty).toList();
          return NovaVideo(
            id: s['id']!,
            uid: 'seed_${s['handle']}',
            handle: s['handle']!,
            displayName: s['displayName']!,
            caption: s['caption']!,
            hashtags: tags,
            mediaUrl: s['url']!,
            soundLabel: s['sound']!,
            likeCount: 1000 + s['id']!.hashCode.abs() % 50000,
            commentCount: 50 + s['id']!.hashCode.abs() % 2000,
            shareCount: 20 + s['id']!.hashCode.abs() % 800,
            createdAt: DateTime.now().millisecondsSinceEpoch - (s['id']!.hashCode.abs() % 72) * 3600000,
          );
        }).toList();
        feed = following ? seeds.where((v) => followingUids.contains(v.uid)).toList() : seeds;
      } else {
        Map<String, String>? q;
        if (!following) {
          final boost = await _tagAffinity();
          if (boost.isNotEmpty) q = {'boost': boost};
        }
        final r = await api.get(following ? '/api/feed/following' : '/api/feed', q);
        feed = ((r['videos'] as List?) ?? [])
            .map((e) => NovaVideo.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      if (feed.isEmpty && isDemo) _seedDemo();
    }
    feedLoading = false;
    notifyListeners();
  }

  void _seedDemo() {
    // Demo-mode conveniences (clearly labeled in Settings):
    // a lively-looking account so every flow is tappable.
    myFollowerCount = 1250;
    // feed is built in loadFeed; offers/listings get demo rows here.
    offers = [
      P2POffer(
        id: 'demo-offer-1', uid: 'seed_trader_ada', handle: 'trader_ada',
        traderScore: 48, tradesCompleted: 52,
        side: 'sell', asset: 'USDT', fiatCurrency: 'NGN',
        price: 1520, minAmount: 10, maxAmount: 500,
        paymentMethods: ['Bank transfer', 'OPay'], terms: 'Release after bank alert confirmed.',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      P2POffer(
        id: 'demo-offer-2', uid: 'seed_sats_musa', handle: 'sats_musa',
        traderScore: 31, tradesCompleted: 35,
        side: 'buy', asset: 'BTC', fiatCurrency: 'USD',
        price: 97400, minAmount: 0.001, maxAmount: 0.05,
        paymentMethods: ['Zelle', 'Cash App'], terms: 'Fast release, no third party.',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    listings = [
      Listing(
        id: 'demo-listing-1', uid: 'seed_market_mama', handle: 'market_mama',
        displayName: 'Market Mama', traderScore: 27,
        title: 'Hand-dyed ankara fabric (6 yards)',
        description: 'Premium cotton ankara, vibrant prints. Ships worldwide from Lagos.',
        priceUsd: 45, asset: 'USDC', category: 'fashion',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      Listing(
        id: 'demo-listing-2', uid: 'seed_dev_diaries', handle: 'dev_diaries',
        displayName: 'Dev Diaries', traderScore: 12,
        title: 'Nova growth playbook (PDF)',
        description: 'The exact launch checklist I used to grow to 100k. Digital download.',
        priceUsd: 19, asset: 'USDC', category: 'digital',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  Future<void> toggleLike(NovaVideo v) async {
    final was = v.likedByMe;
    v.likedByMe = !was;
    v.likeCount += was ? -1 : 1;
    notifyListeners();
    if (isDemo) return;
    try {
      final r = was ? await api.delete('/api/videos/${v.id}/like') : await api.post('/api/videos/${v.id}/like');
      v.likeCount = (r['likeCount'] ?? v.likeCount) as int;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> recordView(NovaVideo v) async {
    if (isDemo) return;
    try {
      await api.post('/api/videos/${v.id}/view');
    } catch (_) {}
  }

  /// Repost a video to the user's followers. Server endpoint may not exist
  /// yet — fall back to a local share-count bump so the UI still responds.
  Future<void> repostVideo(NovaVideo v) async {
    v.shareCount++;
    notifyListeners();
    if (isDemo) return;
    try {
      await api.post('/api/videos/${v.id}/repost');
    } catch (_) {
      // No server endpoint yet; the local bump stands.
    }
  }

  /// Remove a video from the local feed (not-interested signal).
  void markNotInterested(NovaVideo v) {
    feed.removeWhere((e) => e.id == v.id);
    notifyListeners();
    if (isDemo) return;
    try {
      api.post('/api/videos/${v.id}/not-interested');
    } catch (_) {}
  }

  /// Download a video's media file to the device's temp dir.
  Future<void> downloadVideo(NovaVideo v) async {
    final url = v.mediaUrl;
    if (url.isEmpty) throw Exception('No media URL');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final dir = Directory.systemTemp;
      final ext = url.contains('.mp4') ? 'mp4' : 'bin';
      final file = File('${dir.path}/nova_${v.id}.$ext');
      final sink = file.openWrite();
      await resp.pipe(sink);
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<List<VideoComment>> fetchComments(String videoId) async {
    if (isDemo) {
      return [
        VideoComment(id: 'c1', uid: 'seed_nova_studios', handle: 'nova_studios', text: 'This is the future. 🔥', createdAt: DateTime.now().millisecondsSinceEpoch),
        VideoComment(id: 'c2', uid: 'seed_afrobeats_daily', handle: 'afrobeats_daily', text: 'First!', createdAt: DateTime.now().millisecondsSinceEpoch),
      ];
    }
    final r = await api.get('/api/videos/$videoId/comments');
    return ((r['comments'] as List?) ?? []).map((e) => VideoComment.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<void> addComment(NovaVideo v, String text) async {
    if (isDemo) {
      v.commentCount++;
      notifyListeners();
      return;
    }
    await api.post('/api/videos/${v.id}/comments', {'text': text});
    v.commentCount++;
    notifyListeners();
  }

  Future<void> toggleFollow(String targetUid) async {
    final was = followingUids.contains(targetUid);
    if (was) {
      followingUids.remove(targetUid);
    } else {
      followingUids.add(targetUid);
    }
    notifyListeners();
    if (isDemo) return;
    try {
      if (was) {
        await api.delete('/api/users/$targetUid/follow');
      } else {
        await api.post('/api/users/$targetUid/follow');
      }
    } catch (_) {}
  }

  Future<NovaUser?> fetchUser(String uidOrHandle) async {
    if (isDemo) {
      if (me != null && (uidOrHandle == me!.uid || uidOrHandle == me!.handle)) return me;
      return NovaUser(uid: 'seed_$uidOrHandle', handle: uidOrHandle, displayName: uidOrHandle, bio: 'Nova creator', traderScore: 12, tradesCompleted: 15);
    }
    final r = await api.get('/api/users/$uidOrHandle');
    return NovaUser.fromJson((r['user'] as Map).cast<String, dynamic>());
  }

  Future<String> uploadVideo({
    required String filePath,
    required String caption,
    required List<String> hashtags,
    String soundLabel = '',
    String audioKey = '',
    bool rightsAffirmed = false,
    String scanVerdict = '', // '' | 'borderline' — from the on-device nudity scan
    bool isAiGenerated = false,
  }) async {
    if (isDemo) {
      final v = NovaVideo(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        uid: me?.uid ?? 'you',
        handle: me?.handle ?? 'you',
        displayName: me?.displayName ?? 'You',
        caption: caption,
        hashtags: hashtags,
        mediaUrl: filePath, // local file path; video_player can play files
        soundLabel: soundLabel,
        audioKey: audioKey,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isAiGenerated: isAiGenerated,
      );
      feed.insert(0, v);
      notifyListeners();
      return v.id;
    }
    String? uploadedAudioKey;
    if (audioKey.isNotEmpty) {
      final au = await api.upload('/api/uploads', audioKey);
      uploadedAudioKey = '${au['key']}';
    }
    final up = await api.upload('/api/uploads', filePath);
    final r = await api.post('/api/videos', {
      'caption': caption,
      'hashtags': hashtags,
      'mediaKey': up['key'],
      'soundLabel': soundLabel,
      'audioKey': uploadedAudioKey ?? '',
      'rightsAffirmed': rightsAffirmed,
      'scanVerdict': scanVerdict,
      'is_ai_generated': isAiGenerated,
    });
    await loadFeed();
    return '${r['id']}';
  }

  // ---------------- creator earnings wallet ----------------

  Future<void> refreshEarnings() async {
    if (isDemo) return;
    try {
      final r = await api.get('/api/earnings/balance');
      earningsBalance = (r['balance'] ?? 0) as int;
      earningsUsd = (r['usdValue'] ?? 0).toDouble();
      earningsLifetime = (r['lifetimeEarned'] ?? 0) as int;
      notifyListeners();
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> earningsLedger() async {
    if (isDemo) return [];
    final r = await api.get('/api/earnings/ledger');
    return (r['entries'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// Request a USD payout of creator earnings. v1: recorded for manual
  /// processing (actual Flutterwave transfer = phase 2).
  Future<Map<String, dynamic>> requestPayout({required int amountCoins, required String destination}) async {
    if (isDemo) throw ApiException(400, 'demo_mode');
    final r = await api.post('/api/earnings/payout', {'amountCoins': amountCoins, 'destination': destination});
    await refreshEarnings();
    return r;
  }

  // ---------------- moderation ----------------

  Future<void> submitReport({required String targetType, required String targetId, required String reason}) async {
    if (isDemo) return; // demo: reports are local-only; nothing to review
    await api.post('/api/reports', {'targetType': targetType, 'targetId': targetId, 'reason': reason});
  }

  Future<void> reportLive({required String sessionId, required String reason}) async {
    if (isDemo) return;
    await api.post('/api/live/$sessionId/report', {'reason': reason});
  }

  Future<void> loadStrikes() async {
    if (isDemo) return;
    try {
      final r = await api.get('/api/strikes/me');
      strikes = (r['strikes'] as List? ?? []).map((e) => StrikeRecord.fromJson((e as Map).cast<String, dynamic>())).toList();
      accountStatus = '${r['status'] ?? accountStatus}';
      notifyListeners();
    } catch (_) {}
  }

  // ---------------- sellers ----------------

  Future<void> refreshSeller() async {
    if (isDemo) return;
    try {
      final r = await api.get('/api/sellers/me');
      sellerProfile = SellerProfile.fromJson((r['seller'] as Map?)?.cast<String, dynamic>());
      notifyListeners();
    } catch (_) {}
  }

  Future<void> applySeller(Map<String, String> fields) async {
    if (isDemo) throw ApiException(400, 'demo_mode');
    // Upload the ID scan first via the returned key convention.
    await api.post('/api/sellers/apply', fields);
    await refreshSeller();
  }

  Future<String> uploadIdDocument(String filePath) async {
    if (isDemo) return 'demo_id_key';
    final up = await api.upload('/api/uploads', filePath);
    return '${up['key']}';
  }

  // ---------------- orders (receipts + tracking) ----------------

  /// paymentMethod: 'flutterwave' (fiat) or 'crypto' (wallet).
  Future<Map<String, dynamic>> createOrder({required String listingId, String paymentMethod = 'flutterwave'}) async {
    if (isDemo) throw ApiException(400, 'demo_mode');
    return api.post('/api/orders', {'listingId': listingId, 'paymentMethod': paymentMethod});
  }

  Future<OrderDetail> orderDetail(String orderId) async {
    final r = await api.get('/api/orders/$orderId');
    return OrderDetail.fromJson(r);
  }

  Future<void> trackOrder({required String orderId, required String status, String note = '', String trackingNumber = '', String carrier = ''}) async {
    await api.post('/api/orders/$orderId/track', {
      'status': status, 'note': note, 'trackingNumber': trackingNumber, 'carrier': carrier,
    });
  }

  // ---------------- support desk ----------------

  Future<List<SupportTicket>> supportTickets() async {
    if (isDemo) return [];
    final r = await api.get('/api/support/tickets');
    return (r['tickets'] as List? ?? []).map((e) => SupportTicket.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<String> createSupportTicket({required String subject, required String message}) async {
    if (isDemo) throw ApiException(400, 'demo_mode');
    final r = await api.post('/api/support/tickets', {'subject': subject, 'message': message});
    return '${r['id']}';
  }

  Future<Map<String, dynamic>> supportTicketDetail(String ticketId) async {
    final r = await api.get('/api/support/tickets/$ticketId');
    return r;
  }

  Future<void> replySupportTicket({required String ticketId, required String message}) async {
    await api.post('/api/support/tickets/$ticketId/reply', {'message': message});
  }

  // ---------------- hashtags ----------------

  Future<List<Map<String, dynamic>>> trendingHashtags() async {
    if (isDemo) {
      // Demo: derive from the seeded feed.
      final counts = <String, int>{};
      for (final v in feed) {
        for (final h in v.hashtags) {
          counts[h] = (counts[h] ?? 0) + 1;
        }
      }
      final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return sorted.map((e) => {'tag': e.key, 'uses': e.value}).toList();
    }
    try {
      final r = await api.get('/api/hashtags/trending');
      return (r['hashtags'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<NovaVideo>> hashtagVideos(String tag) async {
    final t = tag.toLowerCase();
    if (isDemo) {
      return feed.where((v) => v.hashtags.map((h) => h.toLowerCase()).contains(t)).toList();
    }
    try {
      final r = await api.get('/api/hashtags/${Uri.encodeComponent(t)}');
      return ((r['videos'] as List?) ?? []).map((e) => NovaVideo.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  /// Tags the user engages with → sent as ?boost= to /api/feed (FYP signals).
  Future<String> _tagAffinity() async {
    if (isDemo) return '';
    try {
      final r = await api.get('/api/me/tag-affinity');
      return ((r['tags'] as List?) ?? []).join(',');
    } catch (_) {
      return '';
    }
  }

  // ---------------- P2P ----------------

  Future<void> loadOffers({String? asset, String? fiat}) async {
    if (isDemo) {
      notifyListeners();
      return;
    }
    final q = <String, String>{};
    if (asset != null) q['asset'] = asset;
    if (fiat != null) q['fiat'] = fiat;
    final r = await api.get('/api/p2p/offers', q);
    offers = ((r['offers'] as List?) ?? []).map((e) => P2POffer.fromJson((e as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  Future<String> createOffer(Map<String, dynamic> fields) async {
    if (isDemo) {
      final o = P2POffer(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        uid: me?.uid ?? 'you',
        handle: me?.handle ?? 'you',
        side: '${fields['side']}',
        asset: '${fields['asset']}',
        fiatCurrency: '${fields['fiatCurrency']}',
        price: (fields['price'] as num).toDouble(),
        minAmount: (fields['minAmount'] as num).toDouble(),
        maxAmount: (fields['maxAmount'] as num).toDouble(),
        paymentMethods: List<String>.from(fields['paymentMethods'] ?? []),
        terms: '${fields['terms'] ?? ''}',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      offers.insert(0, o);
      notifyListeners();
      return o.id;
    }
    final r = await api.post('/api/p2p/offers', fields);
    await loadOffers();
    return '${r['id']}';
  }

  Future<Escrow> openEscrow(String offerId, double cryptoAmount) async {
    if (isDemo) {
      final o = offers.firstWhere((e) => e.id == offerId);
      return Escrow(
        id: 'demo_escrow_${DateTime.now().millisecondsSinceEpoch}',
        offerId: offerId,
        buyerUid: o.side == 'sell' ? (me?.uid ?? 'you') : o.uid,
        sellerUid: o.side == 'sell' ? o.uid : (me?.uid ?? 'you'),
        asset: o.asset,
        cryptoAmount: cryptoAmount,
        fiatAmount: cryptoAmount * o.price,
        fiatCurrency: o.fiatCurrency,
        status: 'awaiting_payment',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final r = await api.post('/api/escrows', {'offerId': offerId, 'cryptoAmount': cryptoAmount});
    final e = await api.get('/api/escrows/${r['id']}');
    return Escrow.fromJson((e['escrow'] as Map).cast<String, dynamic>());
  }

  Future<String> escrowAction(String escrowId, String action) async {
    if (isDemo) return action == 'mark-paid' ? 'paid' : action == 'release' ? 'released' : action;
    final r = await api.post('/api/escrows/$escrowId/$action');
    return '${r['status']}';
  }

  // ---------------- marketplace ----------------

  Future<void> loadListings({String? query}) async {
    if (isDemo) {
      notifyListeners();
      return;
    }
    final r = await api.get('/api/listings', query == null ? null : {'q': query});
    listings = ((r['listings'] as List?) ?? []).map((e) => Listing.fromJson((e as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  Future<String> createListing(Map<String, dynamic> fields) async {
    if (isDemo) {
      final l = Listing(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        uid: me?.uid ?? 'you',
        handle: me?.handle ?? 'you',
        displayName: me?.displayName ?? 'You',
        title: '${fields['title']}',
        description: '${fields['description'] ?? ''}',
        priceUsd: (fields['priceUsd'] as num).toDouble(),
        asset: '${fields['asset'] ?? 'USDC'}',
        category: '${fields['category'] ?? 'general'}',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      listings.insert(0, l);
      notifyListeners();
      return l.id;
    }
    final r = await api.post('/api/listings', fields);
    await loadListings();
    return '${r['id']}';
  }

  // ---------------- messaging ----------------

  Future<void> loadThreads() async {
    if (isDemo) {
      notifyListeners();
      return;
    }
    try {
      final r = await api.get('/api/inbox');
      threads = ((r['threads'] as List?) ?? [])
          .map((e) => ChatThread.fromJson((e as Map).cast<String, dynamic>(), auth.uid))
          .toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<List<ChatMessage>> loadMessages(String peerUid) async {
    if (isDemo) return [];
    final r = await api.get('/api/threads/$peerUid/messages');
    return ((r['messages'] as List?) ?? []).map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<void> sendMessage(String peerUid, String text) async {
    if (isDemo) return;
    await api.post('/api/threads/$peerUid/messages', {'text': text});
  }

  // ---------------- blocking ----------------

  /// Blocked users cannot see your content at all (feed, profile, comments,
  /// messages) until unblocked. Blocking also severs follows both ways.
  Future<void> blockUser(String uidOrHandle) async {
    if (isDemo) return;
    await api.post('/api/blocks/$uidOrHandle');
  }

  Future<void> unblockUser(String uidOrHandle) async {
    if (isDemo) return;
    await api.delete('/api/blocks/$uidOrHandle');
  }

  Future<List<NovaUser>> blockedUsers() async {
    if (isDemo) return [];
    final r = await api.get('/api/blocks');
    return (r['blocked'] as List? ?? []).map((e) => NovaUser.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  // ---------------- LIVE ----------------

  Future<void> loadLiveSessions() async {
    if (isDemo) {
      liveSessions = [];
      notifyListeners();
      return;
    }
    try {
      final r = await api.get('/api/live');
      liveSessions = ((r['sessions'] as List?) ?? []).map((e) => LiveSession.fromJson((e as Map).cast<String, dynamic>())).toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<String> startLive(String title) async {
    if (isDemo) {
      // @nova official account is EXEMPT from the 1000-follower gate.
      if (!(me?.isOfficial ?? false) && myFollowerCount < 1000) {
        throw ApiException(403, 'live_requires_1000_followers');
      }
      return 'demo_live_${DateTime.now().millisecondsSinceEpoch}';
    }
    final r = await api.post('/api/live/start', {'title': title});
    await loadLiveSessions();
    return '${r['id']}';
  }

  Future<void> endLive(String id) async {
    if (isDemo) return;
    await api.post('/api/live/$id/end');
    await loadLiveSessions();
  }

  Future<void> joinLive(String id) async {
    if (isDemo) return;
    try {
      await api.post('/api/live/$id/join');
    } catch (_) {}
  }

  Future<void> leaveLive(String id) async {
    if (isDemo) return;
    try {
      await api.post('/api/live/$id/leave');
    } catch (_) {}
  }

  // ---------------- verification ($25/mo) ----------------

  Future<void> _refreshVerification() async {
    try {
      final r = await api.get('/api/verification/status');
      verificationActive = (r['verified'] ?? false) == true;
      final sub = r['subscription'] as Map?;
      verificationExpiry = sub == null ? '' : '${sub['expires_at'] ?? ''}';
    } catch (_) {}
  }

  Future<bool> subscribeVerification(String email) async {
    if (isDemo) {
      verificationActive = true;
      notifyListeners();
      return true;
    }
    final r = await api.post('/api/verification/subscribe', {'email': email});
    final link = ((r['flutterwave'] as Map?)?['data'] as Map?)?['link'] as String?;
    if (link == null) throw ApiException(502, 'checkout_unavailable');
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    throw ApiException(502, 'checkout_unavailable');
  }
}
