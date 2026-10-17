import 'package:flutter/material.dart';

/// In-app legal pages (v1 summaries) behind the auth screen's
/// "Terms of Service" / "Privacy Policy" links. Full hosted legal docs
/// ship with the Nova website; these summaries state the v1 rules honestly.
class LegalScreen extends StatelessWidget {
  final int initialTab; // 0 = Terms, 1 = Privacy
  const LegalScreen({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Legal'),
          bottom: const TabBar(
            indicatorColor: Color(0xFFFFC107),
            labelColor: Color(0xFFFFC107),
            unselectedLabelColor: Colors.white54,
            tabs: [Tab(text: 'Terms of Service'), Tab(text: 'Privacy Policy')],
          ),
        ),
        body: const TabBarView(
          children: [
            _LegalBody(title: 'Terms of Service', sections: _terms),
            _LegalBody(title: 'Privacy Policy', sections: _privacy),
          ],
        ),
      ),
    );
  }
}

class _LegalBody extends StatelessWidget {
  final String title;
  final List<Map<String, String>> sections;
  const _LegalBody({required this.title, required this.sections});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 6),
        const Text('Nova v1 summary. Last updated October 2026.',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 20),
        for (final s in sections) ...[
          Text(s['h']!,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFFFC107))),
          const SizedBox(height: 6),
          Text(s['b']!, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

const List<Map<String, String>> _terms = [
  {
    'h': 'Your account',
    'b': 'One account per email address. You are responsible for keeping your '
        'password and wallet PIN secret. Nova staff will never ask for them. '
        'The official @nova account is operated by Nova itself.'
  },
  {
    'h': 'Content rules',
    'b': 'Nudity is zero-tolerance: confirmed nudity earns a strike and the '
        'content is removed. Three strikes lead to suspension; livestream '
        'nudity leads to an instant ban. Spam, scams, and fraud lead to '
        'restriction or law-enforcement referral. You must own (or have '
        'rights to) everything you upload, and you accept takedowns for violations.'
  },
  {
    'h': 'Marketplace & P2P',
    'b': 'Marketplace purchases are escrowed until delivery is confirmed. '
        'Only buyers with a completed order may review a product. Sellers '
        'must complete identity verification before listing. Crypto '
        'transfers are irreversible — always confirm the address and amount.'
  },
  {
    'h': 'Wallet & PIN',
    'b': 'Your wallet PIN encrypts your keys on your device. Nova servers '
        'store only the encrypted backup — never your PIN or keys. If you '
        'forget your PIN, the wallet cannot be recovered by Nova.'
  },
  {
    'h': 'Calls & voice notes',
    'b': 'Voice calls and voice notes may be recorded and retained for '
        'safety, fraud-prevention, and support review (voice notes: 24 hours '
        'on Nova servers, 30 days archived). By using calls and voice notes '
        'you consent to this recording.'
  },
  {
    'h': 'Termination',
    'b': 'Nova may suspend or ban accounts that breach these terms, with '
        'strikes and review queues as described in the Community Guidelines. '
        'You may delete your account at any time from Settings.'
  },
];

const List<Map<String, String>> _privacy = [
  {
    'h': 'What we collect',
    'b': 'Account data (username, email, profile), content you upload, '
        'device identifiers used for repeat-offender tracking, KYC documents '
        'for sellers (stored encrypted), and call/voice-note recordings as '
        'described in the Terms.'
  },
  {
    'h': 'How we use it',
    'b': 'To operate Nova (feed, messaging, wallet, marketplace), to keep '
        'the platform safe (moderation, anti-fraud, anti-VPN enforcement), '
        'and to provide support.'
  },
  {
    'h': 'Sharing',
    'b': 'We do not sell your data. Fraud cases may be referred to law '
        'enforcement with supporting evidence. Service providers (hosting, '
        'payments via Flutterwave) process data only to provide their services.'
  },
  {
    'h': 'Retention',
    'b': 'Voice notes are deleted from Nova servers after 24 hours and from '
        'archives after 30 days. Account data is kept while your account is '
        'active and deleted on request, except records we must keep for '
        'fraud prevention and legal compliance.'
  },
  {
    'h': 'Contact',
    'b': 'Privacy questions: open a ticket in the app via Settings → Support.'
  },
];
