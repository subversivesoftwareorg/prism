import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving the system proxy pointed at a dead port would break networking
        // for the whole Mac. Only undo it if Prism was the one who enabled it.
        if UserDefaults.standard.bool(forKey: "prismManagesSystemProxy") {
            _ = SystemProxyManager().disableSystemProxy()
            UserDefaults.standard.set(false, forKey: "prismManagesSystemProxy")
        }
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let creditsText = """
        See through your network traffic.

        Prism is an always-on observing proxy that reveals what sites your \
        computer talks to, highlights tracking and privacy concerns, and \
        summarizes your network behavior over time.

        Subversive Software builds tools that put power back in people's hands.

        \u{00A9} 2026 subversivesoftware.org
        """

        let credits = NSAttributedString(
            string: creditsText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Prism",
            .applicationVersion: version,
            .version: build,
            .credits: credits
        ])
    }
}
