import Foundation
import Testing
@testable import Perch

struct CallSourceTests {
    @Test func zoomMenuTitlesGiveState() {
        let titles = ["Mute audio", "Stop video", "Start share", "Leave"]
        #expect(CallLogic.zoomState(menuTitles: titles) == CallState(isMuted: false, isCameraOn: true))
        #expect(CallLogic.zoomState(menuTitles: ["Unmute Audio", "Start Video"]) == CallState(isMuted: true, isCameraOn: false))
    }

    @Test func zoomMenuWithoutAudioItemIsNoCall() {
        #expect(CallLogic.zoomState(menuTitles: ["Join meeting", "Schedule"]) == nil)
        #expect(CallLogic.zoomState(menuTitles: []) == nil)
    }

    @Test func zoomAudioOnlyCallHasNoCamera() {
        #expect(CallLogic.zoomState(menuTitles: ["Mute audio"]) == CallState(isMuted: false, isCameraOn: nil))
    }

    @Test func meetLabelsGiveState() {
        let labels = ["Turn on microphone (⌘ + d)", "Turn off camera (⌘ + e)", "Leave call", "Chat with everyone"]
        #expect(CallLogic.meetState(ariaLabels: labels) == CallState(isMuted: true, isCameraOn: true))
        #expect(CallLogic.meetState(ariaLabels: ["Turn off microphone", "Turn on camera", "Leave call"])
            == CallState(isMuted: false, isCameraOn: false))
    }

    @Test func meetPageWithoutLeaveButtonIsNoCall() {
        #expect(CallLogic.meetState(ariaLabels: ["Turn off microphone", "Turn off camera"]) == nil)
    }

    @Test func meetingURLsMatch() {
        #expect(CallLogic.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallLogic.isMeetingURL("https://meet.google.com/abc-defg-hij?authuser=1"))
        #expect(CallLogic.isMeetingURL("https://meet.google.com/lookup/abcd1234"))
        #expect(!CallLogic.isMeetingURL("https://meet.google.com/"))
        #expect(!CallLogic.isMeetingURL("https://meet.google.com/landing"))
        #expect(!CallLogic.isMeetingURL("https://example.com/abc-defg-hij"))
    }

    @Test func meetReportPicksTheTabInACall() {
        let report = """
        https://meet.google.com/\tnot json
        https://meet.google.com/abc-defg-hij\t["Turn off microphone","Leave call"]
        """
        let tab = CallLogic.meetTab(report: report)
        #expect(tab?.url == "https://meet.google.com/abc-defg-hij")
        #expect(tab?.state == CallState(isMuted: false, isCameraOn: nil))
        #expect(CallLogic.meetTab(report: "") == nil)
    }

    @Test func leaveButtonNeverMatchesEndForAll() {
        #expect(CallLogic.isLeaveButton("Leave meeting"))
        #expect(!CallLogic.isLeaveButton("End meeting for all"))
        #expect(!CallLogic.isLeaveButton("Cancel"))
    }

    @Test func browserErrorsAreClassified() {
        #expect(CallLogic.isJavaScriptDisabled(stderr: "execution error: Google Chrome got an error: Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events. (12)"))
        #expect(CallLogic.isAutomationDenied(stderr: "execution error: Not authorized to send Apple events to Google Chrome. (-1743)"))
        #expect(!CallLogic.isAutomationDenied(stderr: "syntax error"))
    }

    @MainActor @Test func actionsReflectState() {
        let muted = CallLogic.actions(for: CallState(isMuted: true, isCameraOn: false))
        #expect(muted.map(\.id) == ["mute", "camera", "leave"])
        #expect(muted[0].isOn && muted[0].title == "Unmute")
        #expect(muted[1].isOn && muted[1].title == "Camera on")
        #expect(muted[2].isDestructive)
        #expect(CallLogic.actions(for: CallState(isMuted: false, isCameraOn: nil)).map(\.id) == ["mute", "leave"])
    }
}
