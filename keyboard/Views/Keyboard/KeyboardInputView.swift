import UIKit

/// Give UIKit an explicit fitting height even during host/rotation constraint transitions.
/// Never derive this value from the host-assigned height (which can transiently be full screen).
final class KeyboardInputView: UIInputView {
    var desiredHeight: CGFloat = 240 {
        didSet {
            guard desiredHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: desiredHeight)
    }
}
