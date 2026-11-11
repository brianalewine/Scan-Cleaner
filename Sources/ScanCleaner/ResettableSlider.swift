import SwiftUI

struct ResettableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    var resetValue: Double = 0
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @GestureState private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            let thumbSize: CGFloat = 7
            let travel = max(1, geometry.size.width - thumbSize)
            let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.10))
                    .frame(height: 4)
                    .padding(.horizontal, thumbSize / 2)
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: max(4, travel * fraction), height: 4)
                    .offset(x: thumbSize / 2)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.accentColor.opacity(hasKeyboardFocus ? 0.85 : 0), lineWidth: 2))
                    .shadow(color: .black.opacity(isDragging ? 0.22 : 0.14), radius: isDragging ? 3 : 1.5, y: 1)
                    .frame(width: thumbSize, height: 18)
                    .scaleEffect(isEnabled && (isHovering || isDragging) ? 1.12 : 1)
                    .offset(x: travel * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDragging)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, dragging, _ in dragging = isEnabled }
                .onChanged { event in
                guard isEnabled else { return }
                let fraction = min(1, max(0, (event.location.x - thumbSize / 2) / travel))
                setValue(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
            }.onEnded { _ in
                hasKeyboardFocus = false
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard isEnabled else { return }
                value = resetValue
                hasKeyboardFocus = false
            })
        }
        .opacity(isEnabled ? 1 : 0.35)
        .focusable(isEnabled)
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onExitCommand { hasKeyboardFocus = false }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { hasKeyboardFocus = false }
        }
        .onMoveCommand { direction in
            guard isEnabled else { return }
            switch direction {
            case .left, .down: setValue(value - step)
            case .right, .up: setValue(value + step)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: setValue(value + step)
            case .decrement: setValue(value - step)
            @unknown default: break
            }
        }
        .help("Double-click to reset")
    }
    private func setValue(_ newValue: Double) {
        value = min(range.upperBound, max(range.lowerBound, (newValue / step).rounded() * step))
    }
}

