import AppKit
import SwiftUI

struct SidebarHoverDisclosure: Equatable {
    static let presentationDelayNanoseconds: UInt64 = 450_000_000

    let title: String
    let detail: String?
    let symbol: String
}

/// A transient native popover gives a collapsed row its expanded identity
/// without changing the sidebar's geometry. The short dwell ignores cursor
/// transit; leaving the row or beginning a click/drag dismisses immediately.
@MainActor
final class SidebarHoverDisclosurePresenter {
    private weak var anchor: NSView?
    private var disclosure: SidebarHoverDisclosure?
    private var presentationTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var pointerIsInside = false

    func update(disclosure: SidebarHoverDisclosure?, anchor: NSView) {
        self.anchor = anchor
        guard self.disclosure != disclosure else { return }
        self.disclosure = disclosure
        dismiss()
        if pointerIsInside { schedulePresentation() }
    }

    func pointerEntered() {
        pointerIsInside = true
        schedulePresentation()
    }

    func pointerExited() {
        pointerIsInside = false
        dismiss()
    }

    func cancel() {
        dismiss()
    }

    private func schedulePresentation() {
        presentationTask?.cancel()
        guard disclosure != nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: SidebarHoverDisclosure
                    .presentationDelayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.pointerIsInside else { return }
            self.present()
        }
    }

    private func present() {
        guard popover == nil,
              let disclosure,
              let anchor,
              anchor.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 264,
                                     height: disclosure.detail == nil ? 62 : 82)
        popover.contentViewController = NSHostingController(
            rootView: SidebarHoverDisclosureCard(disclosure: disclosure))
        popover.show(relativeTo: anchor.bounds, of: anchor,
                     preferredEdge: .maxX)
        self.popover = popover
    }

    private func dismiss() {
        presentationTask?.cancel()
        presentationTask = nil
        popover?.performClose(nil)
        popover = nil
    }
}

private struct SidebarHoverDisclosureCard: View {
    let disclosure: SidebarHoverDisclosure

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: disclosure.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(disclosure.title)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = disclosure.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 264, alignment: .leading)
    }
}
