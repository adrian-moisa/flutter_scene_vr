import 'dart:async';

import 'package:flutter/widgets.dart';

/// Reports a current example's load failure without blaming a later selection.
/// Loaders must still check [State.mounted] after awaits before attaching data.
void loadExample(State owner, Future<void> Function() load) {
  unawaited(
    Future<void>.sync(load).catchError((Object error, StackTrace stack) {
      if (!owner.mounted) return;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Flutter Scene gallery',
          context: ErrorDescription(
            'while loading ${owner.widget.runtimeType}',
          ),
        ),
      );
    }),
  );
}
