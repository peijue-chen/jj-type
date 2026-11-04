//
//  Theme.swift
//  jj-type
//
//  Shared design system for every window in the app: type scale, card
//  containers, tinted icon tiles, primary/secondary buttons and hint labels.
//  Colors derive from semantic label colors so light/dark mode both work
//  without a single hardcoded background.
//
//  Design language: macOS System Settings — sidebar + grouped rounded cards,
//  one accent per feature area, generous whitespace, 8/10/12 corner radii.
//

import AppKit

enum Theme {

    // MARK: - Type scale

    static func pageTitle() -> NSFont { .systemFont(ofSize: 22, weight: .bold) }
    static func sectionTitle() -> NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static func body() -> NSFont { .systemFont(ofSize: 13) }
    static func bodyMedium() -> NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static func caption() -> NSFont { .systemFont(ofSize: 11) }
    static func mono() -> NSFont { .monospacedSystemFont(ofSize: 12, weight: .medium) }

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10

    // MARK: - Buttons

    /// Accent-filled emphasis button (save / primary action).
    static func primaryButton(_ title: String, symbol: String? = nil) -> NSButton {
        let button = baseButton(title, symbol: symbol)
        button.bezelColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        return button
    }

    /// Regular rounded push button.
    static func button(_ title: String, symbol: String? = nil) -> NSButton {
        baseButton(title, symbol: symbol)
    }

    private static func baseButton(_ title: String, symbol: String?) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13)
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }
        return button
    }

    // MARK: - Text

    static func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = caption()
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        return field
    }

    static func sectionHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = sectionTitle()
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Right-aligned secondary label used in front of form controls.
    static func formLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = body()
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    // MARK: - Cards

    /// Rounded grouped container (System Settings style). Add arranged rows to
    /// `content`; the card sizes itself to the content plus padding.
    static func card() -> CardView { CardView() }

    /// Full-width hairline separator for use inside cards.
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    // MARK: - Menu bar brand mark

    /// Template "JJ▮" wordmark for the status item — the app icon's identity in
    /// one glance, monochrome so the system tints it for light/dark menu bars.
    static func menuBarImage() -> NSImage? {
        let text = NSAttributedString(
            string: "JJ",
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .heavy)])
        let textSize = text.size()
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        let cursorWidth: CGFloat = 3
        let cursorHeight = textSize.height * 0.66
        let gap: CGFloat = 2
        let size = NSSize(width: ceil(textSize.width + gap + cursorWidth),
                          height: ceil(textSize.height))

        let image = NSImage(size: size)
        image.lockFocus()
        text.draw(at: NSPoint(x: 0, y: (size.height - textSize.height) / 2))
        let cursor = NSRect(x: textSize.width + gap,
                            y: (size.height - cursorHeight) / 2,
                            width: cursorWidth, height: cursorHeight)
        NSBezierPath(roundedRect: cursor, xRadius: 1.5, yRadius: 1.5).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

/// Rounded grouped container whose fill/border re-resolve on appearance
/// changes via `updateLayer` (both light and dark without manual tracking).
final class CardView: NSView {
    let content = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Theme.rowSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let pad = Theme.cardPadding
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = Theme.cornerRadius
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    /// Separates two logical groups inside one card with a hairline.
    func addSeparator() {
        content.addArrangedSubview(Theme.separator())
    }
}

/// Small rounded-square tile with a vertical gradient and a white SF Symbol —
/// the visual signature of macOS System Settings rows and sidebars.
final class IconTileView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let imageView = NSImageView()

    init(symbol: String, side: CGFloat, colors: [NSColor]) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.cornerRadius = side * 0.28
        layer?.addSublayer(gradientLayer)

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let inset = side * 0.22
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = bounds.width * 0.28
    }
}
