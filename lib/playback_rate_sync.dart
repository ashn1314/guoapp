import 'dart:async';

import 'package:media_kit/media_kit.dart';

class PlaybackRateSync {
  PlaybackRateSync(this.player);

  final Player player;
  Future<void> _rates = Future<void>.value();

  Future<void> apply(double speed) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(speed));
    return _rates;
  }

  Future<void> get pending => _rates;
}