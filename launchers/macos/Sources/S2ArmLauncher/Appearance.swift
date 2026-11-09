// UI synchronized from LumaNX 8872342 (MIT); see ../../README.md.
import SwiftUI
import AppKit

enum Brand {
    static var name: String { L("S2Arm") }
    static let latinName = "S2Arm"
    static let accent = Color(red:0.02,green:0.53,blue:0.57)
}

struct BrandMark: View {
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let icon = NSImage(contentsOf:Bundle.main.resourceURL?.appendingPathComponent("S2Arm.icns") ?? URL(fileURLWithPath:"/")) {
                BrandIcon(image:icon, size:size)
            } else {
                Image(systemName:"play.square.stack.fill").resizable().scaledToFit().foregroundStyle(Brand.accent.gradient).padding(size*0.12)
            }
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

// Dock applies an icon mask itself; in-app image views need their own transparent corners.
struct BrandIcon: View {
    let image: NSImage
    var size: CGFloat
    var body: some View {
        Image(nsImage:image).resizable().scaledToFit()
            .frame(width:size,height:size)
            .clipShape(RoundedRectangle(cornerRadius:size * 0.25,style:.continuous))
    }
}

/// The operating system owns the glass rendering, including increased contrast.
/// Reduce Transparency gets an opaque surface without the decorative light field.
struct LibraryBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Color(nsColor:.windowBackgroundColor)
            if !reduceTransparency {
                RadialGradient(colors:[Brand.accent.opacity(0.11),.clear],center:.topLeading,startRadius:0,endRadius:650)
                RadialGradient(colors:[Color.indigo.opacity(0.07),.clear],center:.bottomTrailing,startRadius:0,endRadius:500)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    var interactive = false
    func body(content:Content)->some View {
        if reduceTransparency {
            content.background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:radius))
                .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(.primary.opacity(0.12)))
        } else {
            #if S2A_MACOS14
            materialSurface(content)
            #else
            if #available(macOS 26.0, *) {
                content.glassEffect(interactive ? .regular.interactive() : .regular,in:RoundedRectangle(cornerRadius:radius))
            } else {
                materialSurface(content)
            }
            #endif
        }
    }

    private func materialSurface(_ content: Content) -> some View {
        content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))
            .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(.primary.opacity(0.06)))
    }
}

/// Keep the 26 appearance; older systems group the same content without glass merging.
struct PlatformGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        #if S2A_MACOS14
        content
        #else
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing:spacing) { content }
        } else {
            content
        }
        #endif
    }
}

private struct PlatformButtonStyle: ViewModifier {
    var prominent: Bool
    @ViewBuilder func body(content:Content)->some View {
        #if S2A_MACOS14
        borderedButton(content)
        #else
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule) }
        } else {
            borderedButton(content)
        }
        #endif
    }

    @ViewBuilder private func borderedButton(_ content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

extension View {
    func platformButtonStyle(prominent:Bool=false)->some View {
        modifier(PlatformButtonStyle(prominent:prominent))
    }
    func glassSurface(_ radius:CGFloat=18,interactive:Bool=false)->some View {modifier(GlassSurface(radius:radius,interactive:interactive))}
    func libraryControlSurface()->some View {frame(height:42).glassSurface(21)}
    func contentCard(_ radius:CGFloat=18)->some View {
        background(Color(nsColor:.controlBackgroundColor).opacity(0.75),in:RoundedRectangle(cornerRadius:radius))
            .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(.primary.opacity(0.06)))
    }
}

struct LibraryStat: View {
    let title:String
    let value:Int
    let symbol:String
    var body:some View {
        HStack(spacing:8) {
            Image(systemName:symbol).foregroundStyle(Brand.accent)
            Text("\(value)").font(.callout.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal,14).libraryControlSurface()
    }
}
