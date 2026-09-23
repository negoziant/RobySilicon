import AppKit
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowRect = NSRect(x: 0, y: 0, width: 640, height: 480)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Новый Робинзон"
        window.center()

        let skView = TrackingSKView(frame: windowRect)
        skView.showsFPS = true
        skView.showsNodeCount = true
        window.contentView = skView
        window.acceptsMouseMovedEvents = true

        let scene = GameScene(size: CGSize(width: 640, height: 480))
        scene.scaleMode = .aspectFit
        skView.presentScene(scene)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
