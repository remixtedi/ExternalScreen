# External Screen

Use your iPad as an external display for your Mac over USB.

External Screen captures your Mac's screen content, encodes it as H.264 video, and streams it to your iPad in real-time via USB. Touch events on the iPad flow back to the Mac, giving you a fully interactive second screen with no Wi-Fi needed.

## Features

- **Low-latency USB streaming** - Stream to iPad over USB (no network required)
- **Mac-to-Mac network streaming** - Stream to another Mac over your local network or Thunderbolt (receiver mode)
- **H.264 hardware encoding/decoding** - Leverages VideoToolbox for efficient video compression
- **Metal rendering** - GPU-accelerated display on iPad and Mac
- **Touch input** - Interact with your Mac via iPad touch gestures (iPad receiver mode)
- **Cursor streaming** - Smooth cursor motion independent of frame rate (Mac-to-Mac mode)
- **Virtual display** - Creates a dedicated virtual screen (no mirroring your main display)
- **Multiple resolution presets** - Choose from 4 resolution tiers to balance quality and performance
- **Bonjour discovery** - Automatic discovery of other Macs available as a display, with one-click connect from the host

## Requirements

- **Mac**: macOS 14.0+ with Screen Recording permission
- **iPad**: iOS/iPadOS 17.0+
- **Xcode**: 15.0+ (for building from source)
- **USB cable** connecting Mac and iPad

## Installation

Since External Screen is not on the App Store, you'll need to build from source or sideload.

### Option 1: Build from Source (Recommended)

This is the simplest path. Requires Xcode 15+ and a free Apple ID.

```bash
# 1. Clone the repository
git clone https://github.com/remixtedi/ExternalScreen.git
cd ExternalScreen

# 2. Run setup (installs XcodeGen, clones PeerTalk, generates Xcode project)
./setup.sh

# 3. Open in Xcode
open ExternalScreen.xcodeproj
```

**In Xcode:**

4. Select your Apple ID under **Xcode > Settings > Accounts**
5. For each target (`ExternalScreenMac` and `ExternalScreenIOS`):
   - Select the target in project settings
   - Go to **Signing & Capabilities**
   - Set your **Team** to your Apple ID
   - Xcode will auto-generate a bundle identifier if needed
6. **Build and run `ExternalScreenMac`** on your Mac
7. Connect your iPad via USB
8. Select your iPad as the run destination and **build and run `ExternalScreenIOS`**

> **Note**: With a free Apple ID, the iOS app expires after 7 days and needs to be reinstalled. A paid Apple Developer account ($99/year) extends this to 1 year.

### Option 2: Sideload with AltStore

If someone provides a pre-built `.ipa` (e.g., from GitHub Releases):

