// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation
import Darwin

enum KBPersonalData {
	private static let epochKey = "kb.personal.epoch"
	private static let resetRequestedKey = "kb.personal.reset.requested"
	private static let resetAcknowledgedKey = "kb.personal.reset.acknowledged"
	private static let resetAcknowledgedAtKey = "kb.personal.reset.acknowledgedAt"
	private static let resetFailureKey = "kb.personal.reset.failure"
	private static let resetNotification = CFNotificationName(
		"com.swiftuimasterclass.keyboard.personal-data-reset" as CFString
	)

	static var containerURL: URL? {
		FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: KBSettings.appGroup
		)
	}

	/// A monotonically increasing generation for learned data. Every persisted model
	/// carries this value. A writer from an old keyboard process cannot resurrect data
	/// after reset because it is rejected before replacing the current generation.
	static var currentEpoch: UInt64 {
		let stored = KBSettings.sharedDefaults.object(forKey: epochKey) as? NSNumber
		if let stored { return max(1, stored.uint64Value) }
		KBSettings.sharedDefaults.set(NSNumber(value: UInt64(1)), forKey: epochKey)
		return 1
	}

	static var resetStatus: (requested: UInt64, acknowledged: UInt64,
		acknowledgedAt: Date?, failure: String?) {
		let requested = (KBSettings.sharedDefaults.object(forKey: resetRequestedKey) as? NSNumber)?.uint64Value ?? 0
		let acknowledged = (KBSettings.sharedDefaults.object(forKey: resetAcknowledgedKey) as? NSNumber)?.uint64Value ?? 0
		let timestamp = KBSettings.sharedDefaults.double(forKey: resetAcknowledgedAtKey)
		return (requested, acknowledged,
			timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil,
			KBSettings.sharedDefaults.string(forKey: resetFailureKey))
	}

	static func acknowledgeReset(epoch: UInt64) {
		guard epoch == currentEpoch else { return }
		KBSettings.sharedDefaults.set(NSNumber(value: epoch), forKey: resetAcknowledgedKey)
		KBSettings.sharedDefaults.set(Date().timeIntervalSince1970, forKey: resetAcknowledgedAtKey)
	}

	static func modelURL(for epoch: UInt64) -> URL? {
		containerURL?.appendingPathComponent("kb_model.\(epoch).json")
	}

	static var legacyModelURL: URL? {
		containerURL?.appendingPathComponent("kb_model.json")
	}

	/// Serializes reset against extension writes across processes. The lock file has no
	/// user content and remains after reset so both processes coordinate on one inode.
	@discardableResult
	static func withExclusiveStoreLock<T>(_ body: () throws -> T) rethrows -> T {
		guard let lockURL = containerURL else { return try body() }
		let descriptor = open(lockURL.appendingPathComponent(".kb-personal.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
		guard descriptor >= 0 else {
			KBDiagnostics.recorder.storageFailure(operation: "personal-lock-open")
			return try body()
		}
		defer { close(descriptor) }
		if flock(descriptor, LOCK_EX) != 0 {
			KBDiagnostics.recorder.storageFailure(operation: "personal-lock-acquire")
		}
		defer { flock(descriptor, LOCK_UN) }
		return try body()
	}

	/// Deletes learned language and Glide state while preserving appearance and
	/// keyboard preferences. The generation advances before files are removed.
	static func resetLearning() {
		let deleted = withExclusiveStoreLock {
			let next = currentEpoch &+ 1
			let epoch = max(2, next)
			KBSettings.sharedDefaults.set(NSNumber(value: epoch), forKey: epochKey)
			KBSettings.sharedDefaults.set(NSNumber(value: epoch), forKey: resetRequestedKey)
			let modelsRemoved = removeModelFiles()
			let captureRemoved = remove("glide_capture.jsonl")
			let success = modelsRemoved && captureRemoved
			KBSettings.sharedDefaults.removeObject(forKey: "kb.glideprofile")
			KBSettings.sharedDefaults.removeObject(forKey: "kb.touchprofile")
			return success
		}
		recordResetDeletion(deleted)
		KBStats.synchronizeAfterExternalReset()
		postReset()
	}

	/// Deletes all user-generated content. Install state remains so an enabled user is
	/// not forced through onboarding again; functional preferences return to defaults.
	static func resetAll() {
		let deleted = withExclusiveStoreLock {
			let next = currentEpoch &+ 1
			let epoch = max(2, next)
			KBSettings.sharedDefaults.set(NSNumber(value: epoch), forKey: epochKey)
			KBSettings.sharedDefaults.set(NSNumber(value: epoch), forKey: resetRequestedKey)
			var success = removeModelFiles()
			for name in ["glide_capture.jsonl", "clipboard.json", "kb_theme_bg.jpg"] {
				success = remove(name) && success
			}
			success = remove("media-cache") && success
			success = removeFiles(withPrefix: "emoji_atlas_") && success

			let preserved: Set<String> = [epochKey, resetRequestedKey,
				resetAcknowledgedKey, resetAcknowledgedAtKey, resetFailureKey,
				"kb.hasused", "kb.keyboard.lastSeen", "kb.fullaccess", "kb.fullaccess.observedAt"]
			for key in KBSettings.sharedDefaults.dictionaryRepresentation().keys
			where key.hasPrefix("kb.") && !preserved.contains(key) {
				KBSettings.sharedDefaults.removeObject(forKey: key)
			}
			return success
		}
		recordResetDeletion(deleted)
		KBStats.synchronizeAfterExternalReset()
		postReset()
	}

	private static func recordResetDeletion(_ success: Bool) {
		if success {
			KBSettings.sharedDefaults.removeObject(forKey: resetFailureKey)
		} else {
			KBSettings.sharedDefaults.set("storage-delete-failed", forKey: resetFailureKey)
			KBDiagnostics.recorder.storageFailure(operation: "personal-reset-delete")
		}
	}

	private static func removeModelFiles() -> Bool {
		let legacyRemoved = remove("kb_model.json")
		let versionedRemoved = removeFiles(withPrefix: "kb_model.")
		return legacyRemoved && versionedRemoved
	}

	private static func remove(_ name: String) -> Bool {
		guard let url = containerURL?.appendingPathComponent(name) else { return false }
		guard FileManager.default.fileExists(atPath: url.path) else { return true }
		do { try FileManager.default.removeItem(at: url); return true }
		catch { return false }
	}

	private static func removeFiles(withPrefix prefix: String) -> Bool {
		guard let root = containerURL else { return false }
		let files: [URL]
		do {
			files = try FileManager.default.contentsOfDirectory(
				at: root,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)
		} catch { return false }
		var success = true
		for file in files where file.lastPathComponent.hasPrefix(prefix) {
			do { try FileManager.default.removeItem(at: file) }
			catch { success = false }
		}
		return success
	}

	private static func postReset() {
		CFNotificationCenterPostNotification(
			CFNotificationCenterGetDarwinNotifyCenter(),
			resetNotification,
			nil,
			nil,
			true
		)
	}

	static func addResetObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			observer,
			{ _, rawObserver, _, _, _ in
				guard let rawObserver else { return }
				let target = Unmanaged<KBPersonalDataResetObserver>
					.fromOpaque(rawObserver)
					.takeUnretainedValue()
				target.receiveReset()
			},
			resetNotification.rawValue,
			nil,
			.deliverImmediately
		)
	}

	static func removeResetObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterRemoveObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			observer,
			resetNotification,
			nil
		)
	}
}

final class KBPersonalDataResetObserver {
	private let handler: (UInt64) -> Void

	init(handler: @escaping (UInt64) -> Void) {
		self.handler = handler
		KBPersonalData.addResetObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	deinit {
		KBPersonalData.removeResetObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	fileprivate func receiveReset() {
		handler(KBPersonalData.currentEpoch)
	}
}
