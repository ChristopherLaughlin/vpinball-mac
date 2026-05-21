# CLAUDE.md

## What This Is

macOS-native fork of [Visual Pinball](https://github.com/vpinball/vpinball) — an open-source pinball table simulator. This fork adds native Cocoa integration (menus, Dock menu, file associations, packaging) while keeping the upstream engine intact.

Upstream remote: `upstream` → `vpinball/vpinball`

## Build Commands

```bash
# Prerequisites (one-time)
brew install autoconf automake libtool cmake bison curl
export PATH="$(brew --prefix bison)/bin:$PATH"

# Build external dependencies (slow, ~20 min first time; cached after)
platforms/macos-arm64/external.sh

# Copy CMake config (if not already done)
cp make/CMakeLists_bgfx-macos-arm64.txt CMakeLists.txt

# Configure + build
cmake -DCMAKE_BUILD_TYPE=Release -B build
cmake --build build -- -j$(sysctl -n hw.ncpu)

# Quick rebuild after code changes (just main.mm etc.)
cmake --build build --target vpinball -- -j$(sysctl -n hw.ncpu)

# Run
build/VPinballX_BGFX.app/Contents/MacOS/VPinballX_BGFX -play src/assets/exampleTable.vpx
```

**Important:** The repo path must not contain spaces. Use the symlink at `/Users/christopherlaughlin/vpinball-mac` for builds.

## Packaging

```bash
standalone/macos/package.sh build      # Full Release build
standalone/macos/package.sh sign       # Ad-hoc code sign (local use)
standalone/macos/package.sh sign-dev   # Developer ID sign (set SIGNING_IDENTITY)
standalone/macos/package.sh dmg        # Create DMG installer
standalone/macos/package.sh all        # build + sign + dmg
standalone/macos/package.sh release    # build + sign-dev + dmg + notarize
```

## Architecture

### Upstream Engine (don't modify unless necessary)

- `src/` — Core engine: physics, rendering (bgfx/Metal), VBScript scripting, ImGui UI
- `src/renderer/` — BGFX abstraction over Metal (macOS), OpenGL, Vulkan, DirectX
- `src/ui/live/` — ImGui-based in-game settings UI (F12)
- `standalone/` — Platform-specific entry points
- `third-party/` — Vendored deps including libwinevbs (Wine `windows.h` shim)

### Mac-Specific Code (our changes)

- `standalone/macos/main.mm` — App delegate, native Cocoa menus, Dock menu, recent files, file associations, About dialog
- `standalone/macos/Info_BGFX.plist` — Bundle metadata, UTI registration for `.vpx`
- `standalone/macos/package.sh` — Build, sign, DMG, notarize scripts
- `make/CMakeLists_bgfx-macos-arm64.txt` — CMake config (added UniformTypeIdentifiers framework)

### Key Globals

- `g_app` — VPApp instance
- `g_pplayer` — Player instance (active during gameplay)
- `g_pvp` — WinEditor instance
- `g_argc` / `g_argv` — Command-line args (set by main.mm before calling WinMain)

### Settings

INI file: `~/Library/Application Support/VPinballX/10.8/VPinballX.ini`
Property definitions: `src/core/Settings_properties.inl`

Key performance settings: `SyncMode`, `MaxFramerate`, `PFReflection`, `AAFactor`, `FXAA`, `MSAASamples`, `DisableAO`

### Rendering

Uses bgfx which selects Metal on macOS. Render thread gets user-interactive QoS via `pthread_set_qos_class_self_np()`. Resolution is 2x on Retina (e.g. 2940x1912 for a 1470x956 window).

## Syncing with Upstream

```bash
git fetch upstream
git merge upstream/master
# Resolve any conflicts in standalone/macos/ files
# Re-copy CMakeLists if upstream changed the source:
cp make/CMakeLists_bgfx-macos-arm64.txt CMakeLists.txt
```

## Controls Reference

| Action | Key |
|---|---|
| Left/Right Flipper | Left/Right Shift |
| Launch Ball | Enter |
| Nudge | Z / / / Space |
| Credit | 5 |
| Start | 1 |
| Settings | F12 |
| FPS Overlay | F11 |
| Pause | P |
| Exit | Escape |
