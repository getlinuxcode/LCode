# LCode — Architecture

LCode is a native Linux IDE (GTK4 / libadwaita) inspired by Xcode, for building Apple apps in
Swift / SwiftUI without a Mac.

## Principles

1. **Real builds = xtool.** Every build for an Apple device goes through
   [xtool](https://github.com/xtool-org/xtool): iOS SDK extracted from an `Xcode.xip` supplied by the
   user, signing, installation on the device.
2. **Simulator = native Linux recompilation.** The same sources are compiled a second time for
   Linux against **LSim**, a reimplementation of the SwiftUI API that draws into a window shaped like
   the target device. iOS is not emulated: SwiftUI's behavior is reproduced.
3. **Native.** GTK4 + libadwaita user interface, driven from Swift.

## Modules (SwiftPM)

```
LCode/
├── Package.swift
├── Sources/
│   ├── LSimUI/          SwiftUI-compatible public API (View, Text, stacks, controls, @State,
│   │                    modifiers…) + layout engine, animations, design profile.
│   │                    No graphics dependency: produces a backend-independent display list.
│   ├── LSimHost/        Cairo/Pango renderer (display list → pixels), device frame, event loop,
│   │                    mouse → touch, keyboard, headless screenshots, serving frames to the IDE.
│   ├── SwiftUI/         the module user code imports as `SwiftUI` (re-exports LSimUI + LSimHost).
│   ├── Combine/         Combine for the simulator (Apple's framework does not exist on Linux).
│   ├── AVFoundation/    AVPlayer, AVAudioPlayer…: real playback through ffmpeg / paplay.
│   ├── AVKit/           VideoPlayer.
│   ├── CoreMedia/       CMTime and friends.
│   ├── CoreVideo/       CVPixelBuffer (BGRA video frames LSim can draw).
│   ├── CGtk/ CAdw/ CSource/   system module maps for GTK4, libadwaita, GtkSourceView.
│   ├── LCodeKit/        IDE core: xtool projects, simulator/preview build generation, SwiftPM
│   │                    packages, signing, devices, templates, UI localization.
│   ├── lcode/           command-line tool (`lcode new | open | run | preview`).
│   └── LCodeIDE/        the GTK app (`lcode-ide`): editor, navigator, preview, simulator, console…
├── Examples/            SwiftUI test apps (Counter, Fruits, calibration Catalog, Sonde probe).
├── Tests/               LSimUI and LCodeKit tests, calibration references.
└── tools/calibration/   calibration bench (Python).
```

## Simulator pipeline

```
User project (SwiftUI)
        │  LCodeKit generates a temporary Linux package in <project>/.lcode/simulator/:
        │  - targets are links to the project's sources
        │  - `import SwiftUI` / `Combine` / `AVFoundation`… → LCode's modules
        │  - SwiftPM dependencies that import those frameworks are copied and rewired the same way
        │  - @main App entry point → LSimHost
        ▼
swift build (Linux toolchain) ──► native executable
        ▼
LSimHost : App → Scene → View tree
        ▼
LSimUI  : body resolution, state (@State / @Observable / ObservableObject), layout
        ▼
Display list ──► Cairo/Pango renderer ──► GTK window dressed as an iPhone (or the IDE's canvas)
```

Editing the project edits the simulator build, since its targets are links to the same sources.

## Fidelity — what matters

- **Layout**: SwiftUI's size-proposal algorithm (parent proposes, child chooses, parent places),
  default spacing, layout priorities, `Spacer`, `frame`, `padding` (16 pt by default), safe areas.
- **Typography**: Dynamic Type styles (`.body` = 17 pt, `.largeTitle` = 34 pt…), SF fonts installed
  locally (never redistributed), free fallback font otherwise.
- **System colors**: iOS 26+ palette, primary/secondary labels, grouped backgrounds, light and dark.
- **Components**: NavigationStack, List, TabView, sheet, alert, Form, Toggle…
- **Liquid Glass**: refraction, blur, saturation, tint and rim, measured on device.
- **Animations**: default curves (spring), transitions, gestures thresholds.

## Calibration bench

Fidelity relies on exact measurements, not on hand-made screenshots:

1. `Examples/Shared/Catalog/`: a SwiftUI catalog (every variant of a component, each with an
   identifier) compiled both for iOS (xtool) and for LSim.
2. On the iPhone, the **LCode Catalog** app inspects itself page by page, in light and dark mode:
   frames computed by SwiftUI (`onGeometryChange`), Core Animation layers (radii, curves, colors
   converted to sRGB, filters, shadows) and sRGB screenshots, sent to the PC.
3. `tools/calibration/receiver.py` receives the measurements; `tools/calibration/compare.py` has
   LSim render the same pages (`LSIM_SCREEN_ONLY`, `LSIM_DUMP`) and produces a report of the
   differences with iPhone | LSim | difference sheets.

### Automatic fitting

Measurable values live in a JSON **design profile** (`Sources/LSimUI/Profiles/iOS-27.2.json`):
text tracking per size and weight, button metrics per control size, colors, glass material, and
also *behaviors* (label color, `controlSize` sensitivity, fill type). LSim reads it at startup;
`LSIM_PROFILE` points to a variant without recompiling.

One command does everything:

```bash
python3 -I tools/calibration/calibrate.py
```

It builds and installs the catalog (xtool), waits for the app to be launched on the iPhone,
receives the measurements, then `fit.py` fits the profile (direct reading of layers, behavior
choice by search, margins and tracking by error correction, glass by pixel search), rebuilds
LSim, stores the references in `Tests/Calibration/` and runs `check.py` (non-regression: fails if
a marker drifts more than 0.5 pt from its accepted residual). Differences no setting explains are
listed as anomalies in the fit report: those, and only those, call for code changes.

Components not yet moved to the profile keep tables in code (`ListMetrics`, `NavigationMetrics`),
per design generation (`DesignStyle`: Liquid Glass or compatibility).

Known pitfalls: iPhone screenshots are Display P3 (convert before comparing); `lld` writes the
minimum OS version as the SDK version (force `-platform_version`), otherwise iOS runs the app in
compatibility mode; `xtool launch` does not work on iOS 27 (launch the app by hand).

## Running a project: `lcode run`

```bash
swift build --product lcode
.build/debug/lcode run <xtool project>            # LSim simulator
.build/debug/lcode run <xtool project> --device   # connected iPhone, through xtool
```

`LCodeKit` reads the project (`swift package dump-package`) and generates the simulator package
described above.

### API coverage — the probe

`Examples/iOS/Sonde` is an app written "like an ordinary developer would"; running it with
`lcode run Examples/iOS/Sonde` checks LSim's coverage.

Known approximations: `Picker` menus (tap selects the next option), `AsyncImage` without download,
`.swipeActions` / `.searchable` / `.refreshable` accepted without effect, some iOS 26 control
metrics estimated rather than measured.

## Accepted limits

- UIKit, hardware and closed frameworks (ARKit, camera, HealthKit…): stubs.
- The simulator validates UI and logic, not real performance.
- Final testing happens on a real device through xtool.

## Roadmap

- iPad, Mac and Apple TV device profiles.
- More frameworks for the simulator (networking helpers, MapKit, SwiftData…).
- Windows support.
