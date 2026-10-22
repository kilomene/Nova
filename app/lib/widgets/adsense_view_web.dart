import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

/// The "Nova Web Feed" AdSense unit (ayiijumo account, ca-pub-2431202994591245).
const _adSlot = '8675468809';

bool _registered = false;

void _ensureRegistered() {
  if (_registered) return;
  _registered = true;
  ui_web.platformViewRegistry.registerViewFactory('nova-adsense-feed', (int viewId) {
    final div = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = 'transparent';
    final ins = html.Element.tag('ins')
      ..className = 'adsbygoogle'
      ..style.display = 'block'
      ..style.width = '100%'
      ..style.height = '100%';
    ins.setAttribute('data-ad-client', 'ca-pub-2431202994591245');
    ins.setAttribute('data-ad-slot', _adSlot);
    ins.setAttribute('data-ad-format', 'fluid');
    ins.setAttribute('data-ad-layout-key', '-6t+ed+2i-1n-4w');
    div.append(ins);
    // Ask AdSense to fill this unit. Until the account is approved the
    // unit stays empty and transparent, so the house card behind it shows.
    final push = html.ScriptElement()
      ..text = '(adsbygoogle = window.adsbygoogle || []).push({});';
    div.append(push);
    return div;
  });
}

/// The live AdSense view for a web feed ad page.
Widget buildAdsenseView() {
  _ensureRegistered();
  return const HtmlElementView(viewType: 'nova-adsense-feed');
}
