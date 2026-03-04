import Cocoa

/// Main window for the macOS app
class MainWindow: NSWindow {
    private var resolutionPicker: NSPopUpButton!
    private var statusLabel: NSTextField!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "External Screen"
        self.center()
        self.isReleasedWhenClosed = false

        setupContent()
    }

    private func setupContent() {
        let contentView = NSView(frame: self.contentRect(forFrameRect: self.frame))
        contentView.wantsLayer = true

        // Title
        let titleLabel = NSTextField(labelWithString: "External Screen")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
        titleLabel.frame = NSRect(x: 20, y: 260, width: 380, height: 30)
        contentView.addSubview(titleLabel)

        // Status
        let statusTitle = NSTextField(labelWithString: "Status:")
        statusTitle.frame = NSRect(x: 20, y: 220, width: 60, height: 20)
        contentView.addSubview(statusTitle)

        statusLabel = NSTextField(labelWithString: "Ready to start")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 85, y: 220, width: 280, height: 20)
        contentView.addSubview(statusLabel)

        // Resolution picker
        let resLabel = NSTextField(labelWithString: "Resolution:")
        resLabel.frame = NSRect(x: 20, y: 180, width: 80, height: 20)
        contentView.addSubview(resLabel)

        resolutionPicker = NSPopUpButton(frame: NSRect(x: 105, y: 175, width: 220, height: 30))
        let presets = DisplayPreset.allCases
        let defaultPreset = ExternalScreenConstants.defaultPreset
        for preset in presets {
            resolutionPicker.addItem(withTitle: "\(preset.rawValue) (\(preset.description))")
        }
        // Select the default preset
        if let defaultIndex = presets.firstIndex(of: defaultPreset) {
            resolutionPicker.selectItem(at: defaultIndex)
        }
        resolutionPicker.target = self
        resolutionPicker.action = #selector(resolutionChanged(_:))
        contentView.addSubview(resolutionPicker)

        // Buttons
        let startBtn = NSButton(title: "Start", target: nil, action: #selector(AppDelegate.startPipeline))
        startBtn.bezelStyle = .rounded
        startBtn.frame = NSRect(x: 120, y: 130, width: 80, height: 32)
        contentView.addSubview(startBtn)

        let stopBtn = NSButton(title: "Stop", target: nil, action: #selector(AppDelegate.stopPipeline))
        stopBtn.bezelStyle = .rounded
        stopBtn.frame = NSRect(x: 220, y: 130, width: 80, height: 32)
        contentView.addSubview(stopBtn)

        // Instructions
        let instructions = """
        Instructions:
        1. Connect your iPad via USB cable
        2. Open External Screen app on your iPad
        3. Click "Start" button above to begin

        A virtual display will appear in System Settings.
        """
        let instructionsLabel = NSTextField(wrappingLabelWithString: instructions)
        instructionsLabel.font = NSFont.systemFont(ofSize: 11)
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.frame = NSRect(x: 20, y: 10, width: 380, height: 110)
        contentView.addSubview(instructionsLabel)

        self.contentView = contentView
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        let presets = DisplayPreset.allCases
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < presets.count else { return }

        let preset = presets[index]
        print("MainWindow: Resolution changed to \(preset.rawValue) (\(preset.description))")

        // Notify AppDelegate of the change
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.setPreset(preset)
        }
    }

    func updateStatus(_ status: String) {
        statusLabel?.stringValue = status
    }

    func updateSelectedPreset(_ preset: DisplayPreset) {
        let presets = DisplayPreset.allCases
        if let index = presets.firstIndex(of: preset) {
            resolutionPicker?.selectItem(at: index)
        }
    }
}

/// Window controller wrapper
class MainWindowController: NSWindowController {
    convenience init() {
        let window = MainWindow()
        self.init(window: window)
    }

    func show() {
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
