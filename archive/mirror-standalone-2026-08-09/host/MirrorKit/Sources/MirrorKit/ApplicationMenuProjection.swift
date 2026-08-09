import Foundation

/// Makes the system Application menu usable when a foreign-scene walk did
/// not carry menu -16489. Its application rows come from the same process
/// census predicate as `mirror.app list`; the three visibility rows are the
/// stable system commands, not guesses about an application's menu bar.
public enum ApplicationMenuProjection {
    public static func projecting(_ scene: Scene) -> Scene {
        let apps = HitTester.switchableApps(scene)
        guard let front = apps.first(where: { $0.front })
                ?? scene.apps.first(where: { $0.front }) else {
            return scene
        }

        /* Presence is not completeness. With Finder P3 disabled the guest
           can still report menu -16489's shell while carrying no rows. The
           previous projection treated that empty shell as authoritative and
           deliberately returned it unchanged, which is exactly how the
           Application menu became a blank dropdown on metal.

           A usable guest menu names every switchable process in the same
           process roster. Keep that richer answer byte-for-byte. Otherwise
           rebuild the stable system rows and application rows from the
           roster, while retaining the guest's measured title position. */
        let roster = Set(apps.map(\.name))
        let existingIndex = scene.menubar?.menus.firstIndex {
            $0.id == ObjectResolver.applicationMenuID
        }
        if let existingIndex,
           let existing = scene.menubar?.menus[existingIndex],
           roster.isSubset(of: Set(existing.items.map(\.title))) {
            return scene
        }

        var items: [Scene.MenuItem] = [
            .init(title: "Hide \(front.name)", index: 1,
                  separator: false, enabled: true, mark: false, cmd: "H"),
            .init(title: "Hide Others", index: 2,
                  separator: false, enabled: apps.count > 1,
                  mark: false, cmd: ""),
            .init(title: "Show All", index: 3,
                  separator: false, enabled: true, mark: false, cmd: ""),
            .init(title: "", index: 4, separator: true,
                  enabled: false, mark: false, cmd: ""),
        ]
        items.append(contentsOf: apps.enumerated().map { offset, app in
            .init(title: app.name, index: offset + 5, separator: false,
                  enabled: true, mark: app.front, cmd: "")
        })
        let existing = existingIndex.flatMap { scene.menubar?.menus[$0] }
        let menu = Scene.Menu(title: "", apple: false,
                              left: existing?.left ?? 0,
                              id: ObjectResolver.applicationMenuID,
                              items: items)
        var out = scene
        /* The renderer and object resolver historically read `apps`, while
           the complete process census now lives in `processes` when P3 is
           off. These are not invented applications: they are the exact
           switchable process rows, projected into the older shelf so every
           Application-menu consumer sees one roster. */
        let known = Set(out.apps.map(\.psn))
        out.apps.append(contentsOf: apps.filter { !known.contains($0.psn) })
        if out.menubar == nil {
            out.menubar = .init(app: front.name, menus: [menu])
        } else if let existingIndex {
            out.menubar?.menus[existingIndex] = menu
        } else {
            out.menubar?.menus.append(menu)
        }
        return out
    }
}
