import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

// One scene backdrop for the desktop/web gallery and direct OpenXR eyes.
// Keep it separate from the floating panels' light or dark UI theme.
const galleryBackgroundColor = Color(0xfffdf7ff);

// Shared instructions for the demo's Controls card and the gallery Help tab.
const galleryVrControlsHelp =
    'Aim + trigger: select.\n'
    'Aim at a panel + that hand’s stick: scroll.\n\n'
    'Aim away from panels to navigate:\n'
    'Left stick: orbit the scene target.\n'
    'Right stick: forward, back or sideways.\n'
    'Head tracking stays independent.\n\n'
    'Hold grip on a panel to move it.\n'
    'Held hand’s stick: forward = farther; back = closer. Release grip to place.\n\n'
    'Recenter: reset the view.\n'
    'Reset panels: restore their layout.\n'
    'Restart: restore example defaults.\n\n'
    'Examples: switch scene.\n'
    'Controls: example options.\n'
    'Settings: rendering options.\n\n'
    'FPS button: toggle all UI. Scene and stats keep running; the graph returns with UI.\n'
    'FPS counts completed stereo frames, not headset refresh.';

/// Whether the app-wide example picker and settings button are visible.
final ValueNotifier<bool> exampleChromeVisible = ValueNotifier(true);
