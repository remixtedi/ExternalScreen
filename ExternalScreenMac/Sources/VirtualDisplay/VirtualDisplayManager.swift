import Foundation
import CoreGraphics

/// Delegate for virtual display events
protocol VirtualDisplayManagerDelegate: AnyObject {
    func virtualDisplayDidConnect(displayID: CGDirectDisplayID)
    func virtualDisplayDidDisconnect()
}

/// Manages the virtual display lifecycle
final class VirtualDisplayManager {

    // MARK: - Properties

    weak var delegate: VirtualDisplayManagerDelegate?

    private let bridge = VirtualDisplayBridge()
    private var isRunning = false

    /// Current display ID (0 if not active)
    var displayID: CGDirectDisplayID {
        bridge.displayID
    }

    /// Whether the virtual display is currently active
    var isActive: Bool {
        bridge.isActive
    }

    // MARK: - Configuration

    /// Mode dimensions handed to CGVirtualDisplayMode. These are always POINT/logical
    /// dimensions, not pixel dimensions -- CGVirtualDisplayMode's width/height are the
    /// logical size of the display, and `hiDPI` supplies the 2x Retina pixel backing on
    /// top of them. The iPad path stores preset (logical) dims here already; the Mac
    /// receiver path (`reconfigureForReceiver`) stores the receiver's point dims computed
    /// from its reported pixel dims / scale, for the same reason. Capture and encoding use
    /// the receiver's actual PIXEL dimensions, tracked separately by AppDelegate -- ScreenCaptureKit
    /// captures a HiDPI display's Retina backing store at 1:1, i.e. at pixel resolution.
    private(set) var width: Int
    private(set) var height: Int
    private(set) var refreshRate: Double
    private let ppi: Int
    private var displayName: String
    private var hiDPI: Bool
    private var serialNum: UInt32 = 0xE0190D01

    // MARK: - Initialization

    init(preset: DisplayPreset = ExternalScreenConstants.defaultPreset,
         refreshRate: Double = ExternalScreenConstants.defaultRefreshRate,
         ppi: Int = 144,
         displayName: String = "iPad External Display",
         hiDPI: Bool = true) {
        self.width = preset.width
        self.height = preset.height
        self.refreshRate = refreshRate
        self.ppi = ppi
        self.displayName = displayName
        self.hiDPI = hiDPI
    }

    convenience init(width: Int, height: Int,
                     refreshRate: Double = ExternalScreenConstants.defaultRefreshRate,
                     ppi: Int = 144,
                     displayName: String = "iPad External Display",
                     hiDPI: Bool = true) {
        self.init(preset: .medium, refreshRate: refreshRate, ppi: ppi, displayName: displayName, hiDPI: hiDPI)
        self.width = width
        self.height = height
    }

    /// Updates the display resolution using a preset
    @discardableResult
    func updateResolution(preset: DisplayPreset, refreshRate newRefreshRate: Double? = nil) -> Bool {
        return updateResolution(width: preset.width, height: preset.height, refreshRate: newRefreshRate)
    }

    // MARK: - Public Methods

