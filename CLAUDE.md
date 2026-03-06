# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming

The user-facing name is **"External Screen"** (with a space). Always use "External Screen" in UI text, labels, and user-facing strings. The codebase/repo uses "ExternalScreen" (no space) for identifiers, file names, and targets.

## Project Overview

External Screen is a macOS + iOS application that enables using an iPad as an external screen for a Mac via USB. The Mac captures screen content, encodes it as H.264, and streams it to the iPad, which decodes and renders via Metal. Touch events flow back from iPad to Mac.

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
```

**Requirements**: macOS 14.0+, iOS 17.0+, Xcode 15+. Mac app needs Screen Recording permission. Target: 60fps streaming.

## Architecture

### Communication Flow
```
Mac: Virtual Display → ScreenCaptureKit → H264Encoder → USB (PeerTalk) → iPad
iPad: USB (PeerTalk) → H264Decoder → MetalRenderer → Display
iPad: TouchCaptureView → USB → Mac: TouchEventHandler → CGEvents
```

### Key Components

**Shared/** - Cross-platform code
- `Constants.swift` - USB port (2345), `DisplayPreset` enum with 4 resolution tiers (default: medium 1440×1005 @ 25 Mbps), flow control (`maxInFlightFrames: 4`, `captureQueueDepth: 2`), keyframe interval (15 frames)
- `Protocol.swift` - Binary message protocol with 16-byte headers (handshake, displayConfig, frameData, frameAck, touch events, disconnect)

**ExternalScreenMac/Sources/**
- `App/AppDelegate.swift` - Main controller, status bar UI, pipeline orchestration
- `ScreenCapture/ScreenCaptureManager.swift` - ScreenCaptureKit frame capture
- `VideoEncoder/H264Encoder.swift` - VideoToolbox H.264 encoding, Annex-B NAL output
- `USB/USBDeviceManager.swift` - PeerTalk device detection, channel management
- `InputRelay/TouchEventHandler.swift` - Normalized touch coords → CGEvents
- `VirtualDisplay/` - Objective-C bridged virtual display creation

**ExternalScreenIOS/Sources/**
- `App/DisplayViewController.swift` - Full-screen landscape, orchestrates components
- `USB/USBConnectionManager.swift` - PeerTalk server listening on port 2345
- `VideoDecoder/H264Decoder.swift` - VideoToolbox H.264 decoding, SPS/PPS handling
- `Renderer/MetalRenderer.swift` - Metal texture from CVPixelBuffer, full-screen quad
- `Touch/TouchCaptureView.swift` - Touch capture, normalized coordinates (0.0-1.0)

### Dependencies

**PeerTalk** (vendored in both targets) - USB communication via usbmuxd. Compiled with `-fno-objc-arc`. Bridged via `*-Bridging-Header.h`.

**Native Frameworks**: ScreenCaptureKit, VideoToolbox, CoreMedia, Metal, MetalKit

## Configuration

- `project.yml` - XcodeGen configuration. Update `YOUR_TEAM_ID_HERE` with actual team ID.
- Debug logging: `/tmp/ExternalScreen_debug.log`

## Protocol Details

Messages use a binary format: 4-byte type + 8-byte timestamp + 4-byte payload length + payload.

Message types: handshake (0), displayConfig (1), frameData (2), frameAck (3), touchBegan (4), touchMoved (5), touchEnded (6), touchCancelled (7), disconnect (8).

Touch coordinates are normalized 0.0-1.0 relative to display bounds.

## Flow Control

Ack-based: iPad sends `frameAck` per frame; Mac tracks in-flight count. When `maxInFlightFrames` (4) exceeded, encoder drops P-frames but always sends keyframes. This prevents congestion without stalling the pipeline.
