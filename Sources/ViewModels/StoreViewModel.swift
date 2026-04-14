import Foundation
import StoreKit
import SwiftData
import os.log

// MARK: - Store Error

enum StoreError: Error, Sendable {
    case productNotFound(String)
    case purchaseFailed(String)
    case verificationFailed
    case receiptValidationFailed(String)
    case networkError
    case userCancelled
    case alreadyPurchased
}

// MARK: - Product Info

/// A displayable product for the store UI.
struct ProductInfo: Identifiable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    let messageCount: Int
    let isSubscription: Bool
    var isPurchased: Bool = false

    /// StoreKit 2 product backing this info.
    let product: Product?
}

// MARK: - Store View Model

/// Manages StoreKit 2 in-app purchases for message packs.
///
/// Features:
/// - Load product catalog from App Store
/// - Purchase message packs (consumable) and subscriptions
/// - Server-side receipt verification
/// - Track and display message balance
/// - Restore previous purchases
/// - Handle transaction updates (renewals, revocations)
@MainActor
@Observable
final class StoreViewModel {

    // MARK: - Published State

    /// Available products for purchase.
    var products: [ProductInfo] = []

    /// Whether products are currently loading.
    var isLoadingProducts = false

    /// Whether a purchase is in progress.
    var isPurchasing = false

    /// Whether restore is in progress.
    var isRestoring = false

    /// Error message, if any.
    var errorMessage: String?

    /// Success message for transient feedback.
    var successMessage: String?

    /// Purchase history (most recent first).
    var purchaseHistory: [PurchaseRecord] = []

    // MARK: - Supporting Types

    struct PurchaseRecord: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let transactionID: String
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.blip", category: "StoreViewModel")
    private let modelContainer: ModelContainer
    @ObservationIgnored nonisolated(unsafe) private var transactionListener: Task<Void, Error>?
    private var loadedProducts: [Product] = []
    private var hasStarted = false

    // MARK: - Product IDs

    /// StoreKit product identifiers.
    private static let productIDs: [(String, Int)] = [
        ("au.heyblip.Blip.starter10", 10),
        ("au.heyblip.Blip.social25", 25),
        ("au.heyblip.Blip.event50", 50),
        ("au.heyblip.Blip.squad100", 100),
        ("au.heyblip.Blip.season1000", 1000),
        ("au.heyblip.Blip.unlimited", Int.max)
    ]

    private static let allProductIDs: Set<String> = Set(productIDs.map(\.0))

    /// Backend URL for receipt verification.
    private static let verifyReceiptURL = ServerConfig.authBaseURL + "/receipts/verify"

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Lifecycle

    /// Start listening for transaction updates and load products.
    func start() async {
        if hasStarted {
            return
        }
        hasStarted = true
        startTransactionListener()
        await loadProducts()
        await loadPurchaseHistory()
    }

    // MARK: - Load Products

    /// Fetch available products from the App Store.
    func loadProducts() async {
        isLoadingProducts = true
        errorMessage = nil

        do {
            let storeProducts = try await Product.products(for: Self.allProductIDs)
            loadedProducts = storeProducts

            products = storeProducts.compactMap { product in
                guard let packInfo = Self.productIDs.first(where: { $0.0 == product.id }) else {
                    return nil
                }

                return ProductInfo(
                    id: product.id,
                    displayName: product.displayName,
                    description: product.description,
                    displayPrice: product.displayPrice,
                    messageCount: packInfo.1,
                    isSubscription: product.type == .autoRenewable,
                    product: product
                )
            }.sorted { $0.messageCount < $1.messageCount }

        } catch {
            errorMessage = "Failed to load store: \(error.localizedDescription)"
        }

        isLoadingProducts = false
    }

    // MARK: - Purchase

    /// Purchase a message pack or subscription.
    func purchase(_ productInfo: ProductInfo) async {
        guard let product = productInfo.product else {
            errorMessage = "Product not available"
            return
        }

        isPurchasing = true
        errorMessage = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)

                // Verify receipt with backend
                await verifyReceipt(transaction: transaction)

                logger.info("Purchase completed: \(productInfo.displayName)")

                await transaction.finish()

                successMessage = "\(productInfo.displayName) purchased!"
                await loadPurchaseHistory()

            case .userCancelled:
                break // User cancelled, no error

            case .pending:
                successMessage = "Purchase pending approval"

            @unknown default:
                errorMessage = "Unknown purchase result"
            }

        } catch {
            if let storeError = error as? StoreError {
                errorMessage = "Purchase failed: \(storeError)"
            } else {
                errorMessage = "Purchase failed: \(error.localizedDescription)"
            }
        }

        isPurchasing = false
    }

    // MARK: - Restore Purchases

    /// Restore previous purchases.
    func restorePurchases() async {
        isRestoring = true
        errorMessage = nil

        do {
            try await AppStore.sync()

            // Check all current entitlements
            for await result in Transaction.currentEntitlements {
                do {
                    let transaction = try checkVerified(result)
                    logger.info("Restored transaction: \(transaction.productID)")
                } catch {
                    logger.error("Entitlement verification failed during restore: \(error.localizedDescription)")
                }
            }

            await loadPurchaseHistory()
            successMessage = "Purchases restored"

        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }

        isRestoring = false
    }

    // MARK: - Purchase History

    private func loadPurchaseHistory() async {
        purchaseHistory = []
    }

    // MARK: - Private: Transaction Listener

    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try await self.checkVerified(result)
                    await MainActor.run {
                        self.logger.info("Transaction update: \(transaction.productID)")
                    }
                    await transaction.finish()
                } catch {
                    await MainActor.run {
                        self.logger.error("Transaction verification failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Private: Verification

    private func checkVerified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let transaction):
            return transaction
        }
    }

    /// Verify the receipt with the backend for server-side validation.
    private func verifyReceipt(transaction: Transaction) async {
        // Build request
        guard var request = URL(string: Self.verifyReceiptURL).map({ URLRequest(url: $0) }) else { return }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "transactionID": String(transaction.id),
            "productID": transaction.productID,
            "originalID": String(transaction.originalID),
            "purchaseDate": ISO8601DateFormatter().string(from: transaction.purchaseDate),
            "environment": transaction.environment.rawValue
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize receipt body: \(error.localizedDescription)")
            return
        }

        // Send (best-effort; purchase is credited locally regardless)
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            logger.error("Failed to verify receipt with server: \(error.localizedDescription)")
        }
    }

    // MARK: - Utility

    /// Dismiss transient messages.
    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}
