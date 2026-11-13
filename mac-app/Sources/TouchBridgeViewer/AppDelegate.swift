import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ViewerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ViewerWindowController()
        windowController = controller
        controller.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdown()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.releaseTouchIfNeeded()
    }
}
