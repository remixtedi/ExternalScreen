#!/bin/bash

# ExternalScreen - Build, Install & Run Script
# Builds the Mac app, installs it to /Applications, and launches it.
# Handles team ID setup for first-time users.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

PROJECT="ExternalScreen.xcodeproj"
SCHEME_MAC="ExternalScreenMac"
SCHEME_IOS="ExternalScreenIOS"
CONFIG="Debug"
APP_NAME="ExternalScreenMac.app"
INSTALL_PATH="/Applications/$APP_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1" >&2; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  mac       Build, install, and run the Mac app (default)"
    echo "  build     Build the Mac app only (no install/run)"
    echo "  ios       Build the iOS app (requires connected iPad)"
    echo "  setup     Run initial project setup (team ID, dependencies)"
    echo "  clean     Clean build artifacts"
    echo ""
}

# --- Team ID setup ---

ensure_team_id() {
    local yml="$PROJECT_DIR/project.yml"
    if grep -q "YOUR_TEAM_ID_HERE" "$yml" 2>/dev/null; then
        warn "Development team not configured."
        echo ""
        echo "Available signing identities:"
        echo ""
        security find-certificate -c "Apple Development" -p /Library/Keychains/System.keychain 2>/dev/null | \
            openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true

        # List identities and extract team IDs
        local identities
        identities=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" || true)

        if [ -z "$identities" ]; then
            error "No Apple Development signing identities found."
            echo "Please open Xcode, go to Settings > Accounts, and sign in with your Apple ID."
            exit 1
        fi

        echo "$identities"
        echo ""

        # Try to auto-detect team ID from first valid certificate
        local team_id
        team_id=$(security find-certificate -c "Apple Development" -p 2>/dev/null | \
            openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | \
            grep -oE 'OU=[A-Z0-9]{10}' | head -1 | cut -d= -f2)

        if [ -n "$team_id" ]; then
            echo -n "Found team ID: $team_id. Use this? [Y/n] "
            read -r answer
            if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
                sed -i '' "s/YOUR_TEAM_ID_HERE/$team_id/" "$yml"
                info "Team ID set to $team_id"
            else
                echo -n "Enter your Apple Development Team ID: "
                read -r team_id
                sed -i '' "s/YOUR_TEAM_ID_HERE/$team_id/" "$yml"
                info "Team ID set to $team_id"
            fi
        else
            echo -n "Enter your Apple Development Team ID: "
            read -r team_id
            sed -i '' "s/YOUR_TEAM_ID_HERE/$team_id/" "$yml"
            info "Team ID set to $team_id"
        fi

        # Also update bundle IDs to be unique based on team ID
        local lower_team
        lower_team=$(echo "$team_id" | tr '[:upper:]' '[:lower:]')
        sed -i '' "s/bundleIdPrefix: com\.externalscreen/bundleIdPrefix: com.${lower_team}.externalscreen/" "$yml"
        sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER: com\.externalscreen\./PRODUCT_BUNDLE_IDENTIFIER: com.${lower_team}.externalscreen./" "$yml"
        info "Bundle IDs updated to be unique for your team"

        # Regenerate Xcode project
        info "Regenerating Xcode project..."
        xcodegen generate
    fi
}

# --- Commands ---

do_setup() {
    info "Running project setup..."
    if [ -f "$PROJECT_DIR/setup.sh" ]; then
        bash "$PROJECT_DIR/setup.sh"
    fi
    ensure_team_id
    info "Setup complete!"
}

do_clean() {
    info "Cleaning build artifacts..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME_MAC" clean 2>/dev/null || true
    info "Clean complete."
}

do_build_mac() {
    # Ensure project exists
    if [ ! -d "$PROJECT" ]; then
        error "Xcode project not found. Run '$0 setup' first."
        exit 1
    fi

    ensure_team_id

    info "Building $SCHEME_MAC..."
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME_MAC" \
        -configuration "$CONFIG" \
        build 2>&1 | tail -5 >&2

    # Find the built app
    local build_dir
    build_dir=$(xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME_MAC" \
        -configuration "$CONFIG" \
        -showBuildSettings 2>/dev/null | \
        grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')

    if [ ! -d "$build_dir/$APP_NAME" ]; then
        error "Built app not found at $build_dir/$APP_NAME"
        exit 1
    fi

    printf '%s' "$build_dir"
}

do_mac() {
    local build_dir
    build_dir=$(do_build_mac)

    # Kill existing instance
    if pgrep -x "ExternalScreenMac" > /dev/null 2>&1; then
        warn "Stopping running instance..."
        killall "ExternalScreenMac" 2>/dev/null || true
        sleep 1
    fi

    # Install to /Applications
    info "Installing to $INSTALL_PATH..."
    cp -R "$build_dir/$APP_NAME" "$INSTALL_PATH"

    # Launch
    info "Launching ExternalScreenMac..."
    open "$INSTALL_PATH"

    echo ""
    info "ExternalScreenMac is running!"
    echo ""
    echo "  If this is your first run, grant Screen Recording permission:"
    echo "  System Settings > Privacy & Security > Screen Recording"
    echo "  Then restart the app."
    echo ""
}

do_build_ios() {
    if [ ! -d "$PROJECT" ]; then
        error "Xcode project not found. Run '$0 setup' first."
        exit 1
    fi

    ensure_team_id

    # Find connected iOS device
    local device
    device=$(xcrun xctrace list devices 2>/dev/null | grep -i "iPad\|iPhone" | grep -v "Simulator" | head -1 | sed 's/ (.*//')

    if [ -n "$device" ]; then
        info "Building $SCHEME_IOS for device: $device"
        xcodebuild -project "$PROJECT" \
            -scheme "$SCHEME_IOS" \
            -configuration "$CONFIG" \
            -destination "platform=iOS,name=$device" \
            build 2>&1 | tail -5
        info "iOS build complete. Use Xcode to deploy to your device."
    else
        warn "No iOS device connected. Building for generic iOS device..."
        xcodebuild -project "$PROJECT" \
            -scheme "$SCHEME_IOS" \
            -configuration "$CONFIG" \
            -destination 'generic/platform=iOS' \
            build 2>&1 | tail -5
        info "iOS build complete. Connect your iPad and deploy via Xcode."
    fi
}

# --- Main ---

COMMAND="${1:-mac}"

case "$COMMAND" in
    mac)    do_mac ;;
    build)  do_build_mac > /dev/null ;;
    ios)    do_build_ios ;;
    setup)  do_setup ;;
    clean)  do_clean ;;
    -h|--help|help) usage ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
