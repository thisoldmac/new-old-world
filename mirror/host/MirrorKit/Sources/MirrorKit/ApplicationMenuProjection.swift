import Foundation

/// Makes the system Application menu usable when a foreign-scene walk did
/// not carry menu -16489. Its application rows come from the same process
/// census predicate as `mirror.app list`; the three visibility rows are the
/// stable system commands, not guesses about an application's menu bar.
public enum ApplicationMenuProjection {
    public static func projecting(_ scene: Scene) -> Scene {
        if scene.menubar?.menus.contains(where: {
            $0.id == ObjectResolver.applicationMenuID
        }) == true {
            return scene
        }
        let apps = HitTester.switchableApps(scene)
        guard let front = apps.first(where: { $0.front })
                ?? scene.apps.first(where: { $0.front }) else {
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
        let menu = Scene.Menu(title: "", apple: false, left: 0,
                              id: ObjectResolver.applicationMenuID,
                              items: items)
        var out = scene
        if out.menubar == nil {
            out.menubar = .init(app: front.name, menus: [menu])
        } else {
            out.menubar?.menus.append(menu)
        }
        return out
    }
}
