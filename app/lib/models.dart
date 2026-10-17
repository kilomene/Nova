// Data models shared across the app. fromJson mirrors the Workers API;
// toJson is used for the local demo store.
import 'dart:convert';

/// X-style company affiliation: the company (gold badge) this user is
/// affiliated with. Rendered as a small company-logo square next to the
/// user's verification badge.
class Affiliation {
  final String uid;
  final String handle;
  final String displayName;
  final String avatarUrl;

  const Affiliation({
    required this.uid,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
  });

  factory Affiliation.fromJson(Map<String, dynamic> j) => Affiliation(
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? ''}',
        displayName: '${j['display_name'] ?? j['displayName'] ?? ''}',
        avatarUrl: '${j['avatar_url'] ?? j['avatarUrl'] ?? ''}',
      );
}

/// Parses the `affiliated_with` payload attached to users/videos/comments.
Affiliation? parseAffiliation(dynamic v) {
  if (v is Map<String, dynamic> && '${v['uid'] ?? ''}'.isNotEmpty) {
    return Affiliation.fromJson(v);
  }
  return null;
}

class NovaUser {
  final String uid;
  final String handle;
  final String username;
  final String displayName;
  final String bio;
  final String avatarUrl;
  final String kycStatus;
  final String status; // active | suspended | banned
  final bool isBot;
  final bool isOfficial;
  final bool totpEnabled;
  final double traderScore;
  final int tradesCompleted;
  final bool isVerified;
  final String verificationType; // 'personal' | 'business' | ''
  final Affiliation? affiliatedWith;

  NovaUser({
    required this.uid,
    required this.handle,
    this.username = '',
    this.displayName = '',
    this.bio = '',
    this.avatarUrl = '',
    this.kycStatus = 'none',
    this.status = 'active',
    this.isBot = false,
    this.isOfficial = false,
    this.totpEnabled = false,
    this.traderScore = 0,
    this.tradesCompleted = 0,
    this.isVerified = false,
    this.verificationType = '',
    this.affiliatedWith,
  });

  factory NovaUser.fromJson(Map<String, dynamic> j) => NovaUser(
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? 'user'}',
        username: '${j['username'] ?? ''}',
        displayName: '${j['display_name'] ?? j['displayName'] ?? ''}',
        bio: '${j['bio'] ?? ''}',
        avatarUrl: '${j['avatar_url'] ?? j['avatarUrl'] ?? ''}',
        kycStatus: '${j['kyc_status'] ?? j['kycStatus'] ?? 'none'}',
        status: '${j['status'] ?? 'active'}',
        isBot: (j['is_bot'] ?? j['isBot'] ?? 0) == 1 || (j['is_bot'] ?? j['isBot']) == true,
        isOfficial: (j['is_official'] ?? j['isOfficial'] ?? 0) == 1 || (j['is_official'] ?? j['isOfficial']) == true,
        totpEnabled: (j['totp_enabled'] ?? j['totpEnabled'] ?? 0) == 1 || (j['totp_enabled'] ?? j['totpEnabled']) == true,
        traderScore: (j['trader_score'] ?? j['traderScore'] ?? 0).toDouble(),
        tradesCompleted: (j['trades_completed'] ?? j['tradesCompleted'] ?? 0) as int,
        isVerified: (j['is_verified'] ?? j['isVerified'] ?? false) == true,
        verificationType: '${j['verification_type'] ?? j['verificationType'] ?? ''}',
        affiliatedWith: parseAffiliation(j['affiliated_with'] ?? j['affiliatedWith']),
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'handle': handle,
        'display_name': displayName,
        'bio': bio,
        'avatar_url': avatarUrl,
        'kyc_status': kycStatus,
        'trader_score': traderScore,
        'trades_completed': tradesCompleted,
      };
}

class NovaVideo {
  final String id;
  final String uid;
  final String handle;
  final String displayName;
  final String avatarUrl;
  final String caption;
  final List<String> hashtags;
  final String mediaUrl;
  final String soundLabel;
  final String audioKey;
  int likeCount;
  int commentCount;
  int shareCount;
  int viewCount;
  final int createdAt;
  bool likedByMe;
  final bool isVerified;
  final String verificationType; // 'personal' | 'business' | ''
  final Affiliation? affiliatedWith;
  final bool promoted;
  final bool isAiGenerated;

