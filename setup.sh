#!/bin/bash

# ExternalScreen - Project Setup Script
# This script sets up the Xcode project and dependencies

set -e

echo "=== ExternalScreen Project Setup ==="
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Homebrew not found. Please install Homebrew first:"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# Install XcodeGen if not present
if ! command -v xcodegen &> /dev/null; then
    echo "Installing XcodeGen..."
    brew install xcodegen
fi

# Clone PeerTalk if not present
PEERTALK_DIR="Vendor/PeerTalk"
if [ ! -d "$PEERTALK_DIR" ]; then
    echo "Cloning PeerTalk..."
    mkdir -p Vendor
    git clone https://github.com/rsms/peertalk.git "$PEERTALK_DIR"
fi

# Create symbolic links to PeerTalk sources in both projects
echo "Setting up PeerTalk integration..."

# For macOS
MAC_VENDOR="ExternalScreenMac/Vendor/PeerTalk"
if [ ! -d "$MAC_VENDOR" ]; then
    mkdir -p "ExternalScreenMac/Vendor"
    cp -r "$PEERTALK_DIR/peertalk" "$MAC_VENDOR"
fi

# For iOS
IOS_VENDOR="ExternalScreenIOS/Vendor/PeerTalk"
if [ ! -d "$IOS_VENDOR" ]; then
    mkdir -p "ExternalScreenIOS/Vendor"
    cp -r "$PEERTALK_DIR/peertalk" "$IOS_VENDOR"
fi

# Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Open ExternalScreen.xcodeproj in Xcode"
echo "2. Select your development team in Signing & Capabilities"
echo "3. Build and run ExternalScreenMac on your Mac"
echo "4. Build and run ExternalScreenIOS on your iPad"
echo ""
echo "Note: The macOS app requires Screen Recording permission."
echo "Grant it in System Settings → Privacy & Security → Screen Recording"
echo ""
