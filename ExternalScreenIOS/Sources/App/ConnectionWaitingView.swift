import UIKit

/// Full-screen overlay shown when not connected to Mac
final class ConnectionWaitingView: UIView {

    private var pulsingDot: UIView!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        isUserInteractionEnabled = false

        // Gradient background
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(white: 0.08, alpha: 1).cgColor,
            UIColor(white: 0.03, alpha: 1).cgColor,
        ]
        gradient.frame = bounds
        layer.insertSublayer(gradient, at: 0)

        // Main content stack
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
        ])

        // App icon
        let iconView = UIImageView()
        iconView.image = UIImage(named: "AppLogo")
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 16
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),
        ])
        contentStack.addArrangedSubview(iconView)

        // Title
        contentStack.setCustomSpacing(16, after: iconView)
        let titleLabel = UILabel()
        titleLabel.text = "External Screen"
        titleLabel.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        contentStack.addArrangedSubview(titleLabel)

        // Subtitle
        contentStack.setCustomSpacing(6, after: titleLabel)
        let subtitleLabel = UILabel()
        subtitleLabel.text = "USB Display for Mac"
        subtitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.5, alpha: 1)
        contentStack.addArrangedSubview(subtitleLabel)

        // Connection status pill
        contentStack.setCustomSpacing(40, after: subtitleLabel)
        let pill = UIView()
        pill.backgroundColor = UIColor(white: 0.15, alpha: 1)
        pill.layer.cornerRadius = 20
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let pillStack = UIStackView()
        pillStack.axis = .horizontal
        pillStack.spacing = 10
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillStack)

        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            pillStack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            pillStack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        // Pulsing dot
        pulsingDot = UIView()
        pulsingDot.backgroundColor = .systemOrange
        pulsingDot.layer.cornerRadius = 5
        pulsingDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pulsingDot.widthAnchor.constraint(equalToConstant: 10),
            pulsingDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        pillStack.addArrangedSubview(pulsingDot)

        let pillLabel = UILabel()
        pillLabel.text = "Waiting for USB connection..."
        pillLabel.font = UIFont.systemFont(ofSize: 14)
        pillLabel.textColor = UIColor(white: 0.7, alpha: 1)
        pillStack.addArrangedSubview(pillLabel)

        contentStack.addArrangedSubview(pill)

        // Instructions
        contentStack.setCustomSpacing(40, after: pill)
        let instructionsStack = UIStackView()
        instructionsStack.axis = .vertical
        instructionsStack.spacing = 14
        instructionsStack.alignment = .leading
        contentStack.addArrangedSubview(instructionsStack)

        let steps: [(String, String)] = [
            ("cable.connector", "Connect your iPad to Mac via USB"),
            ("desktopcomputer", "Open External Screen on your Mac"),
            ("play.circle", "Click Start on the Mac app"),
        ]

        for (symbolName, text) in steps {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center

            let icon = UIImageView()
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            icon.image = UIImage(systemName: symbolName, withConfiguration: config)
            icon.tintColor = UIColor(white: 0.4, alpha: 1)
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

            let label = UILabel()
            label.text = text
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = UIColor(white: 0.4, alpha: 1)

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            instructionsStack.addArrangedSubview(row)
        }

        startPulsingAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Update gradient frame
        if let gradient = layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = bounds
        }
    }

    private func startPulsingAnimation() {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.8
        animation.toValue = 1.2
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulsingDot.layer.add(animation, forKey: "pulsing")
    }

    func show() {
        alpha = 1
        isHidden = false
        startPulsingAnimation()
    }

    func hide(animated: Bool = true) {
        if animated {
            UIView.animate(withDuration: 0.4, animations: {
                self.alpha = 0
            }, completion: { _ in
                self.isHidden = true
                self.pulsingDot.layer.removeAnimation(forKey: "pulsing")
            })
        } else {
            alpha = 0
            isHidden = true
            pulsingDot.layer.removeAnimation(forKey: "pulsing")
        }
    }
}
