import Cocoa
import ApplicationServices.HIServices.AXUIElement
import ApplicationServices.HIServices.AXNotificationConstants

let axObserverCallback: AXObserverCallback = { _, element, notificationName, _ in
    let type = notificationName as String
    Logger.debug(type)
    retryAxCallUntilTimeout { try handleEvent(type, element) }
}

fileprivate func handleEvent(_ type: String, _ element: AXUIElement) throws {
    // events are handled concurrently, thus we check that the app is still running
    if let pid = try element.pid(),
       try pid != ProcessInfo.processInfo.processIdentifier || (element.subrole() != kAXUnknownSubrole) {
        Logger.info(type, pid, try element.title() ?? "nil")
        switch type {
            case kAXApplicationActivatedNotification: try applicationActivated(element, pid)
            case kAXApplicationHiddenNotification,
                 kAXApplicationShownNotification: try applicationHiddenOrShown(pid, type)
            case kAXWindowCreatedNotification: try windowCreated(element, pid)
            case kAXMainWindowChangedNotification,
                 kAXFocusedWindowChangedNotification: try focusedWindowChanged(element, pid)
            case kAXUIElementDestroyedNotification: try windowDestroyed(element, pid)
            case kAXWindowMiniaturizedNotification,
                 kAXWindowDeminiaturizedNotification: try windowMiniaturizedOrDeminiaturized(element, type)
            case kAXTitleChangedNotification: try windowTitleChanged(element)
            case kAXWindowResizedNotification,
                 kAXWindowMovedNotification: try windowResizedOrMoved(element)
            default: return
        }
    }
}

fileprivate func applicationActivated(_ element: AXUIElement, _ pid: pid_t) throws {
    let appFocusedWindow = try element.focusedWindow()
    let wid = try appFocusedWindow?.cgWindowId()
    DispatchQueue.main.async {
        if let app = Applications.find(pid) {
            if app.hasBeenActiveOnce != true {
                app.hasBeenActiveOnce = true
            }
            let window = (appFocusedWindow != nil && wid != nil) ? Windows.updateLastFocus(appFocusedWindow!, wid!)?.first : nil
            app.focusedWindow = window
            App.app.checkIfShortcutsShouldBeDisabled(window, app.runningApplication)
            App.app.refreshOpenUi(window != nil ? [window!] : [], .refreshUiAfterExternalEvent)
        }
    }
}

fileprivate func applicationHiddenOrShown(_ pid: pid_t, _ type: String) throws {
    DispatchQueue.main.async {
        if let app = Applications.find(pid) {
            app.isHidden = type == kAXApplicationHiddenNotification
            let windows = Windows.list.filter {
                // for AXUIElement of apps, CFEqual or == don't work; looks like a Cocoa bug
                return $0.application.pid == pid
            }
            // if we process the "shown" event too fast, the window won't be listed by CGSCopyWindowsWithOptionsAndTags
            // it will thus be detected as isTabbed. We add a delay to work around this scenario
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                App.app.refreshOpenUi(windows, .refreshUiAfterExternalEvent)
            }
        }
    }
}

fileprivate func windowCreated(_ element: AXUIElement, _ pid: pid_t) throws {
    if let wid = try element.cgWindowId() {
        let axTitle = try element.title()
        let subrole = try element.subrole()
        let role = try element.role()
        let isFullscreen = try element.isFullscreen()
        let isMinimized = try element.isMinimized()
        let level = try wid.level()
        let position = try element.position()
        let size = try element.size()
        DispatchQueue.main.async {
            if let app = Applications.find(pid), NSRunningApplication(processIdentifier: pid) != nil {
                if (!Windows.list.contains { $0.isEqualRobust(element, wid) }) &&
                       AXUIElement.isActualWindow(app, wid, level, axTitle, subrole, role, size) {
                    let window = Window(element, app, wid, axTitle, isFullscreen, isMinimized, position, size)
                    Windows.appendAndUpdateFocus(window)
                    Windows.cycleFocusedWindowIndex(1)
                    App.app.refreshOpenUi([window], .refreshUiAfterExternalEvent)
                }
            }
        }
    }
}