  NovaVideo({
    required this.id,
    required this.uid,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
    this.caption = '',
    this.hashtags = const [],
    required this.mediaUrl,
    this.soundLabel = '',
    this.audioKey = '',
    this.likeCount = 0,
    this.commentCount = 0,
    this.shareCount = 0,
    this.viewCount = 0,
    required this.createdAt,
    this.likedByMe = false,
    this.isVerified = false,
    this.verificationType = '',
    this.affiliatedWith,
    this.promoted = false,
    this.isAiGenerated = false,
  });

  factory NovaVideo.fromJson(Map<String, dynamic> j) {
    final tags = j['hashtags'];
    List<String> hs = [];
    if (tags is String) {
      try {
        hs = (jsonDecode(tags) as List).map((e) => '$e').toList();
      } catch (_) {
        hs = tags.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    } else if (tags is List) {
      hs = tags.map((e) => '$e').toList();
    }
    return NovaVideo(
      id: '${j['id']}',
      uid: '${j['uid'] ?? ''}',
      handle: '${j['handle'] ?? 'user'}',
      displayName: '${j['display_name'] ?? ''}',
      avatarUrl: '${j['avatar_url'] ?? ''}',
      caption: '${j['caption'] ?? ''}',
      hashtags: hs,
      mediaUrl: '${j['media_url'] ?? j['mediaUrl'] ?? ''}',
      soundLabel: '${j['sound_label'] ?? j['soundLabel'] ?? ''}',
      audioKey: '${j['audio_key'] ?? j['audioKey'] ?? ''}',
      likeCount: (j['like_count'] ?? j['likeCount'] ?? 0) as int,
      commentCount: (j['comment_count'] ?? j['commentCount'] ?? 0) as int,
      shareCount: (j['share_count'] ?? j['shareCount'] ?? 0) as int,
      viewCount: (j['view_count'] ?? j['viewCount'] ?? 0) as int,
      createdAt: (j['created_at'] ?? j['createdAt'] ?? 0) as int,
      isVerified: (j['is_verified'] ?? j['isVerified'] ?? false) == true,
      verificationType: '${j['verification_type'] ?? j['verificationType'] ?? ''}',
      affiliatedWith: parseAffiliation(j['affiliated_with'] ?? j['affiliatedWith']),
      promoted: (j['promoted'] ?? false) == true,
      isAiGenerated: (j['is_ai_generated'] ?? j['isAiGenerated'] ?? false) == true,
    );
  }
}

class VideoComment {
  final String id;
  final String uid;
  final String handle;
  final String displayName;
  final String avatarUrl;
  final String text;
  final int createdAt;
  final bool isVerified;
  final String verificationType; // 'personal' | 'business' | ''
  final Affiliation? affiliatedWith;

  VideoComment({
    required this.id,
    required this.uid,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
    required this.text,
    required this.createdAt,
    this.isVerified = false,
    this.verificationType = '',
    this.affiliatedWith,
  });

  factory VideoComment.fromJson(Map<String, dynamic> j) => VideoComment(
        id: '${j['id']}',
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? 'user'}',
        displayName: '${j['display_name'] ?? ''}',
        avatarUrl: '${j['avatar_url'] ?? ''}',
        text: '${j['text'] ?? ''}',
        createdAt: (j['created_at'] ?? 0) as int,
        isVerified: (j['is_verified'] ?? false) == true,
        verificationType: '${j['verification_type'] ?? ''}',
        affiliatedWith: parseAffiliation(j['affiliated_with'] ?? j['affiliatedWith']),
      );
}

class P2POffer {
  final String id;
  final String uid;
  final String handle;
  final double traderScore;
  final int tradesCompleted;
  final String side; // buy | sell (maker side, in crypto)
  final String asset;
  final String fiatCurrency;
  final double price;
  final double minAmount;
  final double maxAmount;
  final List<String> paymentMethods;
  final String terms;
  final int createdAt;

  P2POffer({
    required this.id,
    required this.uid,
    required this.handle,
    this.traderScore = 0,
    this.tradesCompleted = 0,
    required this.side,
    required this.asset,
    required this.fiatCurrency,
    required this.price,
    required this.minAmount,
    required this.maxAmount,
    this.paymentMethods = const [],
    this.terms = '',
    required this.createdAt,
  });

