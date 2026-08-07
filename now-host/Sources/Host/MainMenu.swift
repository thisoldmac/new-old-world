import AppKit

/// The application's menu bar.
///
/// NOW had none. That is not only a missing affordance: **key equivalents are
/// dispatched through `NSApp.mainMenu`**, so with no main menu the app had no
/// ⌘Q, no ⌘W, and no ⌘C/⌘V in the console's text field — the status item's
/// own ⌘Q only fires while that menu is open, which is why quitting appeared
/// to be broken while a Quit item plainly existed.
///
/// **Where the line runs between this menu and the status item.** NOW is a
/// menu-bar application with a window: the status item must work when there
/// is no window at all, so it carries the smallest set that makes sense with
/// nothing on screen — the wire's state, Open, Screenshot Guest, Quit. This
/// menu carries everything, and duplicates exactly those three verbs. Every
/// other command lives in one place only; a status item that mirrored the
/// whole menu would be two surfaces to keep honest instead of one.
///
/// Built as a pure function over a registry and a set of selectors so a test
/// can assemble and inspect it without conjuring a real menu bar. Nothing
/// here reaches into app state: titles that depend on the wire are updated by
/// the delegate when the menu opens (`menuNeedsUpdate`), because a menu that
/// caches the connection is a menu that lies about it.
@MainActor
enum MainMenu {

    /// Tags for the items whose titles or enablement depend on live state.
    /// Read back by the delegate rather than by index — inserting a menu item
    /// must not silently retarget an updater.
    enum Tag: Int {
        case listenToggle = 2001
        /// The "Drive" submenu holder, whose contents are the connected
        /// machines and so cannot be built here — the menu is a pure
        /// function of the registry, and the roster is not in it.
        case guestList = 2002
        case moduleFirst = 2100      // + the module's index in the registry
    }

    /// Selectors the delegate must implement. Passed in rather than hardcoded
    /// so the menu is testable against a stub and so an unimplemented action
    /// is a compile error at the call site, not a silent no-op at runtime.
    struct Actions {
        var about: Selector
        var openWindow: Selector
        var showSettings: Selector
        var screenshotGuest: Selector
        var askGuestForHelp: Selector
        var toggleListening: Selector
        var showMirror: Selector
        var revealSharedFolder: Selector
        var revealLogFolder: Selector
        var quit: Selector
    }

