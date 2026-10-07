import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBarController = MenuBarController()
menuBarController.launch()
app.run()