    /// Creates and activates the virtual display
    /// - Returns: true if successful
    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            print("VirtualDisplayManager: Already running")
            return true
        }

        print("VirtualDisplayManager: Creating virtual display \(width)x\(height) @ \(refreshRate)Hz")

        let success = bridge.createDisplay(
            withWidth: UInt(width),
            height: UInt(height),
            ppi: UInt(ppi),
            refreshRate: refreshRate,
            name: displayName,
            hiDPI: hiDPI,
            serialNum: serialNum
        )

        if success {
            isRunning = true
            print("VirtualDisplayManager: Virtual display created with ID \(bridge.displayID)")
            delegate?.virtualDisplayDidConnect(displayID: bridge.displayID)
        } else {
            print("VirtualDisplayManager: Failed to create virtual display")
        }

        return success
    }

    /// Stops and destroys the virtual display
    func stop() {
        guard isRunning else { return }

        print("VirtualDisplayManager: Destroying virtual display")
        bridge.destroyDisplay()
        isRunning = false
        delegate?.virtualDisplayDidDisconnect()
    }

    /// Destroys and recreates the virtual display for a Mac receiver, sized so the
    /// receiver's *pixel* backing (its native panel resolution) maps 1:1 through
    /// ScreenCaptureKit.
    ///
    /// CGVirtualDisplayMode dimensions are POINT/logical dimensions -- exactly like the
    /// iPad path's preset dims -- with `hiDPI` giving the 2x Retina pixel backing on top.
    /// Passing the receiver's raw pixel size as the mode would render the UI at that many
    /// *points*, i.e. shrunk to a fraction of its intended size on a HiDPI receiver. So we
    /// divide by `scale` here to recover the logical point size and hand that to
    /// CGVirtualDisplayMode instead.
    ///
    /// - Parameters:
    ///   - pixelWidth: Receiver's native pixel width (its panel resolution).
    ///   - pixelHeight: Receiver's native pixel height.
    ///   - scale: Receiver's backing scale factor (2.0 for Retina). Values <= 0 are treated
    ///     as 1 (non-Retina, mode dims == pixel dims).
    ///   - rate: Refresh rate in Hz.
    /// - Returns: true on success.
    @discardableResult
    func reconfigureForReceiver(pixelWidth: Int, pixelHeight: Int, scale: CGFloat, refreshRate rate: Double) -> Bool {
        // Save the prior configuration so we can roll back if the new one fails to apply.
        let previousWidth = width
        let previousHeight = height
        let previousRefreshRate = refreshRate
        let previousDisplayName = displayName
        let previousSerialNum = serialNum
        let previousHiDPI = hiDPI

        if isRunning {
            bridge.destroyDisplay()
            isRunning = false
        }

        // Clamp non-finite/non-positive/sub-1 scale to 1 -- CGVirtualDisplayMode dims
        // should never exceed the receiver's own pixel dims, and a malformed
        // displayCapabilities payload could otherwise deliver NaN/inf here, which would
        // propagate through `Int(Double.nan)` below and trap.
        let effectiveScale = (scale.isFinite && scale > 0) ? max(scale, 1) : 1
        let pointWidth = Int((Double(pixelWidth) / Double(effectiveScale)).rounded())
        let pointHeight = Int((Double(pixelHeight) / Double(effectiveScale)).rounded())

        width = pointWidth
        height = pointHeight
        refreshRate = rate
        displayName = "Mac External Display"
        hiDPI = effectiveScale > 1
        serialNum = 0xE0190D02  // distinct identity so macOS remembers arrangement separately from iPad

        if start() {
            return true
        }

        print("VirtualDisplayManager: reconfigureForReceiver failed, rolling back to previous configuration")
        width = previousWidth
        height = previousHeight
        refreshRate = previousRefreshRate
        displayName = previousDisplayName
        serialNum = previousSerialNum
        hiDPI = previousHiDPI
        start()  // best-effort restore; caller still treats this reconfigure as failed

        return false
    }

    /// Updates the display resolution
    /// - Parameters:
    ///   - newWidth: New width in pixels
    ///   - newHeight: New height in pixels
    ///   - newRefreshRate: New refresh rate in Hz
    /// - Returns: true if successful
    @discardableResult
    func updateResolution(width newWidth: Int, height newHeight: Int, refreshRate newRefreshRate: Double? = nil) -> Bool {
        guard isRunning else {
            print("VirtualDisplayManager: Cannot update - display not running")
            return false
        }

        let rate = newRefreshRate ?? refreshRate
        let success = bridge.updateDisplay(
            withWidth: UInt(newWidth),
            height: UInt(newHeight),
            refreshRate: rate
        )

        if success {
            self.width = newWidth
            self.height = newHeight
            if let newRate = newRefreshRate {
                self.refreshRate = newRate
            }
        }

        return success
    }

    deinit {
        stop()
    }
}