  factory P2POffer.fromJson(Map<String, dynamic> j) => P2POffer(
        id: '${j['id']}',
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? 'user'}',
        traderScore: (j['trader_score'] ?? 0).toDouble(),
        tradesCompleted: (j['trades_completed'] ?? 0) as int,
        side: '${j['side']}',
        asset: '${j['asset']}',
        fiatCurrency: '${j['fiat_currency'] ?? j['fiatCurrency'] ?? ''}',
        price: (j['price'] ?? 0).toDouble(),
        minAmount: (j['min_amount'] ?? j['minAmount'] ?? 0).toDouble(),
        maxAmount: (j['max_amount'] ?? j['maxAmount'] ?? 0).toDouble(),
        paymentMethods: _strList(j['payment_methods'] ?? j['paymentMethods']),
        terms: '${j['terms'] ?? ''}',
        createdAt: (j['created_at'] ?? j['createdAt'] ?? 0) as int,
      );
}

List<String> _strList(dynamic v) {
  if (v is List) return v.map((e) => '$e').toList();
  if (v is String) {
    try {
      return (jsonDecode(v) as List).map((e) => '$e').toList();
    } catch (_) {
      return [];
    }
  }
  return [];
}

class Escrow {
  final String id;
  final String offerId;
  final String buyerUid;
  final String sellerUid;
  final String asset;
  final double cryptoAmount;
  final double fiatAmount;
  final String fiatCurrency;
  final String status;
  final int updatedAt;

  Escrow({
    required this.id,
    required this.offerId,
    required this.buyerUid,
    required this.sellerUid,
    required this.asset,
    required this.cryptoAmount,
    required this.fiatAmount,
    required this.fiatCurrency,
    required this.status,
    required this.updatedAt,
  });

  factory Escrow.fromJson(Map<String, dynamic> j) => Escrow(
        id: '${j['id']}',
        offerId: '${j['offer_id'] ?? j['offerId'] ?? ''}',
        buyerUid: '${j['buyer_uid'] ?? j['buyerUid'] ?? ''}',
        sellerUid: '${j['seller_uid'] ?? j['sellerUid'] ?? ''}',
        asset: '${j['asset'] ?? ''}',
        cryptoAmount: (j['crypto_amount'] ?? j['cryptoAmount'] ?? 0).toDouble(),
        fiatAmount: (j['fiat_amount'] ?? j['fiatAmount'] ?? 0).toDouble(),
        fiatCurrency: '${j['fiat_currency'] ?? j['fiatCurrency'] ?? ''}',
        status: '${j['status'] ?? ''}',
        updatedAt: (j['updated_at'] ?? j['updatedAt'] ?? 0) as int,
      );
}

class Listing {
  final String id;
  final String uid;
  final String handle;
  final String displayName;
  final double traderScore;
  final String title;
  final String description;
  final double priceUsd;
  final String asset;
  final List<String> mediaKeys;
  final String category;
  final int createdAt;

  Listing({
    required this.id,
    required this.uid,
    required this.handle,
    this.displayName = '',
    this.traderScore = 0,
    required this.title,
    this.description = '',
    required this.priceUsd,
    this.asset = 'USDC',
    this.mediaKeys = const [],
    this.category = 'general',
    required this.createdAt,
  });

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        id: '${j['id']}',
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? 'user'}',
        displayName: '${j['display_name'] ?? ''}',
        traderScore: (j['trader_score'] ?? 0).toDouble(),
        title: '${j['title'] ?? ''}',
        description: '${j['description'] ?? ''}',
        priceUsd: (j['price_usd'] ?? j['priceUsd'] ?? 0).toDouble(),
        asset: '${j['asset'] ?? 'USDC'}',
        mediaKeys: _strList(j['media_keys'] ?? j['mediaKeys']),
        category: '${j['category'] ?? 'general'}',
        createdAt: (j['created_at'] ?? j['createdAt'] ?? 0) as int,
      );
}

class ChatMessage {
  final String id;
  final String threadId;
  final String senderUid;
  final String text;
  final int createdAt;

  ChatMessage({
    required this.id,
    required this.threadId,
    required this.senderUid,
    required this.text,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: '${j['id'] ?? ''}',
        threadId: '${j['thread_id'] ?? j['threadId'] ?? ''}',
        senderUid: '${j['sender_uid'] ?? j['senderUid'] ?? ''}',
        text: '${j['text'] ?? ''}',
        createdAt: (j['created_at'] ?? j['createdAt'] ?? 0) as int,
      );
}

class ChatThread {
  final String id;
  final String peerUid;
  final String peerHandle;
  final String peerName;
  final String peerAvatar;
  final String lastMessage;
  final int updatedAt;
  final int unreadCount;

  ChatThread({
    required this.id,
    required this.peerUid,
    required this.peerHandle,
    this.peerName = '',
    this.peerAvatar = '',
    this.lastMessage = '',
    required this.updatedAt,
    this.unreadCount = 0,
  });

