import AppKit
import SwiftUI

/// Where the tour is. AppController updates `keyHeld` and `handsFree` from the hold key, so the tour reacts to the
/// real key and the real dictation.
@MainActor
@Observable
final class TourModel {
    enum HandsFree { case waiting, talking, done }
    var step = 0
    /// The boxes the dictations land in, one per step.
    var listText = ""
    var handsFreeText = ""
    var keyHeld = false
    var handsFree = HandsFree.waiting

    func reset() { step = 0; listText = ""; handsFreeText = ""; keyHeld = false; handsFree = .waiting }
}

/// The short tour after setup: say a list, go hands-free, put the bar somewhere. One window, three steps.
struct TourView: View {
    let settings: Settings
    @Bindable var tour: TourModel
    /// The real bar's edge (a constant in snapshots, so they don't move it).
    @Binding var edge: PillModel.Edge
    /// The bee bobs live; snapshots pin it.
    var animate = true
    let done: () -> Void
    @FocusState private var boxFocused: Bool

    static let listSentence = "Book a restaurant for Friday. Firstly, find a venue, secondly, book a table for six, and thirdly, send the team the details."

    private var key: String { settings.holdKey.rawValue }
    private var step: Int { tour.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= step ? Brand.honey : Brand.raised).frame(width: 28, height: 4)
                }
                Spacer()
                Button("Skip tour", action: done).buttonStyle(.plain).foregroundStyle(Brand.sand)
                    .opacity(step < 2 ? 1 : 0).disabled(step == 2)  // hidden, not removed, so the row keeps its height
            }
            HStack(alignment: .center, spacing: 14) {
                Bee(animate: animate)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Brand.sora(24)).foregroundStyle(Brand.linen)
                    Text(LocalizedStringKey(subtitle)).font(.system(size: 14)).foregroundStyle(Brand.sand)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Group {
                switch step {
                case 0: listStep
                case 1: handsFreeStep
                default: barStep
                }
            }
            .frame(height: 330, alignment: .top)
            HStack {
                if step > 0 { Button("Back") { tour.step -= 1 }.buttonStyle(.plain).foregroundStyle(Brand.sand) }
                Spacer()
                // No Return shortcut while a text box is on screen: Return belongs to the box.
                Button(step == 2 ? "Start dictating" : "Next") { step == 2 ? done() : (tour.step += 1) }
                    .buttonStyle(HoneyButton()).keyboardShortcut(step == 2 ? .defaultAction : nil)
            }
        }
        .padding(28)
        .frame(width: 620)
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear { boxFocused = true }
        .onChange(of: step) { boxFocused = step < 2 }
        .onChange(of: tour.handsFreeText) {
            if tour.handsFree == .talking && !tour.handsFreeText.isEmpty { tour.handsFree = .done }
        }
        .brandWindow()
    }

    private var title: String { ["Say a list", "Go hands-free", "Put the bar where you like it"][step] }

    private var subtitle: String {
        [
            "Hold **\(key)** and read this out. MurmurBee numbers the steps.",
            "Double-tap **\(key)**, talk as long as you like, tap once to finish.",
            "Drag it to an edge of your screen, or click a spot here.",
        ][step]
    }

    // MARK: Step 1

    private var listStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeyboardRow(key: settings.holdKey, pressed: tour.keyHeld, callout: "Hold")
            Text("“\(Self.listSentence)”")
                .font(.system(size: 14)).foregroundStyle(Brand.linen).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surface))
            TranscriptBox(text: $tour.listText, listening: tour.keyHeld,
                          badge: tour.listText.contains("\n1. ") ? "Turned into a list" : nil, focused: $boxFocused)
        }
    }

    // MARK: Step 2

    private var handsFreeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeyboardRow(key: settings.holdKey, pressed: tour.keyHeld,
                        callout: tour.handsFree == .talking ? "Tap to finish" : tour.handsFree == .done ? "Again?" : "Tap twice")
            HStack(spacing: 8) {
                chip("Double-tap", done: tour.handsFree != .waiting, current: tour.handsFree == .waiting)
                chip("Talk", done: tour.handsFree == .done, current: tour.handsFree == .talking)
                chip("Tap once to finish", done: tour.handsFree == .done, current: false)
            }
            TranscriptBox(text: $tour.handsFreeText, listening: tour.handsFree == .talking,
                          badge: tour.handsFree == .done ? "Hands-free works" : nil, focused: $boxFocused)
        }
    }

    private func chip(_ text: String, done: Bool, current: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done || current ? Brand.honey : Brand.sand.opacity(0.6))
            Text(text).foregroundStyle(done || current ? Brand.linen : Brand.sand)
        }
        .font(.system(size: 13, weight: current ? .semibold : .regular))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(current ? Brand.raised : Brand.surface))
        .overlay(Capsule().strokeBorder(current ? Brand.honey : .clear))
    }

    // MARK: Step 3

    private var barStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            BarPicker(edge: $edge)
            Text("Your bar is \(edge == .bottom ? "at the bottom" : "on the \(edge.rawValue)"). Move it again whenever you like.")
                .font(.system(size: 13)).foregroundStyle(Brand.sand)
        }
    }
}

// MARK: - Pieces

/// The bee, bobbing gently.
private struct Bee: View {
    let animate: Bool
    var body: some View {
        if let bee = Brand.bee {
            let image = Image(nsImage: bee).resizable().interpolation(.high).frame(width: 56, height: 56)
            if animate {
                PhaseAnimator([false, true]) { up in image.offset(y: up ? -3 : 3).rotationEffect(.degrees(up ? -3 : 2)) }
                    animation: { _ in .easeInOut(duration: 1.3) }
            } else {
                image
            }
        }
    }
}

