#if DEBUG
import AppKit
import ClickBaitCore
import SwiftUI

/// Side-by-sides of HeyClicky's agent dock (frames from its demo video, 1920×1080 at ~2.1
/// px a point) and ClickBait's dock views at the same size, 2× (Debug builds only):
/// `CLICKBAIT_RENDER_DOCK=<folder with fNNN.NNN.png frames>` writes dock-*.png there and quits.
@MainActor
enum AgentDockRender {
    private static let videoScale = 2.1

    static func runIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["CLICKBAIT_RENDER_DOCK"] else { return }
        let base = URL(fileURLWithPath: folder)
        func frame(_ name: String) -> CGImage? {
            NSImage(contentsOf: base.appending(path: "f\(name).png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        func write(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: base.appending(path: "dock-\(name).png"))
        }

        // The dock (140 s): snip working, answer done, tidy done.
        let dockCrop = CGRect(x: 1640, y: 120, width: 226, height: 330)
        write(pair(frame("140.000"), dockCrop, scene(dockCrop, chromeBlue) { size in
            tiles(in: size, [(.capture, .working), (.processing, .done), (.action, .done)])
        }), "tiles")

        // The spawn (102.5–103.2 s): video time − 102.5 s is the peel's elapsed time.
        let spawnCrop = CGRect(x: 700, y: 100, width: 1220, height: 330)
        let times = ["102.500", "102.567", "102.633", "102.767", "102.900", "103.033", "103.133", "103.200"]
        write(VStack(alignment: .leading, spacing: 6) {
            ForEach(times, id: \.self) { time in
                pair(frame(time), spawnCrop, scene(spawnCrop, chromeBlue) { size in
                    spawnScene(in: size, elapsed: (Double(time) ?? 102.5) - 102.5)
                }, label: "\(time) s")
            }
        }, "spawn")

        // The running card (31 s), hanging under its tile.
        let runningCrop = CGRect(x: 1180, y: 150, width: 690, height: 400)
        write(pair(frame("031.000"), runningCrop, scene(runningCrop, .black) { size in
            let visible = Rect(x: 0, y: 0, width: size.width, height: size.height + 30 / videoScale)
            let tile = AgentDock.tile(0, in: visible)!
            ZStack(alignment: .topLeading) {
                tiles(in: CGSize(width: size.width, height: visible.height), [(.processing, .working)])
                    .offset(y: -30 / videoScale)
                AgentRunningCard(title: "why does this crash on launch",
                                 liveLine: "It's force-unwrapping `config` on line 42, which is nil until the settings load…",
                                 tone: .processing, progressBar: AnyView(StillProgress(tone: .processing)),
                                 blur: false, onStop: {})
                    .offset(x: tile.maxX - AgentDock.cardWidth,
                            y: visible.height - tile.minY + AgentDock.cardGap - 30 / videoScale)
            }
        }), "running")

        // The done card (152 s) under the third tile.
        let doneCrop = CGRect(x: 1180, y: 120, width: 686, height: 900)
        write(pair(frame("152.000"), doneCrop, scene(doneCrop, .black) { size in
            let visible = Rect(x: 0, y: 0, width: size.width, height: size.height)
            let tile = AgentDock.tile(2, in: visible)!
            ZStack(alignment: .topLeading) {
                tiles(in: size, [(.capture, .working), (.action, .working), (.processing, .done)])
                AgentDoneCard(title: "why does this crash on launch",
                              summary: "`config` is nil until Settings load; move the read into `applicationDidFinishLaunching`.",
                              suggestions: ["Show me the fixed code", "Why is it nil at launch?"],
                              tone: .processing, blur: false,
                              onClose: {}, onSuggestion: { _ in }, onFollowUpText: {}, onFollowUpVoice: {},
                              onGoThere: {}, onLater: {})
                    .offset(x: tile.maxX - AgentDock.cardWidth, y: size.height - tile.minY + AgentDock.cardGap)
            }
        }), "done")

        // The result pill at the cursor (44 s).
        let pillCrop = CGRect(x: 840, y: 250, width: 860, height: 180)
        write(pair(frame("044.000"), pillCrop, scene(pillCrop, .black) { _ in
            ZStack(alignment: .topLeading) {
                Image(systemName: "cursorarrow").font(.system(size: 22)).foregroundStyle(.white)
                    .offset(x: 26 / videoScale, y: 14 / videoScale)
                CompanionTriangle(tone: .idle, pulsing: false)
                    .position(x: 105 / videoScale, y: 70 / videoScale)
                AgentResultPill(text: "`config` is nil until Settings load; move the read into applicationDidFinishLaunching.",
                                tone: .processing)
                    .offset(x: 126 / videoScale, y: 70 / videoScale)
            }
        }), "pill")
        exit(0)
    }

    private static let chromeBlue = Color(red: 0.09, green: 0.32, blue: 0.62)

    /// A frame's crop on the left, ClickBait's scene on the right, both in points.
    private static func pair(_ video: CGImage?, _ crop: CGRect, _ ours: some View, label: String? = nil) -> some View {
        let size = CGSize(width: crop.width / videoScale, height: crop.height / videoScale)
        return HStack(alignment: .top, spacing: 6) {
            Group {
                if let cropped = video?.cropping(to: crop) {
                    Image(decorative: cropped, scale: 1).resizable()
                } else {
                    Color.gray
                }
            }
            .frame(width: size.width, height: size.height)
            ours.frame(width: size.width, height: size.height).clipped()
            if let label { Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow) }
        }
        .padding(6)
        .background(Color(white: 0.2))
    }

