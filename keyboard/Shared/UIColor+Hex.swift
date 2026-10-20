// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import UIKit

// UIColor hex + blend helpers — extracted from Keyboard.swift.

extension UIColor {
	convenience init(hex: UInt32) {
		self.init(red: CGFloat((hex >> 16) & 0xFF)/255,
				  green: CGFloat((hex >> 8) & 0xFF)/255,
				  blue: CGFloat(hex & 0xFF)/255, alpha: 1)
	}
	/// Mix toward another colour. fraction 0 = self, 1 = other.
	func blended(with other: UIColor, fraction f: CGFloat) -> UIColor {
		var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
		var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
		getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
		other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
		return UIColor(red: r1+(r2-r1)*f, green: g1+(g2-g1)*f, blue: b1+(b2-b1)*f, alpha: a1+(a2-a1)*f)
	}
}

