import AppKit

// No storyboard, no nib — the whole app is assembled in code.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
