# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming

The user-facing name is **"External Screen"** (with a space). Always use "External Screen" in UI text, labels, and user-facing strings. The codebase/repo uses "ExternalScreen" (no space) for identifiers, file names, and targets.

## Project Overview

External Screen is a macOS + iOS application that enables using an iPad as an external screen for a Mac. It supports two modes:

1. **Host mode (iPad receiver)**: Uses USB to stream from a Mac to a connected iPad. The Mac captures screen content, encodes it as H.264, and streams it to the iPad, which decodes and renders via Metal. Touch events flow back from iPad to Mac.

2. **Receiver mode (Mac receiver)**: Any Mac with "Allow Using as Display" enabled (on by default) advertises itself in standby (TCP 2346 + Bonjour, no window). Picking its name under "Connect to Mac" on the host auto-connects; the receiver auto-activates into a fullscreen window. Esc or host disconnect returns it to standby. A Mac is never an active host and active receiver simultaneously. Details in "Mac-to-Mac Mode" below.

## Build Commands

```bash
# Initial setup (installs XcodeGen, clones PeerTalk, generates Xcode project)
./setup.sh

# Quick build & run (preferred over raw xcodebuild)
./run.sh           # Build, install to /Applications, and launch Mac app
./run.sh build     # Build Mac app only (no install/run)
./run.sh ios       # Build iOS app for connected device
./run.sh setup     # Initial setup (team ID, dependencies, xcodegen)
./run.sh clean     # Clean build artifacts

# Regenerate Xcode project after modifying project.yml
xcodegen generate

# Build from command line
xcodebuild -project ExternalScreen.xcodeproj -scheme ExternalScreenMac -configuration Debug build
xcodebuild -project ExternalScreen.xcodeproj -scheme ExternalScreenIOS -configuration Debug -destination 'platform=iOS,name=<device>' build

# Run unit tests (23 tests: protocol round-trips, MessageDeframer, FlowControlState)
xcodebuild test -project ExternalScreen.xcodeproj -scheme ExternalScreenTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

**Requirements**: macOS 14.0+, iOS 17.0+, Xcode 15+. Mac app needs Screen Recording permission (host mode) and Local Network permission (Mac-to-Mac, prompted on first launch). Target: 60fps streaming.

## Architecture

### Communication Flow
```
Mac host:  Virtual Display → ScreenCaptureKit → H264Encoder → USB (PeerTalk) → iPad
iPad:      USB (PeerTalk) → H264Decoder → MetalRenderer → Display
iPad:      TouchCaptureView → USB → Mac: TouchEventHandler → CGEvents