/// The bottom row of a Mac keyboard, with the hold key lit. It glows harder while the real key is down.
private struct KeyboardRow: View {
    let key: Hotkey.Key
    let pressed: Bool
    let callout: String

    private struct Cap: Identifiable { let id: String; let symbol: String; let word: String; let width: CGFloat }
    private let caps: [Cap] = [
        Cap(id: "fn", symbol: "fn", word: "", width: 40), Cap(id: "ctrl", symbol: "⌃", word: "control", width: 40),
        Cap(id: "lopt", symbol: "⌥", word: "option", width: 40), Cap(id: "lcmd", symbol: "⌘", word: "command", width: 54),
        Cap(id: "space", symbol: "", word: "", width: 150), Cap(id: "rcmd", symbol: "⌘", word: "command", width: 54),
        Cap(id: "ropt", symbol: "⌥", word: "option", width: 40),
    ]
    private var lit: String { key == .fn ? "fn" : "ropt" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(caps) { cap in keyCap(cap) }
            arrows
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        .padding(.top, 30)  // room for the callout over the lit key
        .frame(maxWidth: .infinity)
    }

    private func keyCap(_ cap: Cap) -> some View {
        let on = cap.id == lit
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(on ? Brand.honeyFill : Brand.raised)
            RoundedRectangle(cornerRadius: 6).stroke(on ? Brand.honeyFill : Brand.border)
            if cap.id == "fn" {
                Image(systemName: "globe").font(.system(size: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
                Text("fn").font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
            } else if !cap.symbol.isEmpty {
                Text(cap.symbol).font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
                Text(cap.word).font(.system(size: 8, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
            }
        }
        .foregroundStyle(on ? Brand.ink : Brand.sand)
        .frame(width: cap.width, height: 40)
        .shadow(color: on ? Brand.honeyFill.opacity(pressed ? 0.9 : 0.35) : .clear, radius: pressed ? 14 : 6)
        .scaleEffect(on && pressed ? 0.93 : 1)
        .offset(y: on && pressed ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .overlay(alignment: .top) {
            if on {
                Text(callout).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.honeyFill))
                    .offset(y: -36)
            }
        }
    }

    private var arrows: some View {
        HStack(alignment: .bottom, spacing: 3) {
            arrowKey("arrowtriangle.left.fill")
            VStack(spacing: 3) { arrowKey("arrowtriangle.up.fill"); arrowKey("arrowtriangle.down.fill") }
            arrowKey("arrowtriangle.right.fill")
        }
    }

    private func arrowKey(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 6)).foregroundStyle(Brand.sand)
            .frame(width: 28, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Brand.raised))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.border))
    }
}

/// Where a dictation lands during the tour, with "Listening…" while it records.
private struct TranscriptBox: View {
    @Binding var text: String
    let listening: Bool
    let badge: String?
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .focused(focused)
                .padding(10)
            if text.isEmpty {
                HStack(spacing: 7) {
                    if listening { Circle().fill(Color.red.opacity(0.8)).frame(width: 7, height: 7) }
                    Text(listening ? "Listening…" : "Your words appear here")
                }
                .font(.system(size: 14)).foregroundStyle(listening ? Brand.linen : Brand.sand.opacity(0.7))
                .padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.raised))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(badge != nil || listening ? Brand.honey : Brand.border))
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Label(badge, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.honey).padding(10)
            }
        }
    }
}

/// A small copy of the screen with the three places the bar can sit. Clicking one moves the real bar; dragging the
/// real bar moves this one.
private struct BarPicker: View {
    @Binding var edge: PillModel.Edge
    @State private var hover: PillModel.Edge?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.99, green: 0.89, blue: 0.66), Color(red: 0.95, green: 0.72, blue: 0.47)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(Color.white.opacity(0.55)).frame(height: 14)
                // A window, so the bar has something to be in the way of.
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { _ in Circle().fill(Color.black.opacity(0.15)).frame(width: 7, height: 7) }
                    }
                    ForEach([0.9, 0.72, 0.84, 0.6, 0.78], id: \.self) { f in
                        Capsule().fill(Color.black.opacity(0.1)).frame(width: (w - 220) * f, height: 6)
                    }
                }
                .padding(16)
                .frame(width: w - 150, height: h - 70, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .position(x: w / 2, y: 14 + (h - 70) / 2 + 12)
                ForEach(PillModel.Edge.allCases, id: \.self) { e in
                    spot(e).position(center(e, w, h))
                }
                // The bar itself, gliding between spots.
                Capsule().fill(Brand.barNight)
                    .frame(width: edge == .bottom ? 56 : 12, height: edge == .bottom ? 12 : 56)
                    .shadow(color: Brand.honeyFill.opacity(0.6), radius: 8)
                    .position(center(edge, w, h))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 290)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.border))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: edge)
    }

    private func center(_ e: PillModel.Edge, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        switch e {
        case .bottom: CGPoint(x: w / 2, y: h - 18)
        case .left: CGPoint(x: 20, y: (h + 14) / 2)
        case .right: CGPoint(x: w - 20, y: (h + 14) / 2)
        }
    }

    /// An empty spot: a dashed outline, filled in on hover.
    private func spot(_ e: PillModel.Edge) -> some View {
        let horizontal = e == .bottom
        return Button { edge = e } label: {
            ZStack {
                Capsule().fill(hover == e ? Brand.honeyFill.opacity(0.7) : Color.white.opacity(0.55))
                Capsule().strokeBorder(Color.black.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: horizontal ? 56 : 12, height: horizontal ? 12 : 56)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(edge == e ? 0 : 1)
        .onHover { hover = $0 ? e : nil }
        .help("Move the bar \(e == .bottom ? "to the bottom" : "to the \(e.rawValue)")")
    }
}
