import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../services/crypto_prices.dart';
import '../state/app_state.dart';
import 'orders.dart';
import 'cart_screen.dart';
import 'seller.dart';

/// Marketplace: listings, product detail, create listing.
/// Storefronts live inside profiles (see profile.dart Store tab).
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  final _q = TextEditingController();
  String _selectedCategory = 'all';
  static const _categories = [
    'all', 'electronics', 'fashion', 'home', 'beauty', 'sports',
    'toys', 'books', 'food', 'health', 'automotive', 'other',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final st = context.read<AppState>();
      st.loadListings();
      if (mounted) st.registerRefreshHandler('shop', refresh);
    });
  }

  @override
  void dispose() {
    _q.dispose();
    try {
      context.read<AppState>().unregisterRefreshHandler('shop');
    } catch (_) {}
    super.dispose();
  }

  /// Public refresh entry: pull-to-refresh + bottom-nav re-tap.
  Future<void> refresh() async {
    await context.read<AppState>().loadListings(
      query: _q.text.trim().isEmpty ? null : _q.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white38 : Colors.black45;
    final card = isDark ? const Color(0xFF161616) : const Color(0xFFF5F5F5);
    final thumbBg1 = isDark ? const Color(0xFF2a2a2a) : const Color(0xFFE8E8E8);
    final thumbBg2 = isDark ? const Color(0xFF1a1a1a) : const Color(0xFFD8D8D8);
    final thumbIcon = isDark ? Colors.white24 : Colors.black26;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('Marketplace', style: TextStyle(color: fg)),
        actions: [
          // Cart icon with badge
          Stack(
            children: [
              IconButton(
                icon: Icon(Icons.shopping_cart_outlined, color: fg),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CartScreen()),
                ),
              ),
              if (state.cartCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text('${state.cartCount}',
                        style: const TextStyle(color: Colors.white, fontSize: 10)),
                  ),
                ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
        // Verified users are auto-approved as sellers (no separate KYC).
        // Only unverified users see the seller onboarding.
        onPressed: () {
          final st = context.read<AppState>();
          final isVerifiedUser = st.me?.isVerified == true;
          final isVerifiedSeller = st.sellerProfile.status == 'verified';
          if (!st.isDemo && !isVerifiedUser && !isVerifiedSeller) {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SellerOnboardingScreen()));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sellers must verify identity first (buyers need nothing).')));
          } else {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateListingScreen()));
          }
        },
      ),
      body: Column(
        children: [
          // Category chips
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _categories.map((cat) {
                final selected = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(cat[0].toUpperCase() + cat.substring(1)),
                    selected: selected,
                    onSelected: (_) {
                      setState(() => _selectedCategory = cat);
                      state.loadListings(
                        query: _q.text.trim().isEmpty ? null : _q.text.trim(),
                        category: cat == 'all' ? null : cat,
                      );
                    },
                    selectedColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                  ),
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              style: TextStyle(color: fg),
              decoration: InputDecoration(
                hintText: 'Search products',
                hintStyle: TextStyle(color: sub),
                prefixIcon: Icon(Icons.search, color: sub),
                filled: true,
                fillColor: card,
                border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => state.loadListings(query: _q.text.trim().isEmpty ? null : _q.text.trim()),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: Theme.of(context).colorScheme.primary,
              onRefresh: refresh,
              child: state.listings.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                        Center(child: Text('No products yet — list the first one.', style: TextStyle(color: sub))),
                      ],
                    )
                  : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.75, crossAxisSpacing: 10, mainAxisSpacing: 10),
                    itemCount: state.listings.length,
                    itemBuilder: (context, i) {
                      final l = state.listings[i];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductDetailScreen(listing: l))),
                        child: Container(
                          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                        gradient: LinearGradient(colors: [thumbBg1, thumbBg2]),
                                      ),
                                      child: Center(child: Icon(Icons.shopping_bag_outlined, color: thumbIcon, size: 44)),
                                    ),
                                    Positioned(
                                      top: 6,
                                      right: 6,
                                      child: GestureDetector(
                                        onTap: () => state.toggleProductBookmark(l.id),
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            state.isProductBookmarked(l.id)
                                                ? Icons.bookmark
                                                : Icons.bookmark_border,
                                            color: state.isProductBookmarked(l.id)
                                                ? Theme.of(context).colorScheme.primary
                                                : Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l.title, style: TextStyle(color: fg, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    SizedBox(height: 2),
                                    Text('\$${l.priceUsd.toStringAsFixed(2)} · ${l.asset}', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                                    Row(
                                      children: [
                                        Text('@${l.handle}', style: TextStyle(color: sub, fontSize: 11)),
                                        const SizedBox(width: 4),
                                        Text('★ ${l.traderScore.toStringAsFixed(0)}', style: TextStyle(color: sub, fontSize: 11)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProductDetailScreen extends StatefulWidget {
  final Listing listing;
  const ProductDetailScreen({super.key, required this.listing});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  String _payMethod = 'flutterwave'; // flutterwave (fiat) | crypto (wallet)
  int _qty = 1;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final listing = widget.listing;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;
    final faint = isDark ? Colors.white38 : Colors.black38;
    final card = isDark ? const Color(0xFF1a1a1a) : const Color(0xFFE8E8E8);
    final thumbIcon = isDark ? Colors.white24 : Colors.black26;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, title: Text('Product', style: TextStyle(color: fg))),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 280,
              color: card,
              child: Center(child: Icon(Icons.shopping_bag_outlined, color: thumbIcon, size: 72)),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(listing.title, style: TextStyle(color: fg, fontSize: 22, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('\$${listing.priceUsd.toStringAsFixed(2)} · ${listing.asset}',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Sold by @${listing.handle}', style: TextStyle(color: sub)),
                      const SizedBox(width: 8),
                      Text('★ ${listing.traderScore.toStringAsFixed(0)} trader score', style: TextStyle(color: sub, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(listing.description.isEmpty ? 'No description.' : listing.description, style: TextStyle(color: sub)),
                  const SizedBox(height: 16),
                  Text('Pay with', style: TextStyle(color: fg, fontWeight: FontWeight.bold)),
                  RadioGroup<String>(
                    groupValue: _payMethod,
                    onChanged: (v) => setState(() => _payMethod = v!),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<String>(
                          value: 'flutterwave',
                          title: Text('Card / mobile money (Flutterwave)', style: TextStyle(color: fg, fontSize: 14)),
                          activeColor: Theme.of(context).colorScheme.primary,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                        RadioListTile<String>(
                          value: 'crypto',
                          title: Text('Crypto from Nova wallet (USDC/USDT)', style: TextStyle(color: fg, fontSize: 14)),
                          activeColor: Theme.of(context).colorScheme.primary,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 12),
                  // Quantity selector
                  Row(
                    children: [
                      Text('Quantity', style: TextStyle(color: fg, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        color: sub,
                        onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: card,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$_qty',
                            style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        color: Theme.of(context).colorScheme.primary,
                        onPressed: _qty < 99 ? () => setState(() => _qty++) : null,
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  // Add to Cart + Buy Now row
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.shopping_cart_outlined),
                          label: const Text('Add to Cart'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () {
                            state.addToCart(listing.id, qty: _qty);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Added $_qty to cart')),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 14)),
                          onPressed: () async {
                        if (_payMethod == 'crypto') {
                          // Crypto payment: select coin, enter PIN, send to seller.
                          await _payWithCrypto(context, listing, _qty);
                        } else {
                          // Flutterwave: in-app browser checkout.
                          try {
                            final r = await state.createOrder(listingId: listing.id, paymentMethod: _payMethod, quantity: _qty);
                            if (context.mounted) {
                              // TODO: Open Flutterwave checkout in in-app browser.
                              // For now, show order created.
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order placed. Complete payment in checkout.')));
                              Navigator.of(context).pushReplacement(MaterialPageRoute(
                                builder: (_) => OrderDetailScreen(orderId: '${r['id']}'),
                              ));
                            }
                          } catch (e) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order failed: ${e is ApiException ? e.message : e}')));
                          }
                        }
                      },
                      child: Text('Buy now (\$${(listing.priceUsd * _qty).toStringAsFixed(2)})'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Every purchase generates an itemized receipt + shipping timeline in your order history.',
                      style: TextStyle(color: faint, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  /// Pay with crypto: select coin, enter PIN, send to seller, create order.
  Future<void> _payWithCrypto(BuildContext context, Listing listing, int qty) async {
    final state = context.read<AppState>();
    final totalUsd = listing.priceUsd * qty;
    // Get seller's wallet address.
    String? sellerAddress;
    try {
      final seller = await state.api.get('/api/users/${listing.uid}');
      sellerAddress = seller['evm_address'] as String?;
    } catch (_) {}
    if (sellerAddress == null || sellerAddress.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Seller has no wallet address')),
        );
      }
      return;
    }
    // Show coin selector with real balances.
    final coin = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Pay \$${totalUsd.toStringAsFixed(2)} with crypto'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'ETH'),
            child: const Row(
              children: [Icon(Icons.attach_money), SizedBox(width: 12), Text('ETH (Ethereum)')],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'USDT'),
            child: const Row(
              children: [Icon(Icons.attach_money), SizedBox(width: 12), Text('USDT (Tether)')],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'USDC'),
            child: const Row(
              children: [Icon(Icons.attach_money), SizedBox(width: 12), Text('USDC (USD Coin)')],
            ),
          ),
        ],
      ),
    );
    if (coin == null || !context.mounted) return;
    // Get PIN.
    final pinCtrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm \$${totalUsd.toStringAsFixed(2)} payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Pay with $coin to @${listing.handle}'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'Wallet PIN',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, pinCtrl.text.trim()), child: const Text('Pay')),
        ],
      ),
    );
    if (pin == null || pin.isEmpty || !context.mounted) return;
    // Execute payment.
    try {
      // Convert USD to crypto amount.
      double cryptoAmount;
      if (coin == 'ETH') {
        final prices = await CryptoPrices.getPrices();
        final ethUsd = prices['ETH'] ?? 0;
        if (ethUsd <= 0) throw Exception('Price unavailable');
        cryptoAmount = totalUsd / ethUsd;
      } else {
        // USDT/USDC are 1:1 with USD.
        cryptoAmount = totalUsd;
      }
      // Send crypto to seller.
      String txHash;
      if (coin == 'ETH') {
        txHash = await state.wallet.sendEvm(
          pin: pin,
          to: sellerAddress,
          amountEth: cryptoAmount,
          api: state.api,
        );
      } else {
        // USDT/USDC token transfer.
        final cfg = await state.api.get('/api/config/tokens');
        final contractAddr = (coin == 'USDT' ? cfg['usdt'] : cfg['usdc']) as String?;
        if (contractAddr == null || contractAddr == '0x0000000000000000000000000000000000000000') {
          throw Exception('$coin contract not configured');
        }
        txHash = await state.wallet.sendToken(
          pin: pin,
          contractAddress: contractAddr,
          to: sellerAddress,
          amount: cryptoAmount,
          api: state.api,
        );
      }
      // Create the order with payment confirmed.
      final r = await state.createOrder(
        listingId: listing.id,
        paymentMethod: 'crypto',
        quantity: qty,
      );
      if (context.mounted) {
        final shortHash = txHash.length > 12 ? '${txHash.substring(0, 12)}…' : txHash;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Paid $cryptoAmount $coin ($shortHash). Order placed.')),
        );
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => OrderDetailScreen(orderId: '${r['id']}'),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed: $e')),
        );
      }
    }
  }
}

class CreateListingScreen extends StatefulWidget {
  const CreateListingScreen({super.key});

  @override
  State<CreateListingScreen> createState() => _CreateListingScreenState();
}

class _CreateListingScreenState extends State<CreateListingScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _price = TextEditingController();
  String _asset = 'USDC';
  String _category = 'general';
  bool _busy = false;
  final List<String> _imagePaths = [];
  final _picker = ImagePicker();

  Future<void> _pickImages() async {
    try {
      final images = await _picker.pickMultiImage();
      if (images.isNotEmpty && mounted) {
        setState(() {
          _imagePaths.addAll(images.map((x) => x.path).take(5 - _imagePaths.length));
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final ddBg = isDark ? const Color(0xFF1a1a1a) : const Color(0xFFF5F5F5);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, title: Text('New listing', style: TextStyle(color: fg))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Product images
            Text('Product photos', style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  // Add button
                  if (_imagePaths.length < 5)
                    GestureDetector(
                      onTap: _pickImages,
                      child: Container(
                        width: 100,
                        height: 100,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: ddBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: sub.withOpacity(0.3)),
                        ),
                        child: Icon(Icons.add_photo_alternate, color: sub, size: 36),
                      ),
                    ),
                  // Selected images
                  for (int i = 0; i < _imagePaths.length; i++)
                    Stack(
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            image: DecorationImage(
                              image: FileImage(File(_imagePaths[i])),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 12,
                          child: GestureDetector(
                            onTap: () => setState(() => _imagePaths.removeAt(i)),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: _title, style: TextStyle(color: fg), decoration: InputDecoration(labelText: 'Title', labelStyle: TextStyle(color: sub))),
            TextField(controller: _desc, style: TextStyle(color: fg), maxLines: 3, decoration: InputDecoration(labelText: 'Description', labelStyle: TextStyle(color: sub))),
            TextField(controller: _price, style: TextStyle(color: fg), keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Price (USD)', labelStyle: TextStyle(color: sub), helperText: 'Buyer pays via Flutterwave or crypto', helperStyle: TextStyle(color: sub))),
            TextField(controller: TextEditingController(text: _category), style: TextStyle(color: fg), decoration: InputDecoration(labelText: 'Category', labelStyle: TextStyle(color: sub)), onChanged: (v) => _category = v),
            SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary),
              onPressed: _busy
                  ? null
                  : () async {
                      if (_title.text.trim().isEmpty || _price.text.isEmpty) return;
                      setState(() => _busy = true);
                      try {
                        final state = context.read<AppState>();
                        // Upload product images first.
                        final imageKeys = <String>[];
                        for (final path in _imagePaths) {
                          final up = await state.api.upload('/api/uploads', path);
                          final key = up['key'] as String?;
                          if (key != null && key.isNotEmpty) imageKeys.add(key);
                        }
                        await state.createListing({
                          'title': _title.text.trim(),
                          'description': _desc.text.trim(),
                          'priceUsd': double.parse(_price.text),
                          'asset': _asset,
                          'category': _category.trim().isEmpty ? 'general' : _category.trim(),
                          'mediaKeys': imageKeys,
                        });
                        if (mounted) Navigator.of(context).pop();
                      } catch (e) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(_busy ? 'Publishing…' : 'Publish listing'),
            ),
          ],
        ),
      ),
    );
  }
}
