# ExternalScreen

Use your iPad as an external display for your Mac over USB.

ExternalScreen captures your Mac's screen content, encodes it as H.264 video, and streams it to your iPad in real-time via USB. Touch events on the iPad flow back to the Mac, giving you a fully interactive second screen with no Wi-Fi needed.

## Features

- **Low-latency USB streaming** - No network required, just plug in via USB
- **H.264 hardware encoding/decoding** - Leverages VideoToolbox for efficient video compression
- **Metal rendering** - GPU-accelerated display on iPad
- **Touch input** - Interact with your Mac via iPad touch gestures
- **Virtual display** - Creates a dedicated virtual screen (no mirroring your main display)
- **Multiple resolution presets** - Choose from 4 resolution tiers to balance quality and performance

## Requirements

- **Mac**: macOS 14.0+ with Screen Recording permission
- **iPad**: iOS/iPadOS 17.0+
- **Xcode**: 15.0+ (for building from source)
- **USB cable** connecting Mac and iPad

## Installation

Since ExternalScreen is not on the App Store, you'll need to build from source or sideload.

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

1. Launch **ExternalScreenMac** on your Mac (it appears in the menu bar)
2. Connect your iPad to your Mac via USB
3. Launch **ExternalScreen** on your iPad
4. The connection establishes automatically over USB
5. Your Mac creates a virtual display that streams to the iPad

## Architecture

```
Mac: Virtual Display -> ScreenCaptureKit -> H264 Encoder -> USB (PeerTalk) -> iPad
iPad: USB (PeerTalk) -> H264 Decoder -> Metal Renderer -> Display
iPad: Touch Input -> USB -> Mac: Touch Event Handler -> CGEvents
```

### Project Structure

```
ExternalScreen/
├── Shared/                    # Cross-platform protocol & constants
├── ExternalScreenMac/        # macOS app
│   ├── Sources/
│   │   ├── App/               # AppDelegate, window management
│   │   ├── ScreenCapture/     # ScreenCaptureKit integration
│   │   ├── VideoEncoder/      # H.264 hardware encoding
│   │   ├── USB/               # PeerTalk device management
│   │   ├── InputRelay/        # Touch-to-CGEvent translation
│   │   └── VirtualDisplay/    # Virtual display creation
│   └── Vendor/PeerTalk/       # USB communication library
├── ExternalScreenIOS/        # iPadOS app
│   ├── Sources/
│   │   ├── App/               # AppDelegate, display controller
│   │   ├── Renderer/          # Metal rendering + shaders
│   │   ├── Touch/             # Touch capture (normalized coords)
│   │   ├── USB/               # PeerTalk connection manager
│   │   └── VideoDecoder/      # H.264 hardware decoding
│   └── Vendor/PeerTalk/
└── Vendor/PeerTalk/           # Original PeerTalk source
```

## Configuration

Resolution presets are defined in `Shared/Constants.swift`. The default is **medium** (1440x1005 @ 25 Mbps). Other presets: low, high, and ultra.

Flow control uses an ack-based system with a maximum of 4 in-flight frames to prevent congestion without stalling the pipeline.

## Dependencies

- **[PeerTalk](https://github.com/rsms/peertalk)** (MIT) - USB communication via usbmuxd (vendored)
- **Apple Frameworks**: ScreenCaptureKit, VideoToolbox, CoreMedia, Metal, MetalKit

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
