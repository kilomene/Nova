import 'package:flutter/material.dart';

/// Wallet coin + network catalog for the Send/Receive flows.
/// Structure mirrors major exchange UX (coin → network → address).

class WalletNetwork {
  final String id; // 'trc20', 'erc20', 'bep20', 'bitcoin', 'ethereum'
  final String code; // 'TRC20', 'ERC20', 'BEP20'
  final String chain; // 'Tron', 'Ethereum', 'BNB Smart Chain'
  final int confirmations;
  final String minDeposit;
  final String addressKind; // 'evm' | 'btc' | 'tron'

  const WalletNetwork({
    required this.id,
    required this.code,
    required this.chain,
    required this.confirmations,
    required this.minDeposit,
    required this.addressKind,
  });
}

class WalletCoin {
  final String symbol; // BTC, ETH, USDT, USDC
  final String name;
  final Color brand;
  final String iconGlyph; // single-letter badge
  final List<WalletNetwork> networks;

  const WalletCoin({
    required this.symbol,
    required this.name,
    required this.brand,
    required this.iconGlyph,
    required this.networks,
  });

  /// Coins that need a network choice (more than one network).
  bool get needsNetwork => networks.length > 1;
}

const _trc20 = WalletNetwork(
  id: 'trc20',
  code: 'TRC20',
  chain: 'Tron',
  confirmations: 3,
  minDeposit: '0.01 USDT',
  addressKind: 'tron',
);
const _erc20 = WalletNetwork(
  id: 'erc20',
  code: 'ERC20',
  chain: 'Ethereum',
  confirmations: 12,
  minDeposit: '0.5 USDT',
  addressKind: 'evm',
);
const _bep20 = WalletNetwork(
  id: 'bep20',
  code: 'BEP20',
  chain: 'BNB Smart Chain',
  confirmations: 15,
  minDeposit: '0.01 USDT',
  addressKind: 'evm',
);
const _bitcoinNet = WalletNetwork(
  id: 'bitcoin',
  code: 'BTC',
  chain: 'Bitcoin',
  confirmations: 2,
  minDeposit: '0.0001 BTC',
  addressKind: 'btc',
);
const _ethereumNet = WalletNetwork(
  id: 'ethereum',
  code: 'ETH',
  chain: 'Ethereum',
  confirmations: 12,
  minDeposit: '0.001 ETH',
  addressKind: 'evm',
);

/// Supported deposit coins, in display order.
const List<WalletCoin> walletCoins = [
  WalletCoin(
    symbol: 'USDT',
    name: 'Tether',
    brand: Color(0xFF26A17B),
    iconGlyph: '₮',
    networks: [_trc20, _erc20, _bep20],
  ),
  WalletCoin(
    symbol: 'BTC',
    name: 'Bitcoin',
    brand: Color(0xFFF7931A),
    iconGlyph: '₿',
    networks: [_bitcoinNet],
  ),
  WalletCoin(
    symbol: 'ETH',
    name: 'Ethereum',
    brand: Color(0xFF627EEA),
    iconGlyph: 'Ξ',
    networks: [_ethereumNet],
  ),
  WalletCoin(
    symbol: 'USDC',
    name: 'USD Coin',
    brand: Color(0xFF2775CA),
    iconGlyph: '\$',
    networks: [
      WalletNetwork(
        id: 'erc20',
        code: 'ERC20',
        chain: 'Ethereum',
        confirmations: 12,
        minDeposit: '0.5 USDC',
        addressKind: 'evm',
      ),
      WalletNetwork(
        id: 'bep20',
        code: 'BEP20',
        chain: 'BNB Smart Chain',
        confirmations: 15,
        minDeposit: '0.01 USDC',
        addressKind: 'evm',
      ),
    ],
  ),
];
