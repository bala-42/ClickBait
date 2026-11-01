import Foundation
import Testing
@testable import ClickBait

/// The prompter following a voice: smooth, never backwards, and it keeps up.
struct StudioMotionTests {
    @Test func readingGlidesBetweenLateMatches() {
        // 3 words a second, a match each second reporting where you were a second before;
        // quiet from 6 s to 8 s. 120 frames a second, 30 points a word.
        let fps = 120.0, dt = 1 / fps
        var reading = 0.0, speed = 0.0, offset = 0.0, velocity = 0.0, matched = 0.0
        var lastOffset = 0.0, lastVelocity = 0.0, worstJerk = 0.0, backwards = 0.0
        for frame in 0..<Int(12 * fps) {
            let t = Double(frame) * dt
            let speaking = t < 6 || t > 8
            let said = t < 6 ? t * 3 : t < 8 ? 18 : 18 + (t - 8) * 3
            if frame % Int(fps) == 0 { matched = max(matched, (t < 7 ? max(0, t - 1) * 3 : t < 9 ? 18 : 18 + (t - 9) * 3)) }
            (reading, speed) = StudioMotion.read(at: reading, speed: speed, matched: matched, pace: 3, speaking: speaking, dt: dt)
            (offset, velocity) = StudioMotion.spring(offset, velocity: velocity, to: reading * 30, dt: dt)
            if frame > 0 {
                backwards = max(backwards, lastOffset - offset)
                worstJerk = max(worstJerk, abs(velocity - lastVelocity))  // points/s change in one frame
            }
            (lastOffset, lastVelocity) = (offset, velocity)
            if frame % Int(fps) == 0 { print("MOTION t \(Int(t)) said \(String(format: "%.1f", said)) read \(String(format: "%.1f", reading))") }
            if t > 11.9 { #expect(abs(reading - said) < 4, "keeps up: read \(reading) vs said \(said)") }
        }
        print("MOTION worst velocity change per frame \(String(format: "%.2f", worstJerk)) pt/s, backwards \(String(format: "%.3f", backwards)) pt")
        #expect(backwards < 0.5)
        #expect(worstJerk < 4)  // 120 fps: under ~4 pt/s per frame reads as a glide
    }

    @Test func aSkipJumpsTheSpringNotTheText() {
        var (x, v) = (0.0, 0.0)
        for _ in 0..<72 { (x, v) = StudioMotion.spring(x, velocity: v, to: 600, dt: 1 / 60) }
        #expect(x > 590 && x <= 600.5)  // there in 1.2 s, no overshoot
    }
}
