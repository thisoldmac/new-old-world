import Foundation

/// Host-side joins for Apple-menu presentation facts the Menu Manager does
/// not expose: file icon identity. Titles remain guest-owned and unknown rows
/// remain untouched. The profile is explicit so later system versions can
/// replace this table without changing scene or wire semantics.
public enum AppleMenuProfile {
    public static func macOS86(_ menu: Scene.Menu) -> Scene.Menu {
        guard menu.apple else { return menu }
        var result = menu
        result.items = menu.items.map { item in
            var item = item
            item.icon = macOS86Icons[clean(item.title)]
            return item
        }
        return result
    }

    private static func clean(_ title: String) -> String {
        String(title.drop(while: { $0 == "\0" }))
    }

    private static func icon(_ creator: String, _ type: String)
        -> Scene.MenuItem.IconIdentity {
        .init(creator: creator, type: type)
    }

    private static let folder = Scene.MenuItem.IconIdentity(generic: "folder")

    private static let macOS86Icons: [String: Scene.MenuItem.IconIdentity] = [
        "About This Computer": .init(systemIconID: -16396),
        "Apple FM Radio": icon("fmtn", "APPL"),
        "Apple System Profiler": icon("prfc", "APPD"),
        "AppleCD Audio Player": icon("aucd", "APPL"),
        "Automated Tasks": folder,
        "Calculator": icon("calc", "dfil"),
        "Chooser": icon("chzr", "dfil"),
        "Control Panels": folder,
        "Favorites": folder,
        "Graphing Calculator": .init(generic: "application"),
        "Internet Access": folder,
        "Key Caps": icon("keyc", "APPD"),
        "Network Browser": icon("nbrw", "APPL"),
        "Note Pad": icon("npdt", "APPL"),
        "Recent Applications": folder,
        "Recent Documents": folder,
        "Remote Access Status": icon("rasm", "APPL"),
        "Scrapbook": icon("sbkt", "APPL"),
        "Sherlock": icon("fndf", "APPL"),
        "Sherlock 2": icon("fndf", "APPL"),
        "SimpleSound": icon("sSnd", "APPL"),
        "Stickies": icon("notz", "APPL"),
    ]
}
