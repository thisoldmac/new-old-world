import Foundation

/// The four rows in `net` that measure the WIRE rather than describe the
/// machine's networking — named once, because two pages read the same list
/// from opposite ends.
///
/// **Why they moved.** Networking is a facts page: what this machine's
/// address is, what interfaces it has, what its stack can and cannot be
/// asked. Round trip, receive window, window peak and quiet time are none of
/// those — they are measurements of the link between the two Macs, and they
/// belong beside `wirestat`, which measures the other half of the same
/// question (034, G-1). So Diagnostics shows them and Networking stops.
///
/// **One list, two consumers, and it fails visibly.** `NetworkingModel`
/// removes exactly these labels and `DiagnosticsModel` keeps exactly these
/// labels, both from here. If the guest renames a row, it stops matching in
/// both places at once — so it reappears on Networking rather than
/// disappearing from the app, which is the failure a reader can see.
///
/// The labels are the guest's, from
/// `now-guest-ppc/src/network/net_layout.c :: now_net_row` (the link
/// section). They are matched on the label alone, never on the section
/// title: the host's rule for `net` is that it parses the guest's SHAPE and
/// never its vocabulary, and a section title is prose that will be rewritten
/// one day.
enum GuestLinkTiming {
    static let labels: Set<String> = [
        "Round trip", "Receive window", "Window peak", "Quiet for",
    ]

    static func isTiming(_ label: String) -> Bool {
        labels.contains(label)
    }
}
