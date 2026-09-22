import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBarController = MenuBarController()
app.run()
