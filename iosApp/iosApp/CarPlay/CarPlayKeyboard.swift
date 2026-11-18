// On-screen keyboard for the CarPlay display. iOS never shows the system keyboard
// on a car screen, so Nuvio's search fields (Compose text input views and UIKit
// text fields) are fed through UIKeyInput from this touch keyboard instead.
// Concept adapted from YouDash's YCPKeyboard (GPL-3.0); rewritten for iOS 16.

import ObjectiveC
import SwiftUI
import UIKit

struct NuvioCarKeyboard: View {
    let secure: Bool
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onGo: () -> Void
    let onDone: () -> Void

    @State private var preview: String
    @State private var shifted = false
    @State private var symbols = false

    init(
        initialText: String,
        secure: Bool,
        onInsert: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onGo: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.secure = secure
        self.onInsert = onInsert
        self.onDelete = onDelete
        self.onGo = onGo
        self.onDone = onDone
        _preview = State(initialValue: initialText)
    }

    private var rows: [[String]] {
        if symbols {
            return [
                Array("1234567890").map(String.init),
                Array("-/:;()&@\"").map(String.init),
                Array(".,?!'#%+").map(String.init),
            ]
        }
        return [
            Array("qwertyuiop").map(String.init),
            Array("asdfghjkl").map(String.init),
            Array("zxcvbnm").map(String.init),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 6
            let rowCount: CGFloat = 5 // preview + 3 key rows + control row
            let keyHeight = max(30, (geometry.size.height - gap * (rowCount + 1)) / rowCount)
            let unit = min(88, (geometry.size.width - gap * 11) / 10.6)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Text(displayedPreview)
                        .font(.system(size: min(24, keyHeight * 0.5), weight: .medium))
                        .foregroundColor(preview.isEmpty ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: keyHeight)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                    key("Done", width: unit * 1.6, height: keyHeight, secondary: true, action: onDone)
                }

                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: gap) {
                        if index == 2 && !symbols {
                            key(systemImage: shifted ? "shift.fill" : "shift", width: unit * 1.3, height: keyHeight, secondary: true) {
                                shifted.toggle()
                            }
                        }
                        ForEach(rows[index], id: \.self) { character in
                            let label = shifted && !symbols ? character.uppercased() : character
                            key(label, width: unit, height: keyHeight) {
                                type(label)
                                shifted = false
                            }
                        }
                        if index == 2 {
                            key(systemImage: "delete.left", width: unit * 1.3, height: keyHeight, secondary: true) {
                                if !preview.isEmpty { preview.removeLast() }
                                onDelete()
                            }
                        }
                    }
                }

                HStack(spacing: gap) {
                    key(symbols ? "ABC" : "123", width: unit * 1.6, height: keyHeight, secondary: true) {
                        symbols.toggle()
                    }
                    key("space", width: unit * 5.2, height: keyHeight) { type(" ") }
                    key(systemImage: "magnifyingglass", width: unit * 2, height: keyHeight, accent: true, action: onGo)
                }
            }
            .padding(gap)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(.dark)
    }

    private var displayedPreview: String {
        if preview.isEmpty { return "Search" }
        return secure ? String(repeating: "•", count: preview.count) : preview
    }

    private func type(_ text: String) {
        preview += text
        onInsert(text)
    }

    private func key(
        _ title: String? = nil,
        systemImage: String? = nil,
        width: CGFloat,
        height: CGFloat,
        secondary: Bool = false,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title ?? "")
                }
            }
            .font(.system(size: min(24, height * 0.45), weight: .semibold))
            .foregroundColor(.white)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent ? Color.accentColor : Color.white.opacity(secondary ? 0.12 : 0.2))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title ?? systemImage ?? "")
    }
}

// MARK: - First-responder detection

/// Compose's iOS text fields are custom UIKeyInput views that don't post
/// UITextField notifications, so we observe becomeFirstResponder directly.
enum NuvioCarPlayResponderHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIResponder.self, #selector(UIResponder.becomeFirstResponder)),
              let replacement = class_getInstanceMethod(UIResponder.self, #selector(UIResponder.nuvioCarPlay_becomeFirstResponder))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension UIResponder {
    @objc fileprivate func nuvioCarPlay_becomeFirstResponder() -> Bool {
        // Implementations are exchanged: this calls the original becomeFirstResponder.
        let became = nuvioCarPlay_becomeFirstResponder()
        if became, let view = self as? UIView, self is UIKeyInput {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard NuvioCarPlaySurface.isPresentingOnCar else { return }
                    NuvioCarPlaySurface.shared.textInputBecameActive(view)
                }
            }
        }
        return became
    }
}
