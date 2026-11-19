import AppKit

@MainActor extension NSTableView {
    func configureInventoryColumns(_ name: String, in scrollView: NSScrollView) {
        allowsColumnResizing = true
        allowsColumnReordering = true
        columnAutoresizingStyle = .noColumnAutoresizing
        for column in tableColumns { column.resizingMask = .userResizingMask }
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = self
        autosaveName = Settings.layoutName(name)
        autosaveTableColumns = true
    }
}

@MainActor final class InventorySplitViewController: NSSplitViewController {
    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard !rect.isEmpty else { return rect }
        return rect.insetBy(dx: splitView.isVertical ? -4 : 0, dy: splitView.isVertical ? 0 : -4)
    }
}
