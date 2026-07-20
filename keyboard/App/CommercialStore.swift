import Foundation
import Combine
import StoreKit
import SwiftUI

enum OfferInterest: String, CaseIterable, Codable, Identifiable {
	case entertainment
	case food
	case learning
	case shopping
	case travel

	var id: String { rawValue }
	var title: String { rawValue.capitalized }
	var symbol: String {
		switch self {
		case .entertainment: return "play.tv.fill"
		case .food: return "fork.knife"
		case .learning: return "book.fill"
		case .shopping: return "bag.fill"
		case .travel: return "airplane"
		}
	}
}

enum CommercialRewardKind: String, Codable {
	case theme
	case points
	case voucher
	case cashback
}

enum CommercialCampaignSource: String, Codable {
	case storeKit
	case rewardedAd
	case affiliate
	case firstParty
}

struct CommercialCampaign: Identifiable, Codable, Equatable {
	let id: String
	let title: String
	let subtitle: String
	let merchantID: String?
	let interest: OfferInterest?
	let source: CommercialCampaignSource
	let reward: CommercialRewardKind
	let destination: URL?

	var isPolicyCompatible: Bool {
		guard !id.isEmpty, !title.isEmpty else { return false }
		if reward == .cashback { return source == .affiliate && merchantID != nil }
		if source == .affiliate { return merchantID != nil }
		return true
	}
}

struct AuthenticatedOfferClick: Codable, Equatable, Sendable {
	let campaignID: String
	let merchantID: String
	let oneTimeToken: String
	let destination: URL
	let expiresAt: Date

	func validated(for campaign: CommercialCampaign, now: Date = .now) throws -> URL {
		guard campaign.source == .affiliate,
			  campaignID == campaign.id,
			  merchantID == campaign.merchantID,
			  !oneTimeToken.isEmpty,
			  expiresAt > now,
			  destination.scheme?.lowercased() == "https" else {
			throw CommercialPolicyError.invalidOfferClick
		}
		return destination
	}
}

enum CashbackLedgerStatus: String, Codable, Sendable {
	case pendingReturnWindow
	case fraudReview
	case payable
	case paid
	case reversed
}

struct CashbackLedgerEntry: Identifiable, Codable, Equatable, Sendable {
	let id: String
	let campaignID: String
	let merchantID: String
	let amountMinorUnits: Int
	let currencyCode: String
	let status: CashbackLedgerStatus
	let updatedAt: Date
}

struct RewardedThemeEntitlement: Codable, Equatable, Sendable {
	let themeID: String
	let serverVerificationNonce: String
	let expiresAt: Date?
}

enum CommercialPolicyError: Error {
	case incompatibleCampaign
	case invalidOfferClick
	case invalidReward
}

/// Implemented by the authenticated companion-app backend. Implementations mint a
/// click token only after the user explicitly opens an offer; no keyboard event or
/// installed-app inventory is accepted by this boundary.
protocol CommercialBackend: Sendable {
	func beginAffiliateClick(campaignID: String) async throws -> AuthenticatedOfferClick
	func cashbackLedger() async throws -> [CashbackLedgerEntry]
	func verifyRewardedTheme(nonce: String) async throws -> RewardedThemeEntitlement
}

/// Companion-app commercial state. This intentionally uses the app's standard
/// container, not the keyboard App Group, so neither the extension nor its typed-text
/// process can read or write marketing preferences.
@MainActor
final class CommercialStore: ObservableObject {
	static let productIDs: Set<String> = [
		"com.swiftuimasterclass.keyboard.premium.monthly",
		"com.swiftuimasterclass.keyboard.themes.complete",
	]

	@Published private(set) var products: [Product] = []
	@Published private(set) var purchasedProductIDs = Set<String>()
	@Published private(set) var campaigns: [CommercialCampaign] = []
	@Published private(set) var cashbackLedger: [CashbackLedgerEntry] = []
	@Published var interests: Set<OfferInterest> {
		didSet { persistInterests() }
	}
	@Published private(set) var storeError: String?

