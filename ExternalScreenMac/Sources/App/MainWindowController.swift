import Cocoa

/// Connection state for status indicator
enum ConnectionState {
    case idle, waiting, connected, error

    var dotColor: NSColor {
        switch self {
        case .idle: return .systemRed
        case .waiting: return .systemOrange
        case .connected: return .systemGreen
        case .error: return .systemRed
        }
    }
}

/// Main window for the macOS app
class MainWindow: NSWindow {
    private var statusLabel: NSTextField!
    private var statusDot: NSView!
    private var resolutionLabel: NSTextField!

    private var ipadButton: NSButton!
    private var ipadSubtitle: NSTextField!
    private var macListStack: NSStackView!

    private var resolutionPicker: NSPopUpButton!
    private var receiverCheckbox: NSButton!

    private var currentState: ConnectionState = .idle
    private var receiverNames: [String] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "External Screen"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.minSize = NSSize(width: 420, height: 400)
        self.center()
        self.isReleasedWhenClosed = false

        setupContent()
        renderDevices()
    }

    private func setupContent() {
        // Visual effect background
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        self.contentView = visualEffect

        // Main vertical stack
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        // Pins an arranged subview to the stack's full content width (insets excluded).
        func addFullWidth(_ view: NSView) {
            mainStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -48).isActive = true
        }

        // Header
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .centerY

        let headerIcon = NSImageView()
        headerIcon.image = NSApp.applicationIconImage
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 40),
            headerIcon.heightAnchor.constraint(equalToConstant: 40),
        ])
        headerIcon.setContentHuggingPriority(.required, for: .horizontal)

        let headerLabel = NSTextField(labelWithString: "External Screen")
        headerLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerStack.addArrangedSubview(headerIcon)
        headerStack.addArrangedSubview(headerLabel)
        addFullWidth(headerStack)

        // Status card
        let statusCard = makeCard()
        let statusCardStack = NSStackView()
        statusCardStack.orientation = .horizontal
        statusCardStack.spacing = 8
        statusCardStack.alignment = .centerY
        statusCardStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusCardStack)

        NSLayoutConstraint.activate([
            statusCardStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 12),
            statusCardStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -12),
            statusCardStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusCardStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
        ])

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        statusLabel = NSTextField(labelWithString: "Ready to start")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resolutionLabel = NSTextField(labelWithString: "")
        resolutionLabel.font = NSFont.systemFont(ofSize: 12)
        resolutionLabel.textColor = .secondaryLabelColor
        resolutionLabel.alignment = .right
        resolutionLabel.setContentHuggingPriority(.required, for: .horizontal)
        resolutionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusCardStack.addArrangedSubview(statusDot)
        statusCardStack.addArrangedSubview(statusLabel)
        statusCardStack.addArrangedSubview(resolutionLabel)
        addFullWidth(statusCard)

        // Displays card: iPad row + discovered Mac receivers
        let displaysCard = makeCard()
        let displaysStack = NSStackView()
        displaysStack.orientation = .vertical
        displaysStack.spacing = 12
        displaysStack.alignment = .leading
        displaysStack.translatesAutoresizingMaskIntoConstraints = false
        displaysCard.addSubview(displaysStack)

        NSLayoutConstraint.activate([
            displaysStack.topAnchor.constraint(equalTo: displaysCard.topAnchor, constant: 16),
            displaysStack.bottomAnchor.constraint(equalTo: displaysCard.bottomAnchor, constant: -16),
            displaysStack.leadingAnchor.constraint(equalTo: displaysCard.leadingAnchor, constant: 16),
            displaysStack.trailingAnchor.constraint(equalTo: displaysCard.trailingAnchor, constant: -16),
        ])

        let displaysHeader = NSTextField(labelWithString: "DISPLAYS")
        displaysHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        displaysHeader.textColor = .secondaryLabelColor
        displaysStack.addArrangedSubview(displaysHeader)

        // iPad row (persistent)
        ipadButton = NSButton(title: "Start", target: self, action: #selector(togglePipeline))
        ipadButton.bezelStyle = .rounded
        ipadButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let (ipadRow, _, ipadSub) = makeDeviceRow(
            symbol: "ipad",
            title: "iPad (USB)",
            subtitle: "Connect cable, open External Screen on iPad",
            button: ipadButton
        )
        ipadSubtitle = ipadSub
        displaysStack.addArrangedSubview(ipadRow)
        ipadRow.widthAnchor.constraint(equalTo: displaysStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        displaysStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: displaysStack.widthAnchor).isActive = true

        // Mac receiver rows (rebuilt on discovery/state changes)
        macListStack = NSStackView()
        macListStack.orientation = .vertical
        macListStack.spacing = 10
        macListStack.alignment = .leading
        displaysStack.addArrangedSubview(macListStack)
        macListStack.widthAnchor.constraint(equalTo: displaysStack.widthAnchor).isActive = true

        addFullWidth(displaysCard)

        // Settings card: resolution picker (iPad only) + receiver toggle
        let settingsCard = makeCard(alpha: 0.5)
        let settingsStack = NSStackView()
        settingsStack.orientation = .vertical
        settingsStack.spacing = 10
        settingsStack.alignment = .leading
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsCard.addSubview(settingsStack)

        NSLayoutConstraint.activate([
            settingsStack.topAnchor.constraint(equalTo: settingsCard.topAnchor, constant: 16),
            settingsStack.bottomAnchor.constraint(equalTo: settingsCard.bottomAnchor, constant: -16),
            settingsStack.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor, constant: 16),
            settingsStack.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor, constant: -16),
        ])

        let resRow = NSStackView()
        resRow.orientation = .horizontal
        resRow.spacing = 8
        resRow.alignment = .centerY

        let resLabel = NSTextField(labelWithString: "iPad Resolution:")
        resLabel.font = NSFont.systemFont(ofSize: 13)
        resLabel.setContentHuggingPriority(.required, for: .horizontal)

        resolutionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        let presets = DisplayPreset.allCases
        let defaultPreset = ExternalScreenConstants.defaultPreset
        for preset in presets {
            resolutionPicker.addItem(withTitle: "\(preset.rawValue) (\(preset.description))")
        }
        if let defaultIndex = presets.firstIndex(of: defaultPreset) {
            resolutionPicker.selectItem(at: defaultIndex)
        }
        resolutionPicker.target = self
        resolutionPicker.action = #selector(resolutionChanged(_:))

        resRow.addArrangedSubview(resLabel)
        resRow.addArrangedSubview(resolutionPicker)
        settingsStack.addArrangedSubview(resRow)

        receiverCheckbox = NSButton(
            checkboxWithTitle: "Allow using this Mac as a display",
            target: self,
            action: #selector(receiverCheckboxToggled(_:))
        )
        receiverCheckbox.font = NSFont.systemFont(ofSize: 12)
        let enabled = (NSApp.delegate as? AppDelegate)?.isReceiverEnabled ?? true
        receiverCheckbox.state = enabled ? .on : .off
        settingsStack.addArrangedSubview(receiverCheckbox)

        addFullWidth(settingsCard)

        // Flexible spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        mainStack.addArrangedSubview(spacer)

        // Footer
        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.spacing = 4
        footerStack.alignment = .centerY

        let infoLabel = NSTextField(labelWithString: "External Screen is open-source")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let githubBtn = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        githubBtn.bezelStyle = .inline
        githubBtn.font = NSFont.systemFont(ofSize: 11)

        footerStack.addArrangedSubview(infoLabel)
        footerStack.addArrangedSubview(githubBtn)
        addFullWidth(footerStack)
    }

    private func makeCard(alpha: CGFloat = 1.0) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(alpha).cgColor
        card.layer?.cornerRadius = 10
        return card
    }

    /// Builds a device row: icon, title over subtitle, trailing action button.
    private func makeDeviceRow(symbol: String, title: String, subtitle: String, button: NSButton) -> (NSStackView, NSTextField, NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            icon.image = img.withSymbolConfiguration(config)
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        button.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(button)
        return (row, titleLabel, subtitleLabel)
    }

    // MARK: - Rendering

    /// Re-renders the device list from current state: iPad row button/subtitle,
    /// one row per discovered Mac receiver, and settings enablement.
    private func renderDevices() {
        let appDelegate = NSApp.delegate as? AppDelegate
        let connectedMac = appDelegate?.connectedReceiverName

        // iPad row
        if connectedMac != nil {
            ipadButton.isEnabled = false
            ipadButton.title = "Start"
            ipadButton.bezelColor = nil
            ipadButton.contentTintColor = nil
            ipadSubtitle.stringValue = "Unavailable during a Mac session"
        } else {
            ipadButton.isEnabled = true
            ipadButton.contentTintColor = .white
            switch currentState {
            case .idle, .error:
                ipadButton.title = "Start"
                ipadButton.bezelColor = .systemGreen
                ipadSubtitle.stringValue = "Connect cable, open External Screen on iPad"
            case .waiting:
                ipadButton.title = "Stop"
                ipadButton.bezelColor = .systemRed
                ipadSubtitle.stringValue = "Waiting for iPad…"
            case .connected:
                ipadButton.title = "Stop"
                ipadButton.bezelColor = .systemRed
                ipadSubtitle.stringValue = "Streaming"
            }
        }

        // Resolution presets only apply to the iPad; Mac receivers use native scale
        resolutionPicker.isEnabled = (connectedMac == nil)

        // Mac receiver rows
        macListStack.arrangedSubviews.forEach { view in
            macListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if receiverNames.isEmpty {
            let empty = NSTextField(labelWithString: "No Macs found nearby")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            macListStack.addArrangedSubview(empty)
            return
        }

        let ipadStreaming = (connectedMac == nil && currentState == .connected)
        for name in receiverNames {
            let isConnectedRow = (name == connectedMac)

            let button = NSButton(
                title: isConnectedRow ? "Disconnect" : "Connect",
                target: self,
                action: #selector(macButtonClicked(_:))
            )
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            // Identify by name, not index: a queued click on a stale button must not
            // resolve to a different Mac after the discovered list reorders.
            button.identifier = NSUserInterfaceItemIdentifier(name)
            // Streaming to the iPad or to another Mac blocks new Mac connections
            button.isEnabled = isConnectedRow || (!ipadStreaming && connectedMac == nil)

            let subtitle: String
            if isConnectedRow {
                subtitle = currentState == .connected ? "Connected — native resolution" : "Connecting…"
            } else {
                subtitle = "Available"
            }

            let (row, _, _) = makeDeviceRow(
                symbol: "laptopcomputer",
                title: name,
                subtitle: subtitle,
                button: button
            )
            macListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: macListStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Actions

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/remixtedi/ExternalScreen") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePipeline() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.togglePipeline()
    }

    @objc private func macButtonClicked(_ sender: NSButton) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        guard let name = sender.identifier?.rawValue, !name.isEmpty else { return }

        if name == appDelegate.connectedReceiverName {
            appDelegate.disconnectFromMacReceiver()
        } else {
            appDelegate.connectToReceiver(named: name)
        }
    }

    @objc private func receiverCheckboxToggled(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.setReceiverEnabled(sender.state == .on)
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        let presets = DisplayPreset.allCases
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < presets.count else { return }

        let preset = presets[index]
        print("MainWindow: Resolution changed to \(preset.rawValue) (\(preset.description))")

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.setPreset(preset)
        }
    }

    // MARK: - State Updates

    func updateStatus(_ status: String, state: ConnectionState) {
        currentState = state
        statusLabel?.stringValue = status
        statusDot?.layer?.backgroundColor = state.dotColor.cgColor

        // Update resolution label when connected (iPad only; Mac receivers run native)
        let appDelegate = NSApp.delegate as? AppDelegate
        if state == .connected, let appDelegate {
            if appDelegate.connectedReceiverName != nil {
                resolutionLabel?.stringValue = "Native"
            } else {
                let preset = appDelegate.currentDisplayPreset
                resolutionLabel?.stringValue = "\(preset.width)x\(preset.height)"
            }
        } else {
            resolutionLabel?.stringValue = ""
        }

        renderDevices()
    }

    func updateStatus(_ status: String) {
        // Infer state from status text
        let state: ConnectionState
        let lower = status.lowercased()
        if lower.contains("connected") || lower.contains("streaming") {
            state = .connected
        } else if lower.contains("waiting") || lower.contains("starting") || lower.contains("connecting") {
            state = .waiting
        } else if lower.contains("failed") || lower.contains("error") {
            state = .error
        } else {
            state = .idle
        }
        updateStatus(status, state: state)
    }

    func updateReceivers(_ names: [String]) {
        receiverNames = names
        renderDevices()
    }

    func updateReceiverEnabled(_ enabled: Bool) {
        receiverCheckbox?.state = enabled ? .on : .off
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
