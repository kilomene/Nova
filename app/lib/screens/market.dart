import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import 'orders.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadListings());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Marketplace')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFFFC107),
        foregroundColor: Colors.black,
        child: const Icon(Icons.add),
        // Strict seller onboarding: only verified sellers may list.
        onPressed: () {
          final st = context.read<AppState>();
          if (!st.isDemo && st.sellerProfile.status != 'verified') {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SellerOnboardingScreen()));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sellers must verify identity first (buyers need nothing).')));
          } else {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateListingScreen()));
          }
        },
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search products',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF161616),
                border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => state.loadListings(query: _q.text.trim().isEmpty ? null : _q.text.trim()),
            ),
          ),
          Expanded(
            child: state.listings.isEmpty
                ? const Center(child: Text('No products yet — list the first one.', style: TextStyle(color: Colors.white38)))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.75, crossAxisSpacing: 10, mainAxisSpacing: 10),
                    itemCount: state.listings.length,
                    itemBuilder: (context, i) {
                      final l = state.listings[i];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductDetailScreen(listing: l))),
                        child: Container(
                          decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: const BoxDecoration(
                                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                                    gradient: LinearGradient(colors: [Color(0xFF2a2a2a), Color(0xFF1a1a1a)]),
                                  ),
                                  child: const Center(child: Icon(Icons.shopping_bag_outlined, color: Colors.white24, size: 44)),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    const SizedBox(height: 2),
                                    Text('\$${l.priceUsd.toStringAsFixed(2)} · ${l.asset}', style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold)),
                                    Row(
                                      children: [
                                        Text('@${l.handle}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                        const SizedBox(width: 4),
                                        Text('★ ${l.traderScore.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
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

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final listing = widget.listing;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Product')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 280,
              color: const Color(0xFF1a1a1a),
              child: const Center(child: Icon(Icons.shopping_bag_outlined, color: Colors.white24, size: 72)),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(listing.title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('\$${listing.priceUsd.toStringAsFixed(2)} · ${listing.asset}',
                      style: const TextStyle(color: Color(0xFFFFC107), fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Sold by @${listing.handle}', style: const TextStyle(color: Colors.white70)),
                      const SizedBox(width: 8),
                      Text('★ ${listing.traderScore.toStringAsFixed(0)} trader score', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(listing.description.isEmpty ? 'No description.' : listing.description, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  const Text('Pay with', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  RadioGroup<String>(
                    groupValue: _payMethod,
                    onChanged: (v) => setState(() => _payMethod = v!),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<String>(
                          value: 'flutterwave',
                          title: const Text('Card / mobile money (Flutterwave)', style: TextStyle(color: Colors.white, fontSize: 14)),
                          activeColor: const Color(0xFFFFC107),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                        RadioListTile<String>(
                          value: 'crypto',
                          title: const Text('Crypto from Nova wallet (USDC/USDT)', style: TextStyle(color: Colors.white, fontSize: 14)),
                          activeColor: const Color(0xFFFFC107),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                      onPressed: () async {
                        try {
                          final r = await state.createOrder(listingId: listing.id, paymentMethod: _payMethod);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order placed. Receipt saved to order history.')));
                            Navigator.of(context).pushReplacement(MaterialPageRoute(
                              builder: (_) => OrderDetailScreen(orderId: '${r['id']}'),
                            ));
                          }
                        } catch (e) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order failed: ${e is ApiException ? e.message : e}')));
                        }
                      },
                      child: const Text('Buy now'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Every purchase generates an itemized receipt + shipping timeline in your order history.',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('New listing')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _title, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Title', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: _desc, style: const TextStyle(color: Colors.white), maxLines: 3, decoration: const InputDecoration(labelText: 'Description', labelStyle: TextStyle(color: Colors.white54))),
            Row(
              children: [
                Expanded(child: TextField(controller: _price, style: const TextStyle(color: Colors.white), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (USD)', labelStyle: TextStyle(color: Colors.white54)))),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _asset,
                    dropdownColor: const Color(0xFF1a1a1a),
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Settle in', labelStyle: TextStyle(color: Colors.white54)),
                    items: const [DropdownMenuItem(value: 'USDC', child: Text('USDC')), DropdownMenuItem(value: 'USDT', child: Text('USDT'))],
                    onChanged: (v) => setState(() => _asset = v!),
                  ),
                ),
              ],
            ),
            TextField(controller: TextEditingController(text: _category), style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Category', labelStyle: TextStyle(color: Colors.white54)), onChanged: (v) => _category = v),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: _busy
                  ? null
                  : () async {
                      if (_title.text.trim().isEmpty || _price.text.isEmpty) return;
                      setState(() => _busy = true);
                      try {
                        await context.read<AppState>().createListing({
                          'title': _title.text.trim(),
                          'description': _desc.text.trim(),
                          'priceUsd': double.parse(_price.text),
                          'asset': _asset,
                          'category': _category.trim().isEmpty ? 'general' : _category.trim(),
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
