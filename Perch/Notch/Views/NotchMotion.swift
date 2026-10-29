import SwiftUI

/// Motion values taken from docs/prototype.html so the native surface moves like the prototype.
/// The black shape always morphs (size + corner radius); content fades in only after it has started growing.
enum NotchMotion {
    /// `.island.open`: cubic-bezier(.34,1.22,.64,1) .55s, a slight overshoot as the shape expands.
    static let expand = Animation.timingCurve(0.34, 1.22, 0.64, 1, duration: 0.55)
    /// `.island`: cubic-bezier(.32,.72,0,1) .5s, delayed .1s so the content fades out before the shape shrinks.
    static let collapse = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.5).delay(0.1)
    /// Hover grow/shrink of the idle pill.
    static let hover = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.35)

    /// `.island.open .inrow`: opacity .3s @ .16s, transform .45s @ .14s, blur .3s @ .16s.
    static let contentIn = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.45).delay(0.15)
    /// `.inrow` closing: opacity/blur .16s.
    static let contentOut = Animation.easeOut(duration: 0.16)

    /// `.panel.open`: transform .6s cubic-bezier(.32,.72,0,1) @ .08s, opacity .32s @ .1s.
    static let panelIn = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.6).delay(0.08)
    /// `.panel`: opacity .18s, transform .28s.
    static let panelOut = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)

    /// `.row`: transform .4s, staggered .16s + index × .035s after the panel opens.
    static func rowIn(index: Int) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: 0.4).delay(0.16 + Double(index) * 0.035)
    }
}

extension AnyTransition {
    /// Content inside the black shape: blurred, scaled to .94 and transparent while the shape morphs.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ContentMorph(hidden: true), identity: ContentMorph(hidden: false))
                .animation(NotchMotion.contentIn),
            removal: .modifier(active: ContentMorph(hidden: true), identity: ContentMorph(hidden: false))
                .animation(NotchMotion.contentOut)
        )
    }

    /// Results panel: drops 18 pt from under the shape while scaling up from .92.
    static var commandPanel: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PanelDrop(hidden: true), identity: PanelDrop(hidden: false))
                .animation(NotchMotion.panelIn),
            removal: .modifier(active: PanelDrop(hidden: true), identity: PanelDrop(hidden: false))
                .animation(NotchMotion.panelOut)
        )
    }
}

private struct ContentMorph: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.94 : 1)
            .blur(radius: hidden ? 4 : 0)
    }
}

private struct PanelDrop: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.92 : 1, anchor: .top)
            .offset(y: hidden ? -18 : 0)
    }
}