Mac host:  Virtual Display → ScreenCaptureKit → H264Encoder → TCP (Thunderbolt Bridge) → Mac receiver
Mac host:  CursorStreamer (120 Hz poll, off main thread) → TCP → Mac receiver: Metal cursor overlay
Mac recv:  TCP → H264Decoder → MetalRenderer → fullscreen window (frameAck back per frame)
```

### Key Components

**Shared/** - Cross-platform code
- `Constants.swift` - USB port (2345), TCP port (2346 for Mac-to-Mac), `DisplayPreset` enum with 4 resolution tiers (default: medium 1440×1005 @ 25 Mbps, iPad only — Mac receivers always use their native scale), flow control (`maxInFlightFrames: 4` USB / `networkMaxInFlightFrames: 8` TCP, `captureQueueDepth: 2`), keyframe interval (`keyframeInterval: 15` iPad / `networkKeyframeInterval: 60` Mac receivers), receiver bitrate scaling (~10 bits/px/s, capped 80 Mbps)
- `Protocol.swift` - Binary message protocol with 16-byte headers (handshake, displayConfig, frameData, frameAck, touch events, disconnect, displayCapabilities, cursorPosition, cursorImage)
- `Transport/` - Abstraction for frame transport (USB or network). Contains `FrameTransport` protocol, `PeerTalk` conformance in `USBDeviceManager`, `NetworkHostTransport`, `NetworkReceiverTransport`, `ReceiverBrowser` (Bonjour discovery), `MessageDeframer`, `FlowControlState`
- `Video/` - Cross-platform video components. Contains `H264Decoder` (VideoToolbox decoding, SPS/PPS handling) and `MetalRenderer` (Metal texture rendering with cursor overlay), moved from iOS target

**ExternalScreenMac/Sources/**
- `App/AppDelegate.swift` - Main controller, status bar UI, pipeline orchestration (host or receiver mode)
- `ScreenCapture/ScreenCaptureManager.swift` - ScreenCaptureKit frame capture (host mode)
- `VideoEncoder/H264Encoder.swift` - VideoToolbox H.264 encoding, Annex-B NAL output (host mode)
- `USB/USBDeviceManager.swift` - PeerTalk device detection, channel management, implements `FrameTransport` for USB
- `InputRelay/TouchEventHandler.swift` - Normalized touch coords → CGEvents (host mode)
- `InputRelay/CursorStreamer.swift` - Decoupled cursor position/image streaming (host mode)
- `VirtualDisplay/` - Objective-C bridged virtual display creation (host mode)
- `Receiver/ReceiverSessionController.swift` - Long-lived receiver service with two states: standby (transport listening + Bonjour advertising, no window) and active (fullscreen window, decoder, renderer). Auto-activates on a valid host handshake; auto-returns to standby on host disconnect or Esc, without stopping the listener

**ExternalScreenIOS/Sources/**
- `App/DisplayViewController.swift` - Full-screen landscape, orchestrates components
- `USB/USBConnectionManager.swift` - PeerTalk server listening on port 2345
- `Touch/TouchCaptureView.swift` - Touch capture, normalized coordinates (0.0-1.0)

Note: H264Decoder and MetalRenderer have been moved to `Shared/Video/` for cross-platform use.

### Dependencies

**PeerTalk** (vendored in both targets) - USB communication via usbmuxd. Compiled with `-fno-objc-arc`. Bridged via `*-Bridging-Header.h`.

**Native Frameworks**: ScreenCaptureKit, VideoToolbox, CoreMedia, Metal, MetalKit

## Configuration

- `project.yml` - XcodeGen configuration. Update `YOUR_TEAM_ID_HERE` with actual team ID.
- Debug logging: `/tmp/ExternalScreen_debug.log`
- `UserDefaults` key `receiverEnabled` (default: `true`) - backs the "Allow Using as Display" menu checkbox; controls whether receiver standby auto-starts at launch

## Protocol Details

Messages use a binary format: 4-byte type + 8-byte timestamp + 4-byte payload length + payload.

Message types:
- **0** handshake - Initial connection
- **1** displayConfig - Display resolution & metadata
- **2** frameData - H.264 compressed frame
- **3** frameAck - Flow control acknowledgment
- **4–7** touch events (began, moved, ended, cancelled) - iPad touch input (host mode only)
- **8** disconnect - Connection close
- **9** orientationChange - iPad orientation (landscape/portrait)
- **10** displayCapabilities - Receiver display info (Mac-to-Mac)
- **11** cursorPosition - Cursor coordinates (normalized 0.0-1.0)
- **12** cursorImage - Cursor image bitmap

Touch coordinates are normalized 0.0-1.0 relative to display bounds.

**Transport**: Host mode uses USB (port 2345); Mac-to-Mac receiver mode uses TCP (port 2346) with Bonjour discovery (_extscreen._tcp).

## Mac-to-Mac Mode

Connection sequence: host connects over TCP → host sends `handshake` (protocol version) → receiver validates version (mismatch → logged disconnect), replies with its own `handshake` + `displayCapabilities` (native pixel size + scale) → host recreates the virtual display at the receiver's logical size with Retina backing, then sends `displayConfig` and starts streaming. The receiver ignores frame/cursor messages until the handshake completes. Cursor streaming is decoupled from video: the host polls the cursor at 120 Hz off the main thread and sends position/image messages the receiver composites as a Metal overlay — cursor latency stays independent of the video pipeline.

## Flow Control

Ack-based: receiver (iPad or Mac) sends `frameAck` per frame; host tracks in-flight count per transport. When the window (`maxInFlightFrames: 4` USB, `networkMaxInFlightFrames: 8` TCP) is exceeded, the encoder drops P-frames but always sends keyframes, and forces a keyframe after any drop so the decoder's reference chain recovers. This prevents congestion without stalling the pipeline.

## Gotchas

- CLI builds fail signing while `project.yml` has `YOUR_TEAM_ID_HERE`; append `CODE_SIGNING_ALLOWED=NO` to xcodebuild for build/test checks.
- `CGVirtualDisplayMode` dimensions are LOGICAL (points); `hiDPI: true` adds a 2× Retina backing. Capture, encoder, and `displayConfig` all use PIXEL dimensions. Mixing the two renders the extended display at the wrong scale.
- Commit the regenerated `ExternalScreen.xcodeproj` together with any `project.yml` change (run `xcodegen generate` first) — the checked-in project must stay in sync.
- System cursor images carry oversized accessibility reps; `CursorStreamer` picks the rep matching point size × receiver scale — never "largest rep".
- NSEvent monitors and run-loop Timers stall while the main thread is in tracking mode (window drags, menus); anything latency-critical polls from a background queue instead.