    static func make(appName: String,
                     registry: ModuleRegistry,
                     target: AnyObject,
                     actions: Actions) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem(appName: appName, target: target,
                                 actions: actions))
        main.addItem(fileMenuItem(target: target, actions: actions))
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem(registry: registry, target: target))
        main.addItem(guestMenuItem(appName: appName, target: target,
                                   actions: actions))
        main.addItem(windowMenuItem(appName: appName, target: target,
                                    actions: actions))
        main.addItem(helpMenuItem(appName: appName, target: target,
                                  actions: actions))
        return main
    }

    /// The submenu of the Window item, which NSApplication needs by identity
    /// to keep its window list current.
    static func windowsMenu(in main: NSMenu) -> NSMenu? {
        main.items.first { $0.title == "Window" }?.submenu
    }

    // MARK: - Menus

    private static func item(_ title: String, _ action: Selector?,
                             _ key: String, target: AnyObject? = nil,
                             modifiers: NSEvent.ModifierFlags? = nil,
                             tag: Tag? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action,
                                  keyEquivalent: key)
        // A nil target means "walk the responder chain", which is what the
        // Edit menu's editing commands need to reach the focused text field.
        menuItem.target = target
        if let modifiers {
            menuItem.keyEquivalentModifierMask = modifiers
        }
        if let tag {
            menuItem.tag = tag.rawValue
        }
        return menuItem
    }

    private static func submenu(_ title: String,
                                _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items {
            menu.addItem(item)
        }
        holder.submenu = menu
        return holder
    }

    private static func appMenuItem(appName: String, target: AnyObject,
                                    actions: Actions) -> NSMenuItem {
        // The first menu's own title is ignored — macOS draws the process
        // name — but it is set anyway so a test can find it by name.
        submenu(appName, [
            item("About \(appName)", actions.about, "", target: target),
            .separator(),
            item("Settings…", actions.showSettings, ",", target: target),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                 "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)),
                 ""),
            .separator(),
            item("Quit \(appName)", actions.quit, "q", target: target),
        ])
    }

    /// Files here are this Mac's: the folder NOW shares with the other one.
    /// The guest's files are browsed in the Files module and driven from the
    /// Guest menu — they are not this application's documents.
    private static func fileMenuItem(target: AnyObject,
                                     actions: Actions) -> NSMenuItem {
        submenu("File", [
            item("Reveal Shared Folder in Finder", actions.revealSharedFolder,
                 "r", target: target, modifiers: [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
    }

    /// Standard, and load-bearing: without these items the console's text
    /// field has no ⌘C, ⌘V or ⌘A, because those are responder-chain actions
    /// the main menu dispatches. Their targets stay nil for that reason.
    private static func editMenuItem() -> NSMenuItem {
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z",
                 modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
    }

    /// The module registry, as a menu. Derived, not duplicated: a module
    /// added to `ModuleRegistry.standard` appears here with the next number
    /// and needs no edit — which is the point of having a registry.
    private static func viewMenuItem(registry: ModuleRegistry,
                                     target: AnyObject) -> NSMenuItem {
        var items: [NSMenuItem] = []
        var number = 1

        func add(_ modules: [ModuleDescriptor]) {
            for module in modules {
                let key = number <= 9 ? "\(number)" : ""
                let menuItem = NSMenuItem(
                    title: module.title,
                    action: #selector(AppDelegate.showModule(_:)),
                    keyEquivalent: key)
                menuItem.target = target
                // The index into registry.modules, so the action can select
                // the module without parsing its own title back.
                menuItem.tag = Tag.moduleFirst.rawValue
                    + (registry.modules.firstIndex { $0.id == module.id } ?? 0)
                items.append(menuItem)
                number += 1
            }
        }
        add(registry.listModules)
        if !registry.footerModules.isEmpty {
            items.append(.separator())
            add(registry.footerModules)
        }
        return submenu("View", items)
    }

    /// Verbs that act on the other Mac. A domain menu rather than stuffing
    /// them into File: nothing here touches a document on this side, and the
    /// two that are destructive-ish (listening, quitting an application) read
    /// wrongly under any of the standard menus.
    private static func guestMenuItem(appName: String, target: AnyObject,
                                      actions: Actions) -> NSMenuItem {
        // "Drive" is the first item because everything under it acts on
        // whichever machine is chosen there: a menu that offers to
        // screenshot "the guest" while several are connected has to say
        // which one it means, in the same menu, above the verb.
        let drive = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        drive.tag = Tag.guestList.rawValue
        drive.submenu = NSMenu(title: "Drive")
        return submenu("Guest", [
            drive,
            .separator(),
            item("Screenshot Guest", actions.screenshotGuest, "s",
                 target: target, modifiers: [.command, .shift]),
            .separator(),
            // The title flips to "Stop Listening" when a listener is up; the
            // delegate rewrites it as the menu opens.
            item("Start Listening", actions.toggleListening, "l",
                 target: target, modifiers: [.command, .shift],
                 tag: .listenToggle),
        ])
    }

    /// Fills the "Drive" submenu with the machines currently connected.
    ///
    /// Rebuilt as the menu opens rather than tracked, for the reason the
    /// listen toggle is: a menu that caches the roster is a menu that
    /// offers to drive a Mac that hung up ten minutes ago.
    ///
    /// The item CARRIES its session id in `representedObject`, and no
    /// longer relies on its title round-tripping to an identity. It used
    /// to: the key was derived from the name by one rule, so title and key
    /// agreed by construction. They cannot agree any more — two Macs may
    /// call themselves the same thing, and a redeploy renames one — so the
    /// title is now free to be what a person needs to read (`pb1400c —
    /// NOW-68K 0.14`) while the identity travels beside it.
    ///
    /// Empty is a state worth drawing rather than hiding: "No Macs
    /// connected", disabled, says the wire is idle. A submenu that opens
    /// onto nothing reads as a bug in the app.
    @discardableResult
    static func fillDriveMenu(_ holder: NSMenuItem,
                              guests: [ConnectedGuest],
                              target: AnyObject,
                              action: Selector) -> NSMenu {
        let menu = holder.submenu ?? NSMenu(title: "Drive")
        menu.removeAllItems()
        guard !guests.isEmpty else {
            let empty = NSMenuItem(title: "No Macs Connected", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            holder.submenu = menu
            holder.isEnabled = false
            return menu
        }
        for guest in guests {
            /* Handle first, then what the machine calls itself. Two Macs
               reporting the same name are two rows with two handles, so a
               person can tell them apart and type the one they meant. */
            let entry = NSMenuItem(title: guest.label, action: action,
                                   keyEquivalent: "")
            entry.representedObject = guest.sessionID
            entry.target = target
            entry.state = guest.isActive ? .on : .off
            menu.addItem(entry)
        }
        holder.submenu = menu
        holder.isEnabled = true
        return menu
    }

    /// The window item leads with the window itself, the way Mail's does:
    /// closing NOW's one window leaves the app running (it is a menu-bar
    /// application), and without this there is no menu route back to it.
    private static func windowMenuItem(appName: String, target: AnyObject,
                                       actions: Actions) -> NSMenuItem {
        submenu("Window", [
            item(appName, actions.openWindow, "0", target: target),
            /* The Mirror is a window of this app, so this is where a Mac
               user looks for it — and until it was here, opening one in a
               running host meant finding the Mirror page's button or
               relaunching with --open-mirror. Already open is not a
               no-op: the item raises it. */
            item("Mirror", actions.showMirror, "1", target: target),
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front",
                 #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
    }

    /// No help book ships with NOW, and an item that opens an empty one is
    /// worse than no item. These two are real: the guest's own account of
    /// what it serves, and this Mac's log folder — the two things someone
    /// reaches for when something is not working.
    private static func helpMenuItem(appName: String, target: AnyObject,
                                     actions: Actions) -> NSMenuItem {
        submenu("Help", [
            item("Ask the Guest What It Serves", actions.askGuestForHelp, "/",
                 target: target),
            .separator(),
            item("Reveal This Mac's Log Folder", actions.revealLogFolder, "",
                 target: target),
        ])
    }
}
