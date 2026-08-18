import Foundation

/// The browser face stays HTML 3.2-shaped: no JavaScript, cookies, CSS,
/// redirects, compression or chunked transfer. Old browsers only need links.
enum OnboardingPage {
    static func render(host: String, wirePort: UInt16,
                       assets: OnboardingAssetSnapshot,
                       flavor: OnboardingGuestFlavor = .powerpc,
                       setupImage: OnboardingSetupImage? = nil) -> String {
        let application = assets.application(for: flavor)
        let applicationName = flavor.applicationDisplayName
        var downloads = ""
        if application != nil {
            downloads += item("/now/application.bin", applicationName)
        } else {
            downloads += "<li><b>\(escape(applicationName)):</b> "
                + "not installed on the host</li>\n"
        }
        // NOW-68K ships no preferences as a product property, so the 68K
        // flavor has no settings download: the human types the address.
        if flavor == .powerpc {
            downloads += item("/now/settings.bin",
                              "Settings for \(host):\(wirePort)")
            if assets.codeKitten != nil {
                downloads += item("/now/codekitten.bin",
                                  "CodeKitten (optional standalone IDE)")
            }
        }
        if assets.extensionComponent != nil {
            downloads += item("/now/extension.bin",
                              "NOW Extension (optional; restart required)")
        }

        var dependencies = ""
        if flavor == .powerpc {
            for dependency in OnboardingDependencyCatalog.all {
                if let asset = dependency.installedAsset(in: assets) {
                    dependencies += item(dependencyRoute(asset),
                                         dependency.displayName)
                } else {
                    dependencies += "<li><b>\(escape(dependency.displayName)):</b> "
                        + "not installed on the host. Get it from "
                        + "<a href=\"\(escape(dependency.sourcePageURL.absoluteString))\">"
                        + "the source page</a>.</li>\n"
                }
            }
        }
        for dependency in OnboardingDependencyCatalog.additionalAssets(
            in: assets) {
            dependencies += item(dependencyRoute(dependency),
                                 dependency.fileName)
        }

        let imageDetails: String
        if let setupImage {
            let size = ByteCountFormatter.string(
                fromByteCount: setupImage.transferByteCount,
                countStyle: .file)
            imageDetails = "<p><b>Served image:</b> "
                + "\(escape(setupImage.fileName)), \(escape(size)).<br>"
                + "<b>Contains:</b> "
                + escape(setupImage.includedItems.joined(separator: ", "))
                + ".</p>"
        } else {
            imageDetails = "<p>The host is still preparing the install image. "
                + "If the download is not ready, wait a moment and reload "
                + "this page.</p>"
        }

        let imageContents: String
        let setupSteps: String
        switch flavor {
        case .powerpc:
            imageContents = "It contains the native application, settings "
                + "for this host, the optional extension, and every "
                + "selected companion application and dependency the host "
                + "has prepared. No StuffIt installation is needed for "
                + "packages the host was able to extract."
            setupSteps = """
            <li>From the mounted setup disk, copy <b>New Old World</b>.</li>
            <li>Put
            <b>New Old World Prefs</b> in <b>System Folder:Preferences</b>
            before opening New Old World for the first time.</li>
            <li>Open New Old World. It is configured to connect to
            <b>\(escape(host)):\(wirePort)</b>.</li>
            <li>When the connection succeeds, this Mac appears under Active in
            the host's Connections page.</li>
            <li>If included, copy <b>CodeKitten</b> wherever you keep applications.
            It is optional; NOW's project build and run workflow does not depend
            on the IDE.</li>
            """
        case .m68k:
            imageContents = "It contains NOW-68K and, if selected, the "
                + "optional extension. NOW-68K keeps no settings file: the "
                + "address below is typed in when it opens."
            setupSteps = """
            <li>From the mounted setup disk, copy <b>NOW-68K</b>.</li>
            <li>Open NOW-68K. Type <b>\(escape(host))</b> into Host and
            <b>\(wirePort)</b> into Port.</li>
            <li>When the connection succeeds, this Mac appears under Active in
            the host's Connections page.</li>
            """
        }

        return """
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
        <html>
        <head><title>New Old World Setup</title></head>
        <body bgcolor="#ffffff" text="#000000" link="#0000cc">
        <h1>New Old World Setup</h1>
        <p>This page is coming from the modern Mac on your LAN.</p>
        <h2>Recommended</h2>
        <p><a href="/now/setup.img"><b>Download the complete setup disk</b></a></p>
        \(imageDetails)
        <p>Your browser should decode the MacBinary transfer and leave a
        <b>\(escape(ClassicSetupImageBuilder.classicImageName(for: flavor)))</b>
        file. Open that image with Disk Copy.
        \(imageContents)</p>
        <p>If the browser saves a file ending in <b>.bin</b>, turn on its
        automatic MacBinary decoding and download again. You can also
        <a href="/now/setup.img.bin">download the MacBinary envelope</a>
        explicitly for another MacBinary-aware transfer path.</p>
        <h2>Individual files</h2>
        <p>These MacBinary files are fallbacks for machines that already have
        a MacBinary-aware transfer or decoding tool.</p>
        <ul>
        \(downloads)</ul>
        <h2>Set up the \(MachineNaming.commonNoun)</h2>
        <ol>
        \(setupSteps)</ol>
        <h2>Optional extension and dependencies</h2>
        <ul>
        \(dependencies)</ul>
        <p>Put the NOW Extension in System Folder:Extensions and restart
        \(MachineNaming.simpleReference). The application works without it, with fewer resident
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

    private static func dependencyRoute(_ asset: OnboardingAsset) -> String {
        "/now/dependencies/" + percentEncode(asset.fileName)
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
