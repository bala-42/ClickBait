import Foundation

/// What was on screen when the user asked, beyond the pixels.
public struct ScreenContext: Equatable, Sendable {
    public var appName: String?
    public var windowTitle: String?
    /// e.g. `AXButton "Share"` — filled in once the accessibility inspector exists.
    public var focusedElement: String?
    /// The front window's frame (AppKit's accessibility frame, top-left origin): with the
    /// title, how "go there!" finds the window a background job came from. Not sent to the model.
    public var windowFrame: Rect?

    public init(appName: String? = nil, windowTitle: String? = nil, focusedElement: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
    }
}

/// Everything a provider needs for one ask.
/// How a model writes positions in an image. Qwen 2.5-VL uses the image's pixels;
/// Qwen 3 / 3.5 use 0–1000 of its width and height whatever the prompt says.
public enum CoordinateScale: Sendable, Equatable {
    case pixels
    case thousandths
}

public struct AskRequest: Sendable {
    public var question: String
    /// Set by the provider for the model that answers: prompts describe positions (and
    /// the element list) in this scale, and replies are converted back to pixels.
    public var coordinateScale: CoordinateScale = .pixels
    /// JPEG of the downscaled screenshot (long edge ≤ 1280 px).
    public var screenshotJPEG: Data
    /// Pixel size of `screenshotJPEG`; pointer coordinates come back in this space.
    public var screenshotWidth: Int
    public var screenshotHeight: Int
    public var context: ScreenContext
    /// Text the user highlighted and asked to have explained (⌥⌘). Nil for voice asks.
    public var selectedText: String?
    /// Earlier turns of this bubble's chat (empty for the first message).
    public var history: [ChatTurn]
    /// Set when the user circled or boxed part of the screen (hold ⌥⌘): the screenshot
    /// is then a close-up of that part with the shape drawn on it in red.
    public var snip: SnipKind?
    /// Clickable things Accessibility found on screen, numbered for the model to pick
    /// from. Empty when the app exposes nothing (or for explanations and snips).
    public var elements: [PromptElement]
    /// Set for a second, zoomed-in look: find this one thing in a close-up screenshot.
    public var locate: String?
    /// For snips: a small picture of the whole screen sent after the close-up, so the
    /// model knows what app and what surroundings the marked thing is in.
    public var contextJPEG: Data?
    /// For snips whose explanation came back without parts: list them (`Prompt.partsSystem`).
    /// `question` then holds the explanation, as a hint to what the image shows.
    public var listParts = false
    /// Name the numbered marks on a snip's close-up (`Prompt.marksSystem`): which mark is
    /// each of these names. `question` then holds the explanation.
    public var markNames: [String] = []
    /// How many marks are drawn, numbered from 1.
    public var markCount = 0
    /// The marks are grid cells (each number sits in the top-left of its cell).
    public var marksAreCells = false
    /// Background on what the snip shows (Wikipedia lookups on), for telling the named
    /// things apart when naming the marks.
    public var reference: WikiReference?
    /// A first snip explanation with Wikipedia lookups on: the reply opens with "subject"
    /// (`Prompt.subjectLine`; Ollama's structured output puts it first), looked up while
    /// the rest streams.
    public var askSubject = false
    /// Internet Mode's first step (`Prompt.lookupSystem`, text only): write the search words.
    public var lookupQuery = false
    /// A finished background answer's card (`Prompt.nextSystem`, text only): up to two short
    /// follow-up questions to offer under "suggested next:". Holds the answer.
    public var suggestNextAfter: String?
    /// For that step: words read on this Mac near the pointer (never sent anywhere but Ollama),
    /// and the chat's earlier question for a follow-up like "look it up".
    public var screenWords: String?
    public var earlierQuestion: String?
    /// What an Internet Mode lookup found, for the answer ("From the web").
    public var web: [WebPassage] = []
    /// Plan a tutorial for `question` (`Prompt.tutorialSystem`).
    public var planTutorial = false
    /// The app's menus ("History ▸ Clear History…"), so tutorial plans use real items.
    public var menuOutline: [String] = []
    /// The user's web browser ("Safari"), for website steps in a tutorial plan.
    public var browser: String?
    /// Sort a how-to-sounding request: a walkthrough, or a question to answer?
    public var sortRequest = false
    /// "Where's X?": pick X from the element list, text only (no screenshot).
    public var pickElement = false
    /// Check progress on a running tutorial (`Prompt.progressSystem`).
    public var tutorialCheck: (plan: TutorialPlan, expected: Int)?
    /// Text only: which ClickBait action (if any) is this order? See `Prompt.orderSystem`.
    public var interpretOrder = false
    /// Sort it into one intent (`IntentRouter`, shadow mode): text only, a tiny JSON reply.
    public var routeIntent = false
    /// What the user asked ClickBait to remember, as the prompt block (`Memory.block`), or nil.
    public var remembered: String?
    /// When it was asked: today's date for the prompt (`DateFacts`).
    public var now = Date()

    public init(
        question: String,
        screenshotJPEG: Data,
        screenshotWidth: Int,
        screenshotHeight: Int,
        context: ScreenContext,
        selectedText: String? = nil,
        history: [ChatTurn] = [],
        snip: SnipKind? = nil,
        elements: [PromptElement] = [],
        locate: String? = nil
    ) {
        self.question = question
        self.screenshotJPEG = screenshotJPEG
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.context = context
        self.selectedText = selectedText
        self.history = history
        self.snip = snip
        self.elements = elements
        self.locate = locate
    }
}