1. Install [AltStore](https://altstore.io/) on your Mac and iPad
2. Download the `.ipa` from the [Releases](../../releases) page
3. Open the `.ipa` with AltStore to install on your iPad
4. Build and run the Mac app from source (see Option 1, steps 1-6)

> AltStore uses your free Apple ID to sign the app. It refreshes automatically but has the same 7-day limit as Xcode sideloading.

### Mac App: Granting Screen Recording Permission

The Mac app requires Screen Recording permission to capture screen content:

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Enable **ExternalScreenMac**
3. Restart the app if prompted

## Usage

### iPad Receiver (USB)

1. Launch **ExternalScreenMac** on your Mac (it appears in the menu bar)
2. Connect your iPad to your Mac via USB
3. Launch **ExternalScreen** on your iPad
4. The connection establishes automatically over USB
5. Your Mac creates a virtual display that streams to the iPad

### Mac Receiver (Local Network)

Install and launch **ExternalScreenMac** on both Macs and connect them to the same network (or a Thunderbolt/USB-C cable running a network bridge). No manual "receiver mode" step is needed — every Mac listens for incoming connections automatically.

1. On the Mac you want to use as a display, confirm **"Allow Using as Display"** is checked in the menu bar (it's on by default; this just controls whether the Mac is discoverable/connectable as a receiver)
2. On the other Mac (the host), open **Connect to Mac** in the menu bar — it lists other Macs discovered via Bonjour
3. Select the receiver Mac's name
4. The host automatically starts streaming, and the receiver Mac automatically goes fullscreen and starts displaying — no action needed on the receiver side
5. Press **Esc** on the receiver Mac, or disconnect from the host, to return the receiver to standby (listening, but no window) — its Bonjour listener keeps running so it can be reconnected to at any time

A Mac can't be an active receiver and an active host at the same time: starting the host pipeline is blocked while a Mac is actively displaying another host's stream, and an incoming connection is rejected while a Mac's own host pipeline is running.

## Architecture

### iPad Receiver Mode (USB)
```
Mac: Virtual Display -> ScreenCaptureKit -> H264 Encoder -> USB (PeerTalk) -> iPad
iPad: USB (PeerTalk) -> H264 Decoder -> Metal Renderer -> Display
iPad: Touch Input -> USB -> Mac: Touch Event Handler -> CGEvents
```

### Mac Receiver Mode (Local Network)
```
Host Mac: Virtual Display -> ScreenCaptureKit -> H264 Encoder -> TCP (Bonjour) -> Receiver Mac
Receiver Mac: TCP -> H264 Decoder -> Metal Renderer -> Fullscreen Display
Cursor: Host Mac -> TCP -> Receiver Mac (independent of frame rate)
```

### Project Structure

```
ExternalScreen/
├── Shared/                    # Cross-platform protocol & constants
│   ├── Protocol.swift         # Binary message format
│   ├── Constants.swift        # Ports, presets, flow control
│   ├── Transport/             # FrameTransport abstraction & implementations
│   └── Video/                 # Shared H264Decoder & MetalRenderer
├── ExternalScreenMac/        # macOS app (host & receiver modes)
│   ├── Sources/
│   │   ├── App/               # AppDelegate, window management, mode selection
│   │   ├── ScreenCapture/     # ScreenCaptureKit (host mode)
│   │   ├── VideoEncoder/      # H.264 encoding (host mode)
│   │   ├── USB/               # PeerTalk device management (host mode)
│   │   ├── InputRelay/        # Touch-to-CGEvent, cursor streaming
│   │   ├── VirtualDisplay/    # Virtual display (host mode)
│   │   └── Receiver/          # ReceiverSessionController (standby + fullscreen receiver states)
│   └── Vendor/PeerTalk/       # USB communication library
├── ExternalScreenIOS/        # iPadOS app
│   ├── Sources/
│   │   ├── App/               # AppDelegate, display controller
│   │   ├── USB/               # PeerTalk connection manager
│   │   └── Touch/             # Touch capture (normalized coords)
│   └── Vendor/PeerTalk/
└── Vendor/PeerTalk/           # Original PeerTalk source (cloned by setup.sh)
```

## Configuration

Resolution presets are defined in `Shared/Constants.swift`. The default is **medium** (1440x1005 @ 25 Mbps). Other presets: low, high, and ultra.

**Mac-to-Mac mode** uses TCP port 2346 with Bonjour discovery. Receiver resolution is native (Retina HiDPI), with H.264 bitrate scaled to ~10 bits/pixel/second and capped at 80 Mbps.

Flow control uses an ack-based system with a maximum of 4 in-flight frames to prevent congestion without stalling the pipeline.

## Dependencies

- **[PeerTalk](https://github.com/rsms/peertalk)** (MIT) - USB communication via usbmuxd (vendored)
- **Apple Frameworks**: ScreenCaptureKit, VideoToolbox, CoreMedia, Metal, MetalKit, Network (for TCP), Combine (for Bonjour discovery)
- **macOS 14.0+**, **iOS/iPadOS 17.0+** - Supports both iPad and Mac receivers

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

If you're making significant changes, please open an issue first to discuss.

## Troubleshooting

- **iPad not detected**: Make sure the iPad is connected via USB and is unlocked. Try disconnecting and reconnecting.
- **No video on iPad**: Check that Screen Recording permission is granted on the Mac. Check the debug log at `/tmp/ExternalScreen_debug.log`.
- **Poor performance**: Try switching to a lower resolution preset in `Constants.swift`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

PeerTalk is also licensed under the MIT License by [Rasmus Andersson](https://github.com/rsms/peertalk).
