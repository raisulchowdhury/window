import Foundation

enum PanelFadeTests {
    static func run() -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { print("FAIL: \(message)"); exit(1) }
            checks += 1
        }
        var fade = PanelFade()
        expect(fade.phase == .closed && fade.close() == nil, "closed panel ignores a redundant close")
        let firstOpen = fade.open()
        expect(fade.phase == .opening, "open starts a fade")
        let firstClose = fade.close()!
        expect(!fade.complete(firstOpen) && fade.phase == .closing, "close rejects interrupted open completion")
        expect(fade.close() == nil, "repeated outside clicks do not restart the close")
        let reversedOpen = fade.open()
        expect(!fade.complete(firstClose) && fade.phase == .opening, "reopen prevents stale orderOut")
        expect(fade.complete(reversedOpen) && fade.phase == .open, "reversed open completes")
        expect(!fade.complete(reversedOpen), "completion fires only once")
        let finalClose = fade.close()!
        expect(fade.complete(finalClose) && fade.phase == .closed, "completed close hides and resets")
        return checks
    }
}