fileprivate func focusedWindowChanged(_ element: AXUIElement, _ pid: pid_t) throws {
    if let wid = try element.cgWindowId(),
       let runningApp = NSRunningApplication(processIdentifier: pid) {
        // photoshop will focus a window *after* you focus another app
        // we check that a focused window happens within an active app
        if runningApp.isActive {
            let axTitle = try element.title()
            let subrole = try element.subrole()
            let role = try element.role()
            let isFullscreen = try element.isFullscreen()
            let isMinimized = try element.isMinimized()
            let level = try wid.level()
            let position = try element.position()
            let size = try element.size()
            DispatchQueue.main.async {
                guard let app = Applications.find(pid) else { return }
                // if the window is shown by alt-tab, we mark her as focused for this app
                // this avoids issues with dialogs, quicklook, etc (see scenarios from #1044 and #2003)
                if let w = (Windows.list.first { $0.isEqualRobust(element, wid) }) {
                    app.focusedWindow = w
                }
                if let windows = Windows.updateLastFocus(element, wid) {
                    App.app.refreshOpenUi(windows, .refreshUiAfterExternalEvent)
                } else if AXUIElement.isActualWindow(app, wid, level, axTitle, subrole, role, size) {
                    let window = Window(element, app, wid, axTitle, isFullscreen, isMinimized, position, size)
                    Windows.appendAndUpdateFocus(window)
                    App.app.refreshOpenUi([window], .refreshUiAfterExternalEvent)
                }
            }
        }
        DispatchQueue.main.async {
            if let app = Applications.find(pid) {
                // work-around for apps started "hidden" like in Login Items with the "Hide" checkbox, or with `open -j`
                // these apps report isHidden=false, don't generate windowCreated events initially, and have a delay before their windows are created
                // our only recourse is to manually check their windows once they emit
                if (!app.hasBeenActiveOnce) {
                    app.manuallyUpdateWindows()
                }
            }
        }
    } else {
        DispatchQueue.main.async {
            Applications.find(pid)?.focusedWindow = nil
        }
    }
}

fileprivate func windowDestroyed(_ element: AXUIElement, _ pid: pid_t) throws {
    let wid = try element.cgWindowId()
    DispatchQueue.main.async {
        if let index = (Windows.list.firstIndex { $0.isEqualRobust(element, wid) }) {
            let window = Windows.list[index]
            Windows.removeAndUpdateFocus(window)
            if window.application.addWindowlessWindowIfNeeded() != nil {
                Applications.find(pid)?.focusedWindow = nil
            }
            if Windows.list.count > 0 {
                Windows.moveFocusedWindowIndexAfterWindowDestroyedInBackground(index)
                App.app.refreshOpenUi([], .refreshUiAfterExternalEvent)
            } else {
                App.app.hideUi()
            }
        }
    }
}

fileprivate func windowMiniaturizedOrDeminiaturized(_ element: AXUIElement, _ type: String) throws {
    if let wid = try element.cgWindowId() {
        DispatchQueue.main.async {
            if let window = (Windows.list.first { $0.isEqualRobust(element, wid) }) {
                window.isMinimized = type == kAXWindowMiniaturizedNotification
                App.app.refreshOpenUi([window], .refreshUiAfterExternalEvent)
            }
        }
    }
}

fileprivate func windowTitleChanged(_ element: AXUIElement) throws {
    if let wid = try element.cgWindowId() {
        let newTitle = try element.title()
        DispatchQueue.main.async {
            if let window = (Windows.list.first { $0.isEqualRobust(element, wid) }), newTitle != window.title {
                window.title = window.bestEffortTitle(newTitle)
                App.app.refreshOpenUi([window], .refreshUiAfterExternalEvent)
            }
        }
    }
}

fileprivate func windowResizedOrMoved(_ element: AXUIElement) throws {
    // TODO: only trigger this at the end of the resize, not on every tick
    // currently resizing a window will lag AltTab as it triggers too much UI work
    if let wid = try element.cgWindowId() {
        let isFullscreen = try element.isFullscreen()
        let size = try element.size()
        let position = try element.position()
        DispatchQueue.main.async {
            if let window = (Windows.list.first { $0.isEqualRobust(element, wid) }) {
                window.size = size
                window.position = position
                if window.isFullscreen != isFullscreen {
                    window.isFullscreen = isFullscreen
                    App.app.checkIfShortcutsShouldBeDisabled(window, nil)
                }
                App.app.refreshOpenUi([window], .refreshUiAfterExternalEvent)
            }
        }
    }
}
