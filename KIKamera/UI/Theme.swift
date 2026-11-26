import SwiftUI

@main
struct KIKameraApp: App {
    @StateObject private var library = LookLibrary()

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
    }
}

/// Luxus + Sci-Fi: tiefes Schwarz, Champagner-Gold für Aktionen, Neon-Cyan für KI und Live-Daten.
enum Theme {
    static let bg = Color(hex: 0x050608)
    static let panel = Color(hex: 0x0D0F13)
    static let panel2 = Color(hex: 0x151820)
    static let gold = Color(hex: 0xE6C47E)
    static let goldDeep = Color(hex: 0xB08A45)
    static let cyan = Color(hex: 0x5CF2E6)
    static let rec = Color(hex: 0xFF3B4A)
    static let text = Color(hex: 0xF5F2EA)
    static let muted = Color(hex: 0x8E939C)
    static let line = Color.white.opacity(0.09)

    static let goldGradient = LinearGradient(colors: [Color(hex: 0xF6DFA6), gold, goldDeep],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let aiGradient = AngularGradient(colors: [cyan, Color(hex: 0x7B8CFF), gold, cyan], center: .center)
    static let hairline = LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Glas-Panel mit feiner Lichtkante.
struct Glass: ViewModifier {
    var radius: CGFloat = 18
    var glow: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panel.opacity(0.55)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: (glow ?? .clear).opacity(0.35), radius: 14)
    }
}

extension View {
    func glass(_ radius: CGFloat = 18, glow: Color? = nil) -> some View {
        modifier(Glass(radius: radius, glow: glow))
    }
}

/// Goldener Haupt-Button.
struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(16, .bold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.goldGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.gold.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Dezenter Glas-Button.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(15, .semibold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .glass(14)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Kleiner Chip (Vorschläge, Filter).
struct Chip: View {
    let text: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(selected ? Color.black : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background {
                    if selected {
                        Capsule().fill(Theme.goldGradient)
                    } else {
                        Capsule().fill(Color.white.opacity(0.06))
                    }
                }
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
        }
        .buttonStyle(.plain)
    }
}

/// Animierter KI-Orb mit rotierendem Farbring.
struct AIOrb: View {
    var size: CGFloat = 54
    var active = false
    @State private var spin = 0.0
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.aiGradient)
                .blur(radius: active ? 14 : 8)
                .opacity(active ? 0.9 : 0.55)
                .scaleEffect(breathe ? 1.08 : 0.92)
            Circle()
                .strokeBorder(Theme.aiGradient, lineWidth: 2)
                .rotationEffect(.degrees(spin))
            Circle()
                .fill(Theme.bg)
                .padding(4)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Theme.aiGradient)
                .rotationEffect(.degrees(-spin / 4))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: active ? 2.2 : 6).repeatForever(autoreverses: false)) { spin = 360 }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Feine Überschrift im Sci-Fi-Stil.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, .bold))
            .tracking(1.6)
            .foregroundStyle(Theme.muted)
    }
}
