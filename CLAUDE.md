# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming

The user-facing name is **"External Screen"** (with a space). Always use "External Screen" in UI text, labels, and user-facing strings. The codebase/repo uses "ExternalScreen" (no space) for identifiers, file names, and targets.

## Project Overview

External Screen is a macOS + iOS application that enables using an iPad as an external screen for a Mac. It supports two modes:

1. **Host mode (iPad receiver)**: Uses USB to stream from a Mac to a connected iPad. The Mac captures screen content, encodes it as H.264, and streams it to the iPad, which decodes and renders via Metal. Touch events flow back from iPad to Mac.

2. **Receiver mode (Mac receiver)**: Accepts screen streams from another Mac over the local network (TCP port 2346 via Bonjour). The receiver Mac decodes and renders the stream in a fullscreen window, with cursor position and image updates sent by the host.

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
- `Constants.swift` - USB port (2345), TCP port (2346 for Mac-to-Mac), `DisplayPreset` enum with 4 resolution tiers (default: medium 1440×1005 @ 25 Mbps), flow control (`maxInFlightFrames: 4`, `captureQueueDepth: 2`), keyframe interval (15 frames), receiver bitrate scaling (~10 bits/px/s, capped 80 Mbps)
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
- `Receiver/ReceiverSessionController.swift` - Fullscreen receiver mode; receives frames from remote host, manages decoder and renderer

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

## Protocol Details

Messages use a binary format: 4-byte type + 8-byte timestamp + 4-byte payload length + payload.

Message types:
- **0** handshake - Initial connection
- **1** displayConfig - Display resolution & metadata
- **2** frameData - H.264 compressed frame
- **3** frameAck - Flow control acknowledgment
- **4–7** touch events (began, moved, ended, cancelled) - iPad touch input (host mode only)
- **8** disconnect - Connection close
- **10** displayCapabilities - Receiver display info (Mac-to-Mac)
- **11** cursorPosition - Cursor coordinates (normalized 0.0-1.0)
- **12** cursorImage - Cursor image bitmap

Touch coordinates are normalized 0.0-1.0 relative to display bounds.

**Transport**: Host mode uses USB (port 2345); Mac-to-Mac receiver mode uses TCP (port 2346) with Bonjour discovery (_extscreen._tcp).

## Mac-to-Mac Mode

When the Mac app runs in receiver mode, it listens for connections from another Mac (host). The host discovers the receiver via Bonjour and initiates a TCP connection. The receiver decodes and renders incoming H.264 frames fullscreen with cursor overlay. Cursor streaming is decoupled from frame streaming; the host sends cursor updates (position and image) separately from video frames, allowing smooth cursor motion independent of frame rate.

## Flow Control

Ack-based: iPad sends `frameAck` per frame; Mac tracks in-flight count. When `maxInFlightFrames` (4) exceeded, encoder drops P-frames but always sends keyframes. This prevents congestion without stalling the pipeline.
