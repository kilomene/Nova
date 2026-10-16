# TikTok Product Research — Clean-Room Reference for Nova

> Reverse-engineered from observable product behavior and public documentation only.
> No TikTok code was decompiled, no assets copied, no brand elements reused.
> Nova reimplements these *behaviors* with 100% original code and assets.

Research date: 2026-10-16. Sources: TikTok newsroom/help-center disclosures,
creator guides, and current feature reporting (see parent brief for citations).

## 1. Core loop: the For You feed

- TikTok's primary surface is a full-screen vertical swipe feed ("For You Page").
- It runs on an **interest graph**, not a social graph: content is matched to
  predicted taste, not to who you follow. Follower count is not a direct
  ranking factor; each video is judged on its own performance.
- New uploads go through moderation, then batch testing: shown to a small
  audience, scaled up if engagement is strong (the "snowball").
- Heaviest ranking signals: **watch time / completion rate / rewatches**,
  then likes, comments, shares, follows. Finishing a long video outweighs a
  weak signal like same-country-as-viewer.
- Content signals: captions, on-screen text, hashtags, sounds, effects.
  Device/account signals (language, region, device type) are lightly weighted.
- Feed hygiene rules: avoids two videos in a row from the same creator or
  with the same sound; mixes in regional diversity; "not interested" /
  Restricted Mode / feed refresh controls exist for users.

## 2. Following feed

- Chronological-ish feed of accounts the user follows. Secondary tab, much
  smaller share of watch time than For You.

## 3. Camera / upload flow

- Entry: central "+" button. Options: record in-app (15s/60s/3m/10m lengths),
  upload from camera roll, templates, "Create with AI" effects.
- During capture/edit: sounds (trending audio library), effects/filters
  (incl. AI transitions), text overlays, stickers, voiceover, captions,
  adjust clips / trim.
- Post screen: caption, hashtags (#fyp-style tags are NOT a ranking factor —
  relevant tags are), cover frame picker ("Cover titles" AI feature),
  privacy (public/friends/private), allow duet / stitch / comments toggles,
  location tag, branded-content disclosure toggle.
- Photo mode: carousel posts exist alongside video.

## 4. Engagement on a video

- Right rail: profile avatar (+follow), like (heart), comment (opens
  bottom-sheet thread), save/bookmark, share (repost, DM, copy link,
  share-to-other-apps).
- Bottom: sound disc (tap → sound page with all videos using it), caption,
  hashtags.
- Long-press: not interested, save video, duet/stitch shortcuts, report.
- Comments: threaded replies, like comments, reply-with-video, comment
  filters incl. "with media".

## 5. Duet / Stitch (collaboration primitives)

- **Duet**: split-screen — original plays beside your new recording; used for
  reactions, harmonies, side-by-sides. Respects creator's allow-duet setting.
- **Stitch**: clip up to ~5 seconds of someone else's video, then append your
  own recorded response; used for commentary, continuations, tutorials.
  Must be recorded in-app (no camera-roll stitch). Respects allow-stitch.
- Sound reuse: any video's audio can be reused via the sound page ("Use this
  sound").

## 6. Profiles

- Avatar, handle, display name, bio, link, follower/following/like counts,
  tabs: videos grid, liked (private), reposts; creator tools (analytics,
  Creator Center); business accounts get storefront-ish product showcases.
- Follow/unfollow, message button, share profile.

## 7. Discovery

- Search: keyword search across videos, users, sounds, hashtags, LIVE;
  "Creator Search Insights" surfaces trending queries with low video supply.
- Hashtag pages + challenges (branded and organic).
- Trending sounds page; STEM-style topic feeds in some regions.

## 8. Direct messaging

- 1:1 and group chats, text/photo/video/voice notes, in-app games in DMs
  (testing), message requests for non-mutuals, block/report, disappearing
  options. Encrypted-message passcode exists on some accounts.

## 9. LIVE

- 18+ only; safety training required before first go-live (2026 rules).
- Gifts: viewers buy coins → send animated gifts → creator receives
  "diamonds" convertible to cash (platform keeps ~50%).
- Paid subscriptions for exclusive LIVE perks; sponsored segments must be
  labeled. LIVE Shopping: product pinning during streams.

## 10. Notifications

- Likes, comments, new followers, mentions, replies, LIVE alerts from
  followed creators, system/monetization updates. Granular per-type toggles.

## 11. Creator tools & monetization

- Creator Rewards Program: pays per 1,000 qualified views on original
  1-minute+ videos (~$0.40–$1.00 RPM); 10K followers + 100K views/30d + 18+.
- TikTok Shop: in-feed product cards, affiliate commissions (5–20%), seller
  storefronts, LIVE shopping.
- Series: paywalled video collections. Subscriptions + tips.
- Creator Marketplace: brand-deal matchmaking (flat-fee sponsored posts).
- Analytics: traffic sources, follower activity windows, search insights.

## 12. What Nova takes from this (mapping)

| TikTok behavior            | Nova v1 equivalent                          |
|----------------------------|---------------------------------------------|
| For You vertical feed      | Home feed, heuristic ranking (no ML in v1)  |
| Following feed             | Following tab                               |
| Camera + upload + post     | Upload flow: pick video, caption, hashtags  |
| Like/comment/share/save    | Right-rail actions + comment sheet          |
| Duet/Stitch                | Labeled STUB in v1 (API fields reserved)    |
| Profiles + tabs            | Profile with Videos + Store tabs            |
| Search/hashtags/sounds     | Search screen (videos/users/hashtags)       |
| DMs                        | Inbox + chat UI over Workers API + WS       |
| LIVE + gifts               | Labeled STUB in v1                          |
| Creator monetization       | Wallet tips in USDC + marketplace (Nova's edge: instant stablecoin payout, no 50% gift cut, x402 pay-per-view hooks) |

## 13. Deliberate Nova differences

- Wallet-first identity: every profile has a wallet; tipping/buying never
  leaves the app.
- Reputation from completed trades, not follower counts (P2P + marketplace).
- x402 hooks: paywalled content / API access payable in stablecoins.
- No TikTok brand, logo, sounds, or music — all Nova-original assets.