	private let defaults: UserDefaults
	private var transactionListener: Task<Void, Never>?
	private var serverCampaigns: [CommercialCampaign] = []

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		let raw = defaults.array(forKey: "commercial.explicitInterests") as? [String] ?? []
		interests = Set(raw.compactMap(OfferInterest.init(rawValue:)))
		transactionListener = Task { [weak self] in
			for await update in Transaction.updates {
				guard let self else { return }
				if case .verified(let transaction) = update {
					await transaction.finish()
					await self.refreshEntitlements()
				}
			}
		}
	}

	deinit { transactionListener?.cancel() }

	func refresh() async {
		do {
			products = try await Product.products(for: Self.productIDs)
				.sorted { $0.price < $1.price }
			storeError = nil
		} catch {
			products = []
			storeError = "The store is unavailable right now."
		}
		await refreshEntitlements()
	}

	func purchase(_ product: Product) async {
		do {
			switch try await product.purchase() {
			case .success(.verified(let transaction)):
				await transaction.finish()
				await refreshEntitlements()
			case .success(.unverified):
				storeError = "The purchase could not be verified."
			case .pending, .userCancelled:
				break
			@unknown default:
				storeError = "The purchase could not be completed."
			}
		} catch {
			storeError = "The purchase could not be completed."
		}
	}

	/// Accept only policy-compatible, server-issued campaigns. A future network client
	/// may call this with a feed personalized from explicit interests, saved merchants,
	/// and confirmed prior offers. There is deliberately no keyboard-data parameter.
	func applyServerCampaigns(_ value: [CommercialCampaign]) {
		serverCampaigns = value.filter(\.isPolicyCompatible)
		refreshVisibleCampaigns()
	}

	func beginAffiliateClick(_ campaign: CommercialCampaign,
		using backend: any CommercialBackend) async throws -> URL {
		guard campaign.isPolicyCompatible, campaign.source == .affiliate else {
			throw CommercialPolicyError.incompatibleCampaign
		}
		let click = try await backend.beginAffiliateClick(campaignID: campaign.id)
		return try click.validated(for: campaign)
	}

	func refreshCashbackLedger(using backend: any CommercialBackend) async throws {
		let entries = try await backend.cashbackLedger()
		cashbackLedger = entries.filter {
			!$0.id.isEmpty && !$0.campaignID.isEmpty && !$0.merchantID.isEmpty &&
			$0.amountMinorUnits >= 0 && $0.currencyCode.count == 3 &&
			$0.currencyCode.allSatisfy { $0.isASCII && $0.isLetter }
		}.sorted { $0.updatedAt > $1.updatedAt }
	}

	func verifyRewardedTheme(nonce: String,
		using backend: any CommercialBackend) async throws -> RewardedThemeEntitlement {
		guard !nonce.isEmpty else { throw CommercialPolicyError.invalidReward }
		let entitlement = try await backend.verifyRewardedTheme(nonce: nonce)
		guard !entitlement.themeID.isEmpty,
			  !entitlement.serverVerificationNonce.isEmpty,
			  entitlement.expiresAt.map({ $0 > .now }) ?? true else {
			throw CommercialPolicyError.invalidReward
		}
		return entitlement
	}

	func setInterest(_ interest: OfferInterest, enabled: Bool) {
		if enabled { interests.insert(interest) } else { interests.remove(interest) }
		refreshVisibleCampaigns()
	}

	private func refreshVisibleCampaigns() {
		campaigns = serverCampaigns.filter { campaign in
			guard let interest = campaign.interest else { return true }
			return interests.contains(interest)
		}
	}

	private func refreshEntitlements() async {
		var verified = Set<String>()
		for await result in Transaction.currentEntitlements {
			if case .verified(let transaction) = result,
			   transaction.revocationDate == nil {
				verified.insert(transaction.productID)
			}
		}
		purchasedProductIDs = verified
	}

	private func persistInterests() {
		defaults.set(interests.map(\.rawValue).sorted(), forKey: "commercial.explicitInterests")
	}
}