    private static func scene(_ crop: CGRect, _ backdrop: Color, @ViewBuilder _ content: @escaping (CGSize) -> some View) -> some View {
        let size = CGSize(width: crop.width / videoScale, height: crop.height / videoScale)
        return ZStack(alignment: .topLeading) {
            backdrop
            content(size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Tiles in their slots; the scene's top edge is the menu bar's bottom, its right edge the screen's.
    private static func tiles(in size: CGSize, _ jobs: [(CompanionTone, AgentDock.Status)]) -> some View {
        let visible = Rect(x: 0, y: 0, width: size.width, height: size.height)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                if let tile = AgentDock.tile(index, in: visible) {
                    AgentTile(tone: job.0, look: AgentDock.look(job.1, opened: false, reduceMotion: false),
                              angle: job.1 == .working ? 40 : 0)
                        .position(x: tile.midX, y: size.height - tile.midY)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static func spawnScene(in size: CGSize, elapsed: Double) -> some View {
        let visible = Rect(x: 0, y: 0, width: size.width, height: size.height)
        let cursor = Point(x: 60 / videoScale, y: size.height - 230 / videoScale)
        let slot = AgentDock.tile(0, in: visible)!
        let frame = AgentDock.spawn(at: elapsed, from: cursor, to: Point(x: slot.midX, y: slot.midY))
        let shift = AgentDock.slide(at: elapsed)
        return ZStack(alignment: .topLeading) {
            Image(systemName: "cursorarrow").font(.system(size: 22)).foregroundStyle(.white)
                .offset(x: cursor.x - 55 / videoScale, y: size.height - cursor.y - 25 / videoScale)
            // The older tiles slide down a slot as the new one arrives.
            ForEach(0..<2, id: \.self) { index in
                if let from = AgentDock.tile(index, in: visible), let to = AgentDock.tile(index + 1, in: visible) {
                    AgentTile(tone: index == 0 ? .processing : .action,
                              look: AgentDock.look(.done, opened: false, reduceMotion: false))
                        .position(x: from.midX, y: size.height - (from.midY + (to.midY - from.midY) * shift))
                }
            }
            AgentTile(tone: .capture, look: AgentDock.look(.working, opened: false, reduceMotion: false))
                .opacity(frame.tileOpacity)
                .position(x: slot.midX, y: size.height - slot.midY)
            if !frame.docked {
                CompanionTriangle(tone: .capture, pulsing: false, angle: frame.angle,
                                  glowRadius: CompanionTriangle.glowRadius * (1 + frame.swell * 2))
                    .scaleEffect(frame.scale)
                    .position(x: frame.center.x, y: size.height - frame.center.y)
            }
            if frame.freshScale > 0 {
                CompanionTriangle(tone: .idle, pulsing: false)
                    .scaleEffect(frame.freshScale)
                    .position(x: cursor.x, y: size.height - cursor.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The answer's sweeping bar, still (a render can't animate).
private struct StillProgress: View {
    let tone: CompanionTone
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tone.color).frame(width: geometry.size.width / 3).offset(x: geometry.size.width / 3)
            }
        }
        .frame(height: 3)
    }
}
#endif
