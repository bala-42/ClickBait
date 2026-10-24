import ClickBaitCore
import SwiftUI

/// The Home card's bean while it's played with (`SpaceToy`): stepped at 60 fps only while it
/// moves, its face for the moment, and how fast it's going for the stars (`SpaceScene`).
@MainActor @Observable
final class SpaceToyPlay {
    static let shared = SpaceToyPlay()

    private(set) var toy = SpaceToy()
    /// Dizzy from a hard bounce, for a moment.
    private(set) var dizzy = false
    private var dizzyTask: Task<Void, Never>?
    /// Bumped on each hard bounce: the bean spins once.
    private(set) var spins = 0
    /// Bumped when it's grabbed, let go or petted: a jelly wobble.
    private(set) var jiggles = 0
    private var grabbedAt = Point(x: 0, y: 0)
    private var ticking: Task<Void, Never>?
    /// How far it may go from the middle of the card (its edges, less the bean's size).
    var limit = Point(x: 120, y: 8)
    var reduceMotion = false

    /// Its face while played with; nil at rest (its own face).
    var face: (mood: Bean.Mood, eyes: Bean.EyePair)? {
        if dizzy { return (.idle, Bean.EyePair(.dot, .dash(tilt: 25))) }
        if toy.held { return (.warm, .both(.pill())) }
        if toy.speed > 380 { return (.warm, .both(.chevron)) }  // wheee
        return nil
    }

    func drag(_ translation: CGSize) {
        if !toy.held {
            toy.held = true
            jiggles += 1
            grabbedAt = toy.offset
            toy.velocity = Point(x: 0, y: 0)
            run()
        }
        // An elastic pull: it follows the pointer, resisting more the further it goes, never
        // past `pull` (the card's sides; a little above and below it).
        func elastic(_ x: Double, _ most: Double) -> Double { x / (1 + abs(x) / most) }
        toy.offset = Point(x: elastic(grabbedAt.x + translation.width, limit.x * 1.6),
                           y: elastic(grabbedAt.y + translation.height, 30))
    }

    func release(_ flick: CGSize) {
        jiggles += 1
        toy.letGo(velocity: reduceMotion ? Point(x: 0, y: 0) : Point(x: flick.width, y: flick.height))
        run()
    }

    /// The pointer came onto it: a little wobble.
    func pet() {
        if !reduceMotion { jiggles += 1 }
    }

    /// Back to rest at once (the card closed or changed).
    func reset() {
        ticking?.cancel()
        ticking = nil
        toy = SpaceToy()
        dizzyTask?.cancel()
        dizzy = false
    }

    private func getDizzy() {
        dizzy = true
        spins += 1
        dizzyTask?.cancel()
        dizzyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.dizzy = false
        }
    }

    private func run() {
        guard ticking == nil else { return }
        ticking = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled, let self, toy.isMoving {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                let dt = min(0.05, (now - last) / .seconds(1))
                last = now
                if reduceMotion, !toy.held {
                    toy = SpaceToy()  // no elastic: back in place at once
                    continue
                }
                let hit = toy.step(dt, limit: limit)
                if hit > 350, !reduceMotion { getDizzy() }
            }
            self?.ticking = nil
        }
    }
}

/// Lets the Home card's bean be grabbed and pulled, springing back on an elastic when let go,
/// soft as jelly (`SpaceToyPlay`); a click still hops it (a drag starts once the pointer moves).
struct SpaceToyHandle: ViewModifier {
    let on: Bool
    let radius: CGFloat
    @State private var play = SpaceToyPlay.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let held = play.toy.held
        // Jelly: stretched along the way it's moving, as hard as it's fast.
        let velocity = play.toy.velocity
        let stretch = reduceMotion ? 0 : min(0.24, hypot(velocity.x, velocity.y) / 2600)
        let heading = Angle(radians: atan2(velocity.y, velocity.x))
        content
            .rotationEffect(-heading)
            .scaleEffect(x: 1 + stretch, y: 1 - stretch * 0.8)
            .rotationEffect(heading)
            .scaleEffect(x: held ? 1.08 : 1, y: held ? 0.92 : 1)
            .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: play.jiggles) { view, scale in
                view.scaleEffect(x: scale.width, y: scale.height, anchor: .center)
            } keyframes: { _ in
                SpringKeyframe(CGSize(width: 1.13, height: 0.87), duration: 0.09)
                SpringKeyframe(CGSize(width: 0.9, height: 1.1), duration: 0.12)
                SpringKeyframe(CGSize(width: 1.05, height: 0.95), duration: 0.12)
                SpringKeyframe(CGSize(width: 0.98, height: 1.02), duration: 0.12)
                SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.25, spring: .bouncy)
            }
            .keyframeAnimator(initialValue: 0.0, trigger: play.spins) { view, angle in
                view.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                CubicKeyframe(360, duration: 0.6)
                CubicKeyframe(360, duration: 0.01)
            }
            .offset(x: on ? play.toy.offset.x : 0, y: on ? play.toy.offset.y : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: held)
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in if on { play.drag(value.translation) } }
                .onEnded { value in if on { play.release(value.velocity) } })
            .onHover { inside in if on, inside { play.pet() } }
            .onAppear { play.reduceMotion = reduceMotion }
            .onChange(of: on) { _, now in if !now { play.reset() } }
            .onChange(of: radius) { _, r in play.limit = Point(x: 161 - r, y: 8) }
            .onAppear { play.limit = Point(x: 161 - radius, y: 8) }
    }
}
