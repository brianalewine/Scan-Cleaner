import SwiftUI

struct ResettableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    var resetValue: Double = 0
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 6)
            let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.15)).frame(height: 2)
                Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width: 3 + travel * fraction, height: 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary.opacity(0.85)).frame(width: 6, height: 12)
                    .offset(x: travel * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard isEnabled else { return }
                let fraction = min(1, max(0, (event.location.x - 3) / travel))
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

