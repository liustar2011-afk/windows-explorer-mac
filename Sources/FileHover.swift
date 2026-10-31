import SwiftUI
import AppKit

/// Highlight the file under a moving pointer. Scrolling clears the old hover
/// without highlighting rows passing beneath a stationary pointer.
final class FileHover: ObservableObject {
    static let shared = FileHover()

    struct Target: Equatable {
        let owner: ObjectIdentifier
        let tab: UUID
        let item: String
    }

    @Published private(set) var target: Target?
    private var pointerWindow: ObjectIdentifier?
    private var pointerPosition: CGPoint?

    func isHovered(_ item: String, in explorer: Explorer) -> Bool {
        target == Target(owner: ObjectIdentifier(explorer), tab: explorer.tab.id, item: item)
    }

    func handle(_ event: NSEvent) {
        guard event.type == .mouseMoved || event.type == .leftMouseDragged,
              let window = event.window else { return }
        let windowID = ObjectIdentifier(window)
        let position = event.locationInWindow
        guard pointerWindow != windowID || pointerPosition != position else { return }
        pointerWindow = windowID
        pointerPosition = position
        let row = RightClickRouter.shared.target(at: RightClickRouter.rootPoint(event), in: window)
        let next: Target?
        if let row, !row.blocksFileSelection,
           let explorer = row.selectionOwner, let item = row.selectionID {
            next = Target(owner: ObjectIdentifier(explorer), tab: explorer.tab.id, item: item)
        } else {
            next = nil
        }
        if target != next { target = next }
    }

    func clearForScroll() {
        if target != nil { target = nil }
    }

    func reset() {
        pointerWindow = nil
        pointerPosition = nil
        if target != nil { target = nil }
    }
}
