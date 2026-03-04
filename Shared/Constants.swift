import Foundation

/// Resolution preset for display scaling
public enum DisplayPreset: String, CaseIterable {
    case largeUI = "Large UI"           // 1194×834 - Matches iPad logical resolution
    case medium = "Medium"              // 1440×1005 - Like 27" 1440p monitor
    case moreSpace = "More Space"       // 1600×1117 - Balance of space and readability
    case native = "Native"              // 2388×1668 - Full resolution, smallest UI

    public var width: Int {
        switch self {
        case .largeUI: return 1194
        case .medium: return 1440
        case .moreSpace: return 1600
        case .native: return 2388
        }
    }

    public var height: Int {
        switch self {   
        case .largeUI: return 834
        case .medium: return 1005
        case .moreSpace: return 1117
        case .native: return 1668
        }
    }

    /// Recommended bitrate for this resolution (in bps)
    /// At 60fps, higher bitrate per frame for sharp text without congestion
    public var recommendedBitrate: Int {
        switch self {
        case .largeUI: return 15_000_000   // 15 Mbps - sharp text at 60fps
        case .medium: return 25_000_000    // 25 Mbps - sharp text at 60fps
        case .moreSpace: return 30_000_000 // 30 Mbps - sharp text at 60fps
        case .native: return 40_000_000    // 40 Mbps - sharp text at 60fps
        }
    }

    public var description: String {
        return "\(width)×\(height)"
    }
}

/// Shared constants between macOS and iOS apps
public enum ExternalScreenConstants {
    /// Port for PeerTalk USB communication
    public static let usbPort: UInt16 = 2345

    /// Default display preset
    public static let defaultPreset: DisplayPreset = .medium

    /// Default refresh rate
    public static let defaultRefreshRate: Double = 60.0

    /// Fallback refresh rate for non-ProMotion displays
    public static let fallbackRefreshRate: Double = 60.0

    /// Keyframe interval (every N frames)
    /// At 60fps, every 15 frames = every 0.25 sec for quick error recovery
    public static let keyframeInterval: Int = 15  // Every 15 frames at 60fps = every 0.25 sec

    /// Protocol version for compatibility checking
    public static let protocolVersion: UInt32 = 1

    /// Maximum frame size in bytes (for buffer allocation)
    public static let maxFrameSize: Int = 1024 * 1024 * 2  // 2 MB

    /// Lower queue depth for reduced latency (1 causes SCK stalls, 2 is minimum safe)
    public static let captureQueueDepth: Int = 2

    /// Maximum frames in-flight before dropping new P-frames
    /// Value of 4 balances latency with USB round-trip time (~15ms at 120fps)
    public static let maxInFlightFrames: UInt32 = 4
}
