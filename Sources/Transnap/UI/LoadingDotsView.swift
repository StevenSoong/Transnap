import AppKit

final class LoadingDotsView: NSView {
    private let dotSize: CGFloat = 4.5
    private let dotSpacing: CGFloat = 3.5
    private var dots: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupDots()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupDots()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 14) }

    override func layout() {
        super.layout()
        let totalWidth = dotSize * 3 + dotSpacing * 2
        let startX = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotSize) / 2
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: startX + CGFloat(index) * (dotSize + dotSpacing),
                y: y,
                width: dotSize,
                height: dotSize
            )
            dot.cornerRadius = dotSize / 2
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotColor()
    }

    func startAnimating() {
        stopAnimating()
        isHidden = false

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dots.forEach { $0.opacity = 0.72 }
            return
        }

        for (index, dot) in dots.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.24, 1.0, 0.24]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            pulse.duration = 0.9
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.14
            pulse.repeatCount = .infinity
            pulse.fillMode = .both
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: "transnap.loadingPulse")
        }
    }

    func stopAnimating() {
        for dot in dots {
            dot.removeAnimation(forKey: "transnap.loadingPulse")
            dot.opacity = 0.24
        }
    }

    private func setupDots() {
        guard dots.isEmpty else { return }
        for _ in 0..<3 {
            let dot = CALayer()
            dot.opacity = 0.24
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        updateDotColor()
    }

    private func updateDotColor() {
        let color = NSColor.secondaryLabelColor.cgColor
        dots.forEach { $0.backgroundColor = color }
    }
}
