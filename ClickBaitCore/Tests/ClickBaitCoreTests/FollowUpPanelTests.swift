import Testing
@testable import ClickBaitCore

struct FollowUpPanelTests {
    @Test func textOpensForTyping() {
        var panel = FollowUpPanel()
        #expect(panel.tap(.text) == .none)
        #expect(panel.isOpen)
        #expect(panel.voice == .ready)
    }

    @Test func voiceOpensAndRecords() {
        var panel = FollowUpPanel()
        #expect(panel.tap(.voice) == .startRecording)
        #expect(panel.isOpen)
        panel.recordingStarted()
        #expect(panel.voice == .recording)
    }

    @Test func bothInputsStayAvailable() {
        var panel = FollowUpPanel()
        _ = panel.tap(.text)
        panel.draft = "where is"
        #expect(panel.tap(.voice) == .startRecording)  // voice from the open chat
        panel.recordingStarted()
        #expect(panel.tap(.voice) == .stopRecording)
        panel.transcribed("the cerebellum")
        #expect(panel.draft == "where is the cerebellum")  // added to what was typed
        #expect(panel.submit() == .send("where is the cerebellum"))
        #expect(panel.isOpen)
        #expect(panel.tap(.voice) == .startRecording)  // and again after a send
    }

    @Test func voiceIsPressToStartPressToStop() {
        var panel = FollowUpPanel()
        _ = panel.tap(.voice)
        panel.recordingStarted()
        #expect(panel.tap(.voice) == .stopRecording)
        #expect(panel.voice == .transcribing)
        #expect(panel.tap(.voice) == .none)  // waits for the words
    }

    @Test func theTranscriptIsReviewedNotSent() {
        var panel = FollowUpPanel()
        _ = panel.tap(.voice)
        panel.recordingStarted()
        _ = panel.tap(.voice)
        panel.transcribed(" show me the parts ")
        #expect(panel.voice == .ready)
        #expect(panel.draft == "show me the parts")
        panel.draft = "show me the moons"  // edited
        #expect(panel.submit() == .send("show me the moons"))
    }

    @Test func pressingVoiceWhileTheMicStartsGivesUp() {
        var panel = FollowUpPanel()
        _ = panel.tap(.voice)
        #expect(panel.tap(.voice) == .cancelRecording)
        #expect(panel.voice == .ready)
    }

    /// Rapid presses with the microphone never confirming: every start is matched by a
    /// cancel or stop, so the microphone ends off.
    @Test func rapidTogglingEndsSettled() {
        var panel = FollowUpPanel()
        var open = 0
        for mode in [FollowUpPanel.Mode.voice, .voice, .text, .voice, .text, .voice, .voice, .voice, .text, .voice] {
            switch panel.tap(mode) {
            case .startRecording: open += 1
            case .cancelRecording, .stopRecording: open -= 1
            default: break
            }
            #expect(open >= 0 && open <= 1)
        }
        if panel.collapse() == .cancelRecording { open -= 1 }
        #expect(open == 0)
        #expect(!panel.voice.isBusy)
    }

    @Test func noSendWhileRecordingOrAnswering() {
        var panel = FollowUpPanel()
        _ = panel.tap(.text)
        panel.draft = "and then?"
        #expect(panel.submit(answering: true) == .none)
        #expect(panel.hint == FollowUpPanel.busyHint)
        _ = panel.tap(.voice)
        #expect(!panel.canSend)
        #expect(panel.submit() == .none)
        #expect(panel.hint == FollowUpPanel.recordingHint)
        #expect(panel.draft == "and then?")
    }

    @Test func emptyIsNotSent() {
        var panel = FollowUpPanel()
        _ = panel.tap(.text)
        panel.draft = "   "
        #expect(!panel.canSend)
        #expect(panel.submit() == .none)
        #expect(panel.hint == FollowUpPanel.emptyHint)
    }

    @Test func foldingKeepsTheDraftDropsTheRecording() {
        var panel = FollowUpPanel()
        _ = panel.tap(.text)
        panel.draft = "half typed"
        #expect(panel.pause() == .none)
        #expect(panel.isOpen)
        _ = panel.tap(.voice)
        panel.recordingStarted()
        #expect(panel.pause() == .cancelRecording)
        #expect(panel.isOpen)
        #expect(panel.voice == .ready)
        #expect(panel.collapse() == .none)
        #expect(!panel.isOpen)
        #expect(panel.draft == "half typed")
    }

    @Test func silenceAndFailuresSaySo() {
        var panel = FollowUpPanel()
        _ = panel.tap(.voice)
        panel.recordingStarted()
        _ = panel.tap(.voice)
        panel.transcribed("")
        #expect(panel.voice == .failed(FollowUpPanel.silentHint))
        #expect(panel.tap(.voice) == .startRecording)  // try again
        panel.recordingFailed("Microphone access is off.")
        #expect(panel.voice == .failed("Microphone access is off."))
    }

    @Test func aRefusedSendKeepsTheWords() {
        var panel = FollowUpPanel()
        panel.sendFailed("why?", reason: "Screen Recording is off.")
        #expect(panel.isOpen)
        #expect(panel.draft == "why?")
        #expect(panel.hint == "Screen Recording is off.")
    }

    @Test func aLateTranscriptAfterFoldingIsIgnored() {
        var panel = FollowUpPanel()
        _ = panel.tap(.voice)
        panel.recordingStarted()
        _ = panel.tap(.voice)
        _ = panel.collapse()
        panel.transcribed("too late")
        #expect(panel.draft.isEmpty)
    }
}

struct BackgroundJobReopenTests {
    @Test func aDoneJobWorksAgainOnTheNewQuestion() {
        var job = BackgroundJob(question: "what is this", kind: .snip, homeBundleID: nil, homePID: nil, conversation: Conversation())
        job.reopen(asking: "too early")
        #expect(job.question == "what is this")  // only a done job reopens
        job.complete(answer: "A brain.", conversation: Conversation())
        job.reopen(asking: "which part is the cerebellum?")
        #expect(job.isWorking)
        #expect(job.question == "which part is the cerebellum?")
        #expect(job.answer.isEmpty)
    }
}
