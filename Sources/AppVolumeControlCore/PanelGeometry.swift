import CoreGraphics

public enum PanelGeometry {
    public static func frame(
        anchor: CGRect,
        panelSize: CGSize,
        screenFrame: CGRect,
        gap: CGFloat = 0
    ) -> CGRect {
        let maximumX = max(screenFrame.minX, screenFrame.maxX - panelSize.width)
        let centeredX = anchor.midX - (panelSize.width / 2)
        let clampedX = min(max(centeredX, screenFrame.minX), maximumX)
        let topAlignedY = min(anchor.minY, screenFrame.maxY) - gap

        return CGRect(
            x: clampedX,
            y: topAlignedY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

public enum PanelLayout {
    public static let width: CGFloat = 360
    public static let minimumHeight: CGFloat = 112
    public static let maximumHeight: CGFloat = 360

    public static func height(
        applicationCount: Int,
        showsPermissionNotice: Bool
    ) -> CGFloat {
        let rowHeight: CGFloat = 42
        let permissionNoticeHeight: CGFloat = showsPermissionNotice ? 18 : 0
        let requested = minimumHeight
            + CGFloat(max(applicationCount, 0)) * rowHeight
            + permissionNoticeHeight
        return min(maximumHeight, max(minimumHeight, requested))
    }
}
