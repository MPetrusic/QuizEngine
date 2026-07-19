import Combine
import Foundation
import QuizEngineCore
import QuizEngineGame

@MainActor
final class StarterQuizModel: ObservableObject {
    let variant = StarterQuizVariantDefinition.variant
    let questionDataService: QuestionDataService
    let progressManager: PlayerProgressManager
    let analytics = StarterNoopAnalytics()
    let purchaseStatus = StarterNoopPurchaseStatus()
    let haptics = StarterNoopHaptics()

    @Published var game: QuizViewModel?
    @Published var contentError: String?

    init() {
        questionDataService = StarterQuizContent.makeQuestionDataService()
        progressManager = PlayerProgressManager(
            variant: variant,
            questionDataService: questionDataService,
            analytics: analytics,
            purchaseStatus: purchaseStatus
        )

        do {
            try StarterQuizContent.validateQuestions(bundle: .main)
        } catch {
            contentError = error.localizedDescription
        }
    }

    func start(categoryID: String) {
        guard progressManager.isCategoryUnlocked(categoryID) else { return }

        do {
            let questions = try questionDataService.getQuestionsForCategoryMode(category: categoryID)
            let game = QuizViewModel(
                questions: questions,
                gameMode: .singlePlayer,
                selectedCategory: categoryID,
                analytics: analytics,
                purchaseStatus: purchaseStatus,
                haptics: haptics
            )
            game.progressManager = progressManager
            self.game = game
        } catch {
            contentError = error.localizedDescription
        }
    }
}

final class StarterNoopAnalytics: AnalyticsProvider, @unchecked Sendable {}

final class StarterNoopPurchaseStatus: PurchaseStatusProvider {
    let isPremium = false
    let adsRemoved = false
}

final class StarterNoopHaptics: HapticProvider {
    func notification(_ type: HapticNotificationType) {}
    func impact(_ style: HapticImpactStyle) {}
}