  factory ChatThread.fromJson(Map<String, dynamic> j, String selfUid) {
    // API returns peer_* fields; derive peerUid from thread id when missing.
    var peerUid = '${j['peer_uid'] ?? ''}';
    if (peerUid.isEmpty) {
      final parts = '${j['id']}'.split('__');
      peerUid = parts.firstWhere((p) => p != selfUid, orElse: () => '');
    }
    return ChatThread(
      id: '${j['id']}',
      peerUid: peerUid,
      peerHandle: '${j['peer_handle'] ?? 'user'}',
      peerName: '${j['peer_name'] ?? ''}',
      peerAvatar: '${j['peer_avatar'] ?? ''}',
      lastMessage: '${j['last_message'] ?? j['lastMessage'] ?? ''}',
      updatedAt: (j['updated_at'] ?? j['updatedAt'] ?? 0) as int,
      unreadCount: (j['unread_count'] ?? 0) as int,
    );
  }
}

class GiftItem {
  final String id;
  final String name;
  final int coinPrice;
  final int creatorShare;
  final String animation;

  GiftItem({
    required this.id,
    required this.name,
    required this.coinPrice,
    required this.creatorShare,
    required this.animation,
  });

  factory GiftItem.fromJson(Map<String, dynamic> j) => GiftItem(
        id: '${j['id']}',
        name: '${j['name']}',
        coinPrice: (j['coin_price'] ?? j['coinPrice'] ?? 0) as int,
        creatorShare: (j['creator_share'] ?? j['creatorShare'] ?? 0) as int,
        animation: '${j['animation'] ?? j['id']}',
      );

  // Demo catalog mirrors the backend seed (docs: backend/schema.sql).
  static List<GiftItem> demoCatalog() => [
        GiftItem(id: 'coin_burst', name: 'Coin Burst', coinPrice: 10, creatorShare: 5, animation: 'coin_burst'),
        GiftItem(id: 'nova_heart', name: 'Nova Heart', coinPrice: 50, creatorShare: 25, animation: 'nova_heart'),
        GiftItem(id: 'rocket', name: 'Rocket', coinPrice: 100, creatorShare: 50, animation: 'rocket'),
        GiftItem(id: 'crown', name: 'Golden Crown', coinPrice: 500, creatorShare: 250, animation: 'crown'),
      ];
}

class CoinPackage {
  final String id;
  final int usd;
  final int coins;

  CoinPackage({required this.id, required this.usd, required this.coins});

  factory CoinPackage.fromJson(Map<String, dynamic> j) => CoinPackage(
        id: '${j['id']}',
        usd: (j['usd'] ?? 0) as int,
        coins: (j['coins'] ?? 0) as int,
      );

  static List<CoinPackage> demoPackages() => [
        CoinPackage(id: 'coins_500', usd: 5, coins: 500),
        CoinPackage(id: 'coins_1100', usd: 10, coins: 1100),
        CoinPackage(id: 'coins_3000', usd: 25, coins: 3000),
      ];
}

class LiveSession {
  final String id;
  final String uid;
  final String handle;
  final String displayName;
  final String avatarUrl;
  final String title;
  final int viewerCount;
  final int startedAt;
  final bool isVerified;
  final String verificationType; // 'personal' | 'business' | ''
  final Affiliation? affiliatedWith;

  LiveSession({
    required this.id,
    required this.uid,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
    this.title = '',
    this.viewerCount = 0,
    required this.startedAt,
    this.isVerified = false,
    this.verificationType = '',
    this.affiliatedWith,
  });

