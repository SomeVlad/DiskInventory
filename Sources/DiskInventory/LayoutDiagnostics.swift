import AppKit

@MainActor enum LayoutDiagnostics {
    static func drag(in view: NSView, from start: NSPoint, to end: NSPoint) -> Bool {
        guard let window = view.window else { return false }
        let origin = view.convert(start, to: nil)
        let destination = view.convert(end, to: nil)
        let middle = NSPoint(x: (origin.x + destination.x) / 2, y: (origin.y + destination.y) / 2)
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, at point: NSPoint, delay: Double) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: timestamp + delay,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = event(.leftMouseDown, at: origin, delay: 0),
              let drag = event(.leftMouseDragged, at: middle, delay: 0.03),
              let move = event(.leftMouseDragged, at: destination, delay: 0.06),
              let up = event(.leftMouseUp, at: destination, delay: 0.09) else { return false }
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(move, atStart: true)
        NSApp.postEvent(drag, atStart: true)
        view.mouseDown(with: down)
        window.contentView?.layoutSubtreeIfNeeded()
        return true
    }

    static func exerciseColumns(_ table: NSTableView) -> Bool {
        guard table.allowsColumnReordering, table.allowsColumnResizing,
              let header = table.headerView, table.tableColumns.count >= 2 else { return false }
        let column = table.tableColumns[0]
        let width = column.width
        let rect = header.headerRect(ofColumn: 0)
        let start = NSPoint(x: rect.maxX - 1, y: rect.midY)
        guard drag(in: header, from: start, to: NSPoint(x: start.x + 24, y: start.y)),
              column.width > width + 8 else {
            print("Header resizing failed for \(table.autosaveName ?? "?"), width \(width) → \(column.width).")
            return false
        }
        let first = header.headerRect(ofColumn: 0)
        let second = header.headerRect(ofColumn: 1)
        let moved = table.tableColumns[1]
        let origin = NSPoint(x: min(second.midX, header.visibleRect.maxX - 8), y: second.midY)
        let target = NSPoint(x: first.minX + 18, y: first.midY)
        guard origin.x > second.minX + 8, drag(in: header, from: origin, to: target),
              table.tableColumns[0] === moved else {
            print("Header reordering failed for \(table.autosaveName ?? "?").")
            return false
        }
        return true
    }

    static func exerciseDivider(_ split: NSSplitView) -> Bool {
        guard split.isVertical, let leading = split.subviews.first else { return false }
        let before = leading.frame.width
        let x = leading.frame.maxX + split.dividerThickness / 2
        let y = split.bounds.midY
        let limit = split.maxPossiblePositionOfDivider(at: 0)
        let delta: CGFloat = limit - x >= 35 ? 32 : -32
        let start = NSPoint(x: x, y: y)
        let moved = drag(in: split, from: start, to: NSPoint(x: x + delta, y: y))
        guard moved, abs(leading.frame.width - before) > 15 else {
            let hit = split.superview?.hitTest(split.convert(start, to: split.superview))
            let actual = leading.frame.width
            split.setPosition(x + delta, ofDividerAt: 0)
            split.window?.contentView?.layoutSubtreeIfNeeded()
            print("Divider \(split.autosaveName ?? "?") changed from \(before) to \(actual), API set it to \(leading.frame.width), allowed \(split.minPossiblePositionOfDivider(at: 0))...\(limit), hit \(String(describing: hit.map { type(of: $0) })).")
            return false
        }
        return true
    }
}
