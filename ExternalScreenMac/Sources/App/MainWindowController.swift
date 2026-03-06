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
    private var resolutionPicker: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var statusDot: NSView!
    private var resolutionLabel: NSTextField!
    private var toggleButton: NSButton!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "External Screen"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.minSize = NSSize(width: 420, height: 380)
        self.center()
        self.isReleasedWhenClosed = false

        setupContent()
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
        mainStack.addArrangedSubview(headerStack)

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
        mainStack.addArrangedSubview(statusCard)

        // Controls card
        let controlsCard = makeCard()
        let controlsStack = NSStackView()
        controlsStack.orientation = .vertical
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsCard.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: controlsCard.topAnchor, constant: 16),
            controlsStack.bottomAnchor.constraint(equalTo: controlsCard.bottomAnchor, constant: -16),
            controlsStack.leadingAnchor.constraint(equalTo: controlsCard.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: controlsCard.trailingAnchor, constant: -16),
        ])

        // Resolution picker row
        let resRow = NSStackView()
        resRow.orientation = .horizontal
        resRow.spacing = 8
        resRow.alignment = .centerY

        let resLabel = NSTextField(labelWithString: "Resolution:")
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
        controlsStack.addArrangedSubview(resRow)

        // Toggle button
        toggleButton = NSButton(title: "Start", target: self, action: #selector(togglePipeline))
        toggleButton.bezelStyle = .rounded
        toggleButton.bezelColor = .systemGreen
        toggleButton.contentTintColor = .white
        toggleButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        controlsStack.addArrangedSubview(toggleButton)

        mainStack.addArrangedSubview(controlsCard)

        // Instructions card
        let instructionsCard = makeCard(alpha: 0.5)
        let instructionsStack = NSStackView()
        instructionsStack.orientation = .vertical
        instructionsStack.spacing = 10
        instructionsStack.translatesAutoresizingMaskIntoConstraints = false
        instructionsCard.addSubview(instructionsStack)

        NSLayoutConstraint.activate([
            instructionsStack.topAnchor.constraint(equalTo: instructionsCard.topAnchor, constant: 16),
            instructionsStack.bottomAnchor.constraint(equalTo: instructionsCard.bottomAnchor, constant: -16),
            instructionsStack.leadingAnchor.constraint(equalTo: instructionsCard.leadingAnchor, constant: 16),
            instructionsStack.trailingAnchor.constraint(equalTo: instructionsCard.trailingAnchor, constant: -16),
        ])

        let howToLabel = NSTextField(labelWithString: "HOW TO USE")
        howToLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        howToLabel.textColor = .secondaryLabelColor
        instructionsStack.addArrangedSubview(howToLabel)

        let steps: [(String, String)] = [
            ("cable.connector", "Connect your iPad via USB cable"),
            ("ipad", "Open External Screen on your iPad"),
            ("play.fill", "Click Start to begin streaming"),
        ]

        for (symbolName, text) in steps {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY

            let icon = NSImageView()
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                icon.image = img.withSymbolConfiguration(config)
                icon.contentTintColor = .secondaryLabelColor
            }
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            instructionsStack.addArrangedSubview(row)
        }

        mainStack.addArrangedSubview(instructionsCard)

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
        mainStack.addArrangedSubview(footerStack)
    }

    private func makeCard(alpha: CGFloat = 1.0) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(alpha).cgColor
        card.layer?.cornerRadius = 10
        return card
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/remixtedi/ExternalScreen") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePipeline() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.togglePipeline()
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

    func updateStatus(_ status: String, state: ConnectionState) {
        statusLabel?.stringValue = status
        statusDot?.layer?.backgroundColor = state.dotColor.cgColor

        // Update resolution label when connected
        if state == .connected {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                let preset = appDelegate.currentDisplayPreset
                resolutionLabel?.stringValue = "\(preset.width)x\(preset.height)"
            }
        } else {
            resolutionLabel?.stringValue = ""
        }

        // Update toggle button based on state
        switch state {
        case .idle, .error:
            toggleButton?.title = "Start"
            toggleButton?.bezelColor = .systemGreen
            toggleButton?.contentTintColor = .white
        case .waiting, .connected:
            toggleButton?.title = "Stop"
            toggleButton?.bezelColor = .systemRed
            toggleButton?.contentTintColor = .white
        }
    }

    func updateStatus(_ status: String) {
        // Infer state from status text
        let state: ConnectionState
        let lower = status.lowercased()
        if lower.contains("connected") || lower.contains("streaming") {
            state = .connected
        } else if lower.contains("waiting") || lower.contains("starting") {
            state = .waiting
        } else if lower.contains("failed") || lower.contains("error") {
            state = .error
        } else {
            state = .idle
        }
        updateStatus(status, state: state)
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