  factory LiveSession.fromJson(Map<String, dynamic> j) => LiveSession(
        id: '${j['id']}',
        uid: '${j['uid'] ?? ''}',
        handle: '${j['handle'] ?? 'user'}',
        displayName: '${j['display_name'] ?? ''}',
        avatarUrl: '${j['avatar_url'] ?? ''}',
        title: '${j['title'] ?? ''}',
        viewerCount: (j['viewer_count'] ?? 0) as int,
        startedAt: (j['started_at'] ?? 0) as int,
        isVerified: (j['is_verified'] ?? false) == true,
        verificationType: '${j['verification_type'] ?? ''}',
        affiliatedWith: parseAffiliation(j['affiliated_with'] ?? j['affiliatedWith']),
      );
}

/// Moderation strike (3 = suspended).
class StrikeRecord {
  final String id;
  final String reason;
  final String details;
  final int createdAt;
  StrikeRecord({required this.id, required this.reason, this.details = '', required this.createdAt});
  factory StrikeRecord.fromJson(Map<String, dynamic> j) => StrikeRecord(
        id: '${j['id']}',
        reason: '${j['reason'] ?? ''}',
        details: '${j['details'] ?? ''}',
        createdAt: (j['created_at'] ?? 0) as int,
      );
}

/// Strict seller onboarding profile (TikTok-Shop-style).
class SellerProfile {
  final String status; // none | pending | verified | rejected
  final String reviewerNote;
  SellerProfile({required this.status, this.reviewerNote = ''});
  factory SellerProfile.fromJson(Map<String, dynamic>? j) => SellerProfile(
        status: '${j?['status'] ?? 'none'}',
        reviewerNote: '${j?['reviewer_note'] ?? ''}',
      );
}

/// Itemized order receipt (TikTok Shop-grade).
class OrderReceipt {
  final String orderId;
  final List<Map<String, dynamic>> items;
  final double shippingUsd;
  final double taxUsd;
  final double totalUsd;
  final String paymentMethod;
  final String trackingNumber;
  final String carrier;
  OrderReceipt({
    required this.orderId,
    required this.items,
    required this.shippingUsd,
    required this.taxUsd,
    required this.totalUsd,
    required this.paymentMethod,
    required this.trackingNumber,
    required this.carrier,
  });
  factory OrderReceipt.fromJson(Map<String, dynamic> j) => OrderReceipt(
        orderId: '${j['orderId'] ?? ''}',
        items: (j['items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        shippingUsd: (j['shippingUsd'] ?? 0).toDouble(),
        taxUsd: (j['taxUsd'] ?? 0).toDouble(),
        totalUsd: (j['totalUsd'] ?? 0).toDouble(),
        paymentMethod: '${j['paymentMethod'] ?? ''}',
        trackingNumber: '${j['trackingNumber'] ?? ''}',
        carrier: '${j['carrier'] ?? ''}',
      );
}

class OrderEvent {
  final String status;
  final String note;
  final int createdAt;
  OrderEvent({required this.status, this.note = '', required this.createdAt});
  factory OrderEvent.fromJson(Map<String, dynamic> j) => OrderEvent(
        status: '${j['status'] ?? ''}',
        note: '${j['note'] ?? ''}',
        createdAt: (j['created_at'] ?? 0) as int,
      );
}

class OrderDetail {
  final Map<String, dynamic> order;
  final OrderReceipt receipt;
  final List<OrderEvent> timeline;
  OrderDetail({required this.order, required this.receipt, required this.timeline});
  factory OrderDetail.fromJson(Map<String, dynamic> j) => OrderDetail(
        order: Map<String, dynamic>.from(j['order'] as Map),
        receipt: OrderReceipt.fromJson(Map<String, dynamic>.from(j['receipt'] as Map)),
        timeline: (j['timeline'] as List? ?? []).map((e) => OrderEvent.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
      );
}

/// Support desk ticket + replies.
class SupportTicket {
  final String id;
  final String subject;
  final String status;
  final int updatedAt;
  SupportTicket({required this.id, required this.subject, required this.status, required this.updatedAt});
  factory SupportTicket.fromJson(Map<String, dynamic> j) => SupportTicket(
        id: '${j['id']}',
        subject: '${j['subject'] ?? ''}',
        status: '${j['status'] ?? 'open'}',
        updatedAt: (j['updated_at'] ?? 0) as int,
      );
}

class SupportReply {
  final String author; // user | agent
  final String message;
  final int createdAt;
  SupportReply({required this.author, required this.message, required this.createdAt});
  factory SupportReply.fromJson(Map<String, dynamic> j) => SupportReply(
        author: '${j['author'] ?? ''}',
        message: '${j['message'] ?? ''}',
        createdAt: (j['created_at'] ?? 0) as int,
      );
}

/// Report reasons (rights-holder takedowns use 'copyright').
class ReportReasons {
  static const List<String> all = ['nudity', 'spam', 'harassment', 'fraud', 'impersonation', 'copyright', 'other'];
  static const Map<String, String> labels = {
    'nudity': 'Nudity / sexual content',
    'spam': 'Spam',
    'harassment': 'Harassment / hate',
    'fraud': 'Fraud / scam (evidence captured for law-enforcement pipeline)',
    'impersonation': 'Impersonation / fake account',
    'copyright': 'Copyright (rights-holder takedown)',
    'other': 'Other',
  };
}
