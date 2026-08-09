import Foundation

/// The browser face stays HTML 3.2-shaped: no JavaScript, cookies, CSS,
/// redirects, compression or chunked transfer. Old browsers only need links.
enum OnboardingPage {
    static func render(host: String, wirePort: UInt16,
                       assets: OnboardingAssetSnapshot) -> String {
        var downloads = ""
        if assets.application != nil {
            downloads += item("/now/application.bin", "New Old World")
        } else {
            downloads += "<li><b>New Old World:</b> not installed on the host</li>\n"
        }
        downloads += item("/now/settings.bin",
                          "Settings for \(host):\(wirePort)")
        if assets.archive != nil {
            downloads += item("/now/archive.sit",
                              "Complete StuffIt archive (optional)")
        }
        if assets.extensionComponent != nil {
            downloads += item("/now/extension.bin",
                              "NOW Extension (optional; restart required)")
        }

        var dependencies = ""
        for dependency in assets.dependencies {
            let route = "/now/dependencies/"
                + percentEncode(dependency.fileName)
            dependencies += item(route, dependency.fileName)
        }
        if dependencies.isEmpty {
            dependencies = "<li>No local dependency packages are installed.</li>\n"
        }
        if !assets.hasCarbonLib {
            dependencies += "<li>CarbonLib is not bundled. Get CarbonLib 1.6 "
                + "from <a href=\"http://macintoshgarden.org/apps/carbonlib\">"
                + "Macintosh Garden</a> if this Mac does not have it.</li>\n"
        }

        return """
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
        <html>
        <head><title>New Old World Setup</title></head>
        <body bgcolor="#ffffff" text="#000000" link="#0000cc">
        <h1>New Old World Setup</h1>
        <p>This page is coming from the modern Mac on your LAN.</p>
        <h2>Downloads</h2>
        <ul>
        \(downloads)</ul>
        <h2>Set up the classic Mac</h2>
        <ol>
        <li>Download and decode <b>New Old World</b>.</li>
        <li>Download and decode the settings file. Put
        <b>New Old World Prefs</b> in <b>System Folder:Preferences</b>
        before opening New Old World for the first time.</li>
        <li>Open New Old World. It is configured to connect to
        <b>\(escape(host)):\(wirePort)</b>.</li>
        <li>When the connection succeeds, this Mac appears under Active in
        the host's Connections page.</li>
        </ol>
        <h2>Optional extension and dependencies</h2>
        <ul>
        \(dependencies)</ul>
        <p>Put the NOW Extension in System Folder:Extensions and restart the
        classic Mac. The application works without it, with fewer resident
        capabilities.</p>
        <hr>
        <p><small>This temporary server accepts only setup downloads. Stop it
        from the Connections page when setup is complete.</small></p>
        </body>
        </html>
        """
    }

    private static func item(_ href: String, _ label: String) -> String {
        "<li><a href=\"\(href)\">\(escape(label))</a></li>\n"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.utf8.map { byte in
            let scalar = UnicodeScalar(byte)
            let character = Character(String(scalar))
            return allowed.contains(character)
                ? String(character)
                : String(format: "%%%02X", byte)
        }.joined()
    }
}
