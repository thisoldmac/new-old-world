import AppKit
import XCTest
@testable import Host

/// The menu bar NOW did not have.
///
/// Its absence was not only cosmetic: `NSApp.mainMenu` is what dispatches key
/// equivalents, so with no main menu there was no ⌘Q, no ⌘W, and no ⌘C/⌘V in
/// the console — while a Quit item plainly existed in the status item, where
/// its ⌘Q only fires with that menu open. Everything below is checked against
/// the menu the delegate really installs, assembled through the same seam.
///
/// The delegate is built but never launched, so no status item is conjured
/// and no listener starts: `makeMainMenu` touches the registry and selectors
/// only.
@MainActor
final class MainMenuTests: XCTestCase {

    private func menu() -> NSMenu {
        quietAppDelegate().makeMainMenu()
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        let item = try XCTUnwrap(menu.items.first { $0.title == title },
                                "no \(title) menu")
        return try XCTUnwrap(item.submenu)
    }

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let sub = item.submenu {
                return [item] + allItems(sub)
            }
            return [item]
        }
    }

    // MARK: - The missing keys

    func testQuitIsInTheAppMenuWithCommandQ() throws {
        let app = try submenu(ProductIdentity.displayName, in: menu())
        let quit = try XCTUnwrap(
            app.items.first { $0.title.hasPrefix("Quit") },
            "no Quit item")
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
    }

    /// Every item with a target must actually reach it. A renamed action is
    /// otherwise a menu item that greys out or does nothing at runtime, which
    /// is exactly how a menu bar rots.
    func testEveryTargetedItemReachesItsAction() throws {
        let delegate = quietAppDelegate()
        let menu = delegate.makeMainMenu()
        // Submenu holders are excluded: AppKit gives them submenuAction:
        // and owns it.
        for item in allItems(menu)
        where item.target != nil && item.submenu == nil {
            let action = try XCTUnwrap(item.action, "\(item.title) has a "
                                       + "target and no action")
            XCTAssertTrue(delegate.responds(to: action),
                          "\(item.title) is wired to \(action), which the "
                          + "delegate does not implement")
        }
    }

    /// The editing commands must have NO target: they are dispatched down the
    /// responder chain to whatever text field is focused. Giving them one is
    /// the standard way to break ⌘C in an app that has a perfectly good Edit
    /// menu.
    func testEditingCommandsGoToTheResponderChain() throws {
        let edit = try submenu("Edit", in: menu())
        let keys = Dictionary(uniqueKeysWithValues:
            edit.items.filter { !$0.isSeparatorItem }
                .map { ($0.title, $0) })
        for title in ["Cut", "Copy", "Paste", "Select All"] {
            let item = try XCTUnwrap(keys[title], "Edit is missing \(title)")
            XCTAssertNil(item.target,
                         "\(title) must reach the focused field, not a fixed "
                         + "target")
            XCTAssertNotNil(item.action)
        }
        XCTAssertEqual(keys["Copy"]?.keyEquivalent, "c")
        XCTAssertEqual(keys["Paste"]?.keyEquivalent, "v")
        XCTAssertEqual(keys["Select All"]?.keyEquivalent, "a")
    }

    /// One shortcut, one command. A duplicate is invisible until the wrong
    /// thing happens: whichever item the menu bar finds first wins.
    func testNoTwoItemsShareAShortcut() throws {
        var seen: [String: String] = [:]
        for item in allItems(menu()) where !item.keyEquivalent.isEmpty {
            let chord = "\(item.keyEquivalentModifierMask.rawValue)"
                + item.keyEquivalent
            if let other = seen[chord] {
                XCTFail("\(item.title) and \(other) share a shortcut")
            }
            seen[chord] = item.title
        }
        XCTAssertGreaterThan(seen.count, 8, "found suspiciously few shortcuts")
    }

    // MARK: - What NOW actually does

    /// The View menu is the module registry, derived rather than retyped — so
    /// a module added to the registry appears here with no edit, which is the
    /// only reason a registry is better than a switch statement.
    func testTheViewMenuIsTheModuleRegistry() throws {
        let registry = ModuleRegistry.standard
        let view = try submenu("View", in: menu())
        let titles = view.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(titles,
                       registry.listModules.map(\.title)
                           + registry.footerModules.map(\.title),
                       "every module, list first, footer after the divider")
        // ⌘1… in order, which is what makes the numbering worth having.
        let numbered = view.items.filter { !$0.keyEquivalent.isEmpty }
        XCTAssertEqual(numbered.map(\.keyEquivalent),
                       (1...min(9, titles.count)).map(String.init))
    }

    /// The module tags carry an index into the registry, so the action does
    /// not have to parse its own title back into an identifier.
    func testEachModuleItemCarriesItsRegistryIndex() throws {
        let registry = ModuleRegistry.standard
        let view = try submenu("View", in: menu())
        for item in view.items where !item.isSeparatorItem {
            let index = item.tag - MainMenu.Tag.moduleFirst.rawValue
            XCTAssertTrue(registry.modules.indices.contains(index),
                          "\(item.title) has no registry index")
            XCTAssertEqual(registry.modules[index].title, item.title,
                           "\(item.title)'s tag points at the wrong module")
        }
    }

    /// The verbs that act on the other machine live together, and the two
    /// that only make sense with a window (settings, module navigation) do
    /// not. This pins the split so it is a decision, not an accident.
    func testGuestVerbsAreInTheGuestMenu() throws {
        let guest = try submenu("Guest", in: menu())
        let titles = guest.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Drive", "Capture Screen", "Start Listening"])
        XCTAssertEqual(guest.items.first { $0.title == "Capture Screen" }?
            .keyEquivalentModifierMask, [.command, .shift])
    }

    /// The listen item is one item with two titles, read as the menu opens.
    func testTheListenItemSaysWhatItWillDo() {
        XCTAssertEqual(AppDelegate.listenToggleTitle(.idle),
                       "Start Listening")
        XCTAssertEqual(AppDelegate.listenToggleTitle(.failed("no port")),
                       "Start Listening")
        XCTAssertEqual(AppDelegate.listenToggleTitle(.listening(port: 5250)),
                       "Stop Listening")
        XCTAssertEqual(
            AppDelegate.listenToggleTitle(.connected(guestName: "PB 180c")),
            "Stop Listening")
    }

    /// The Window submenu is handed to NSApplication by identity so it keeps
    /// the window list in it current; finding it by title is how the delegate
    /// does that, so the title is load-bearing.
    func testTheWindowsMenuIsFindable() throws {
        let main = menu()
        let windows = try XCTUnwrap(MainMenu.windowsMenu(in: main))
        XCTAssertEqual(windows.title, "Window")
        XCTAssertTrue(windows.items.contains { $0.keyEquivalent == "0" },
                      "closing the one window must leave a menu route back "
                      + "to it — NOW keeps running without one")
    }

    /// **The Mirror's menu face.** The item is the whole of it — the
    /// action ends at `HostAppState.showMirror`, which the agent
    /// verb and the guest's `host.show` also end at — so an item that
    /// lost its target or its selector would be the one face of this
    /// capability with no other gate on it.
    func testTheWindowMenuOpensTheMirror() throws {
        let windows = try XCTUnwrap(MainMenu.windowsMenu(in: menu()))
        let item = try XCTUnwrap(
            windows.items.first { $0.title == "Show Mirror" },
            "opening the Mirror in a running host has to be somewhere a "
            + "Mac user looks, and that is the Window menu")
        /* The action and not the target: `NSMenuItem.target` is WEAK, and
           the target this menu was built against is a stub that dies with
           the helper. Every other item test here checks the selector for
           the same reason. */
        XCTAssertEqual(item.action, #selector(AppDelegate.showMirror))
        XCTAssertEqual(item.keyEquivalent, "m")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift],
                       "plain Cmd-M is Minimize")
    }

    /// Help has no help book, so it must not offer one. What it offers
    /// instead has to be real.
    func testHelpOffersOnlyThingsThatExist() throws {
        let help = try submenu("Help", in: menu())
        let titles = help.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("Help") && $0.contains(
            ProductIdentity.displayName) },
            "a \"NOW Help\" item would open an empty help book")
        XCTAssertEqual(titles, ["Ask the Guest What It Serves",
                                "Reveal This Mac's Log Folder"])
    }

    // MARK: - The status item is the small surface

    /// The status item exists for when there is no window at all, so it
    /// carries the fewest verbs that make sense with nothing on screen. If it
    /// grows to mirror the main menu there are two surfaces to keep honest.
    func testTheStatusItemStaysTheSmallSurface() {
        let delegate = quietAppDelegate()
        let status = delegate.makeStatusMenu()
        let titles = status.items.filter { !$0.isSeparatorItem }.map(\.title)
        // One status line plus three verbs: open, shoot, quit.
        XCTAssertEqual(titles.count, 4, """
            The status item's menu changed size. It is deliberately the \
            smallest set that works with no window open — everything else \
            belongs in the main menu, where it lives in exactly one place.
            """)
    }

    /// **Only a route from OUTSIDE the app may take the front.**
    ///
    /// Both items open the same window, and which selector each carries is
    /// the whole of the always-on-top fix (2026-08-06): the status item is
    /// reached from whatever application the person was in and a status menu
    /// does not activate its own app, so it must bring NOW forward; the main
    /// menu is only reachable when NOW is already active, so activating there
    /// buys nothing and `ignoringOtherApps: true` merely takes the front from
    /// whoever had it. Pointing either one at the other's selector puts back
    /// one of the two defects — a window that opens behind everything, or an
    /// app that reads as always on top.
    func testOnlyTheOutsideRouteBringsTheAppForward() throws {
        let delegate = quietAppDelegate()
        let status = delegate.makeStatusMenu()
        let open = try XCTUnwrap(status.items.first {
            $0.title.hasPrefix("Open ")
        })
        XCTAssertEqual(open.action,
                       #selector(AppDelegate.openMainWindowFromOutsideTheApp),
                       """
                       The status item's Open must bring the app forward: it \
                       is clicked from another application, and a status menu \
                       does not activate its own app.
                       """)

        let main = delegate.makeMainMenu()
        let inApp = try XCTUnwrap(allItems(main).first {
            $0.action == #selector(AppDelegate.openMainWindow)
                || $0.action
                    == #selector(AppDelegate.openMainWindowFromOutsideTheApp)
        })
        XCTAssertEqual(inApp.action, #selector(AppDelegate.openMainWindow),
                       """
                       A main-menu item is reached with NOW already active. \
                       Activating from there can only take the front from \
                       another application on a route nobody asked it to.
                       """)
    }
}
