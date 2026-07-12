//
//  QuizViewModel.swift
//  QuizEngineGame
//
//  Created by Milos Petrusic on 3.12.22..
//

import Combine
import Foundation
import SwiftUI
import QuizEngineCore

@MainActor
public class QuizViewModel: ObservableObject {
    private var interstitialAd: (any InterstitialAdProvider)?
    private var rewardAd: (any RewardAdProvider)?
    private let leaderboard: (any LeaderboardProvider)?
    private let analytics: (any AnalyticsProvider)?
    private let purchaseStatus: (any PurchaseStatusProvider)?
    private let haptics: (any HapticProvider)?

    @Published public private(set) var questionData: [Question] = []
    @Published public private(set) var questionNumber = -1
    @Published public private(set) var score = 0
    @Published public private(set) var livesRemaining = 3
    @Published public private(set) var shouldShowCorrectView = false
    @Published public private(set) var shouldShowWrongAnswerView = false
    @Published public private(set) var shouldShowRewardProposalView = false
    @Published public private(set) var shouldShowLifeGrantedView = false
    @Published public private(set) var shouldShowAnswerDescription = false
    @Published public private(set) var shouldShowStreakView = false
    @Published public var shouldChangeBackground: Bool = false
    @Published public var timeRemaining = 15
    @Published public var shouldAllowTap = true
    @Published public var shouldPresentResultView = false
    @Published public private(set) var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public var isRewardAdAvailable: Bool { rewardAd?.isLoaded ?? false }

    private var interstitialAdWasShown = false
    private var adRewardWasShown = false
    private var userDidEarnAward = false
    @Published public var correctAnswersInRow = 0
    private var gameMode: GameMode
    private var numberOfQuestions = 0
    public private(set) var selectedCategory: String?

    // Coin tracking
    public var progressManager: PlayerProgressManager?
    @Published public private(set) var coinsEarnedThisSession = 0

    // Power-up tracking
    @Published public private(set) var usedPowerUps: Set<PowerUp> = []
    @Published public private(set) var hiddenAnswerIndices: Set<Int> = []
    @Published public private(set) var isTimeFrozen = false
    @Published public private(set) var hasActiveStreakShield = false
    private var extraLifeUsed = false

    // MARK: - Phase 3 Session Statistics Tracking

    /// Number of correct answers in this session (for lifetime stats)
    @Published public private(set) var correctAnswersThisSession = 0

    /// Maximum consecutive correct answers achieved during this session
    @Published public private(set) var maxStreakThisSession = 0

    // MARK: - Practice Mode Tracking

    /// Questions answered incorrectly in practice mode (for end-of-session review)
    @Published public private(set) var missedQuestions: [Question] = []

    /// Total questions answered in this practice session (starts at 0, increments after each answer)
    @Published public private(set) var questionsAnsweredThisSession = 0

    /// Whether this is practice mode (no lives, learning-focused)
    public var isPracticeMode: Bool { gameMode == .practice }

    /// Whether this is competitive mode (all categories, records count)
    public var isCompetitiveMode: Bool { gameMode == .singlePlayer && selectedCategory == nil }

    /// Whether this is category mode (specific category in singlePlayer, not practice)
    public var isCategoryMode: Bool { gameMode == .singlePlayer && selectedCategory != nil }

    // MARK: - Phase E8: Advanced Statistics Tracking

    /// Timestamp when the current question was displayed (for response time calculation)
    private var questionDisplayTime: Date?

    /// Accumulated session statistics for advanced analytics
    private var advancedSessionStats = PlayerProgressManager.SessionStatistics()

    public init(
        questions: [Question]?,
        gameMode: GameMode,
        selectedCategory: String?,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        rewardAd: (any RewardAdProvider)? = nil,
        leaderboard: (any LeaderboardProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        haptics: (any HapticProvider)? = nil
    ) {
        if let orderedQuestions = questions {
            // Preserve question order (difficulty progression applied in QuestionDataService)
            // Only shuffle answers within each question
            self.questionData = orderedQuestions.map { question in
                let shuffledAnswers = question.answers.shuffled()
                return Question(
                    id: question.id,
                    question: question.question,
                    answers: shuffledAnswers,
                    imageName: question.imageName,
                    description: question.description,
                    categories: question.categories,
                    difficulty: question.difficulty
                )
            }
            numberOfQuestions = orderedQuestions.count
        } else {
            self.questionData = []
        }
        self.gameMode = gameMode
        self.selectedCategory = selectedCategory
        self.analytics = analytics
        self.interstitialAd = interstitialAd
        self.rewardAd = rewardAd
        self.leaderboard = leaderboard
        self.purchaseStatus = purchaseStatus
        self.haptics = haptics

        // Log game start event
        analytics?.logGameStarted(category: selectedCategory, mode: gameMode)

        goToNextQuestion()
        rewardAd?.load()
        interstitialAd?.load()
    }

    public func showWrongAnswerView() {
        stopTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.shouldAllowTap = true

            guard self.livesRemaining > 0 else {
                if self.extraLifeUsed {
                    self.endGame()
                } else {
                    self.showRewardProposalView()
                }
                return
            }

            self.startTimer()
            self.goToNextQuestion()
        }
    }

    public func showDescriptionView() {
        stopTimer()

        // Delay showing the description to let the wrong answer animation play first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.shouldShowAnswerDescription = true
            }
        }
    }

    public func hideDescriptionView() {
        self.shouldAllowTap = true
        withAnimation {
            shouldShowAnswerDescription = false
            self.goToNextQuestion()
        }

        if livesRemaining > 0 {
            startTimer()
        }

        if livesRemaining == 0 {
            endGame()
        }
    }

    public func showLifeGrantedView() {
        withAnimation {
            shouldShowLifeGrantedView = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.shouldAllowTap = true
            withAnimation {
                self.shouldShowLifeGrantedView = false
            }

            self.goToNextQuestion()
        }
    }

    public func showStreakView() {
        withAnimation {
            shouldShowStreakView = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation {
                self.shouldShowStreakView = false
            }
        }
    }

    public func startTimer() {
        // No timer in practice mode - learning at your own pace
        guard !isPracticeMode else { return }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    }

    public func stopTimer() {
        timer.upstream.connect().cancel()
    }

    public func goToNextQuestion() {
        resetPowerUpsForQuestion()
        withAnimation {
            guard questionNumber < numberOfQuestions - 1 else {
                endGame()
                return
            }

            questionNumber += 1

            // Phase 4A: Track question as seen for content freshness
            trackCurrentQuestionAsSeen()

            // Phase E8: Record when question is displayed for response time tracking
            questionDisplayTime = Date()
        }
    }

    /// Tracks the current question as seen (Phase 4A)
    /// Call this when a question is first displayed to the user
    public func trackCurrentQuestionAsSeen() {
        guard questionNumber >= 0 && questionNumber < questionData.count else { return }
        let currentQuestion = questionData[questionNumber]
        progressManager?.recordQuestionSeen(questionID: currentQuestion.id)
    }

    public func updateRemainingTime() {
        timeRemaining = 15
    }

    public func increaseScoreForCorrectAnswer() {
        isTimeFrozen = false
        stopTimer()
        correctAnswersInRow += 1
        score += correctAnswersInRow > 5 ? 20 : 10
        awardCoinsForCorrectAnswer()
        runStreakAchievedLogicIfNeeded()

        // Phase 3: Track session statistics
        correctAnswersThisSession += 1
        questionsAnsweredThisSession += 1
        if correctAnswersInRow > maxStreakThisSession {
            maxStreakThisSession = correctAnswersInRow
        }

        // Phase E8: Track advanced statistics
        recordAdvancedQuestionStats(wasCorrect: true)

        // Track category progress for correct answer (all modes, including competitive)
        if questionNumber >= 0 && questionNumber < questionData.count {
            let currentQuestion = questionData[questionNumber]
            // Record correct answer for all categories this question belongs to
            for category in currentQuestion.categories {
                progressManager?.recordCorrectAnswer(
                    questionID: currentQuestion.id,
                    category: category
                )
                progressManager?.markCategoryHundredPercent(category: category)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateRemainingTime()
            self.startTimer()
            self.shouldAllowTap = true
            withAnimation {
                self.goToNextQuestion()
            }
        }
    }

    private func shouldShowAd() -> Bool {
        // Premium users and users who purchased ad removal don't see interstitial ads
        if purchaseStatus?.isPremium ?? false { return false }
        if purchaseStatus?.adsRemoved ?? false { return false }

        // 40% chance (2 in 5 sessions)
        return Int.random(in: 0..<5) < 2
    }

    public func restartGame() {
        startTimer()
        updateRemainingTime()
        questionData = questionData.shuffled()
        questionNumber = 0
        score = 0
        livesRemaining = 3
        coinsEarnedThisSession = 0
        usedPowerUps = []
        hiddenAnswerIndices = []
        isTimeFrozen = false
        hasActiveStreakShield = false
        extraLifeUsed = false
        correctAnswersInRow = 0
        shouldChangeBackground = false
        correctAnswersThisSession = 0
        maxStreakThisSession = 0
        questionsAnsweredThisSession = 0
        missedQuestions = []
        shouldPresentResultView = false
        adRewardWasShown = false
        interstitialAdWasShown = false
        advancedSessionStats = PlayerProgressManager.SessionStatistics()
        interstitialAd?.load()
        rewardAd?.load()
    }

    public func reduceLivesRemaining() {
        isTimeFrozen = false
        questionsAnsweredThisSession += 1

        // Phase E8: Track advanced statistics for wrong answer
        recordAdvancedQuestionStats(wasCorrect: false)

        // Check for active streak shield - protects streak from being reset
        if hasActiveStreakShield {
            hasActiveStreakShield = false
            // Streak preserved! Don't reset correctAnswersInRow
        } else {
            correctAnswersInRow = 0
            withAnimation(.easeInOut(duration: 0.8)) {
                shouldChangeBackground = false
            }
        }

        // Track the missed question for practice mode review
        if isPracticeMode && questionNumber >= 0 && questionNumber < questionData.count {
            let currentQuestion = questionData[questionNumber]
            if !missedQuestions.contains(where: { $0.id == currentQuestion.id }) {
                missedQuestions.append(currentQuestion)
            }
        }

        // Track category progress for wrong answer (all modes, including competitive)
        if questionNumber >= 0 && questionNumber < questionData.count {
            let currentQuestion = questionData[questionNumber]
            // Record wrong answer for all categories this question belongs to
            for category in currentQuestion.categories {
                progressManager?.recordWrongAnswer(
                    questionID: currentQuestion.id,
                    category: category
                )
            }
        }

        updateRemainingTime()

        switch gameMode {
        case .singlePlayer:
            // Only reduce lives in competitive mode
            livesRemaining -= 1
            showWrongAnswerView()
        case .practice:
            // Practice mode: no lives, just show description and continue
            showDescriptionView()
        }
    }

    public func endGame() {
        hideRewardProposalView()
        stopTimer()

        shouldPresentResultView = true

        // Log game end event
        let questionsAnswered = questionNumber + 1
        analytics?.logGameEnded(
            score: score,
            livesRemaining: livesRemaining,
            questionsAnswered: questionsAnswered,
            coinsEarned: coinsEarnedThisSession,
            category: selectedCategory,
            mode: gameMode
        )

        // Update best score for category (both modes track category stats)
        if let category = selectedCategory {
            progressManager?.updateBestScore(
                category: category,
                sessionScore: score
            )
        }

        // Only record session statistics for competitive mode (not practice)
        // Practice mode is for learning, not for achievements/stats tracking
        if !isPracticeMode {
            // Update play streak (consecutive days with a completed game)
            progressManager?.updatePlayStreak()

            progressManager?.recordSessionStats(
                questionsAnswered: questionsAnswered,
                questionsCorrect: correctAnswersThisSession,
                sessionScore: score,
                longestStreak: maxStreakThisSession,
                usedPowerUps: usedPowerUps
            )

            // Phase E8: Record advanced session statistics
            progressManager?.recordAdvancedSessionStats(advancedSessionStats)

            // Phase 3C: Check for newly unlocked achievements
            progressManager?.checkAndUnlockAchievements()
        }

        // Submit score to GameKit leaderboard immediately when game ends
        // Only for competitive mode (all categories) - this ensures correct timestamps
        // for daily/weekly leaderboard filtering
        if isCompetitiveMode {
            Task {
                await leaderboard?.submitScore(score)
            }
        }
    }

    public func showRewardAd() {
        guard !adRewardWasShown else {
            shouldPresentResultView = true
            return
        }
        rewardAd?.show { [weak self] userDidEarnReward in
            self?.adRewardWasShown = true
            guard userDidEarnReward else {
                self?.endGame()
                return
            }
            self?.extraLifeUsed = true
            self?.shouldShowRewardProposalView = false
            self?.analytics?.logExtraLifeUsed(method: .ad)
            self?.incrementLives()
            self?.updateRemainingTime()
            self?.startTimer()
        }
    }

    public func showInterstitialAd() {
        interstitialAdWasShown = true
        interstitialAd?.show()
    }

    public func showInterstitialAdIfEligible() {
        guard interstitialAd?.isReady() == true, !interstitialAdWasShown, shouldShowAd() else { return }
        showInterstitialAd()
    }

    public func updateRemainingTimeAndHandleNavigationIfNeeded() {
        // No timer logic in practice mode
        guard !isPracticeMode else { return }

        if timeRemaining > 0 {
            timeRemaining -= 1
        }

        // Guard against shouldAllowTap to prevent double life-loss when the timer
        // expires in the same run loop cycle as a wrong-answer tap.
        if timeRemaining == 0 && livesRemaining > 0 && shouldAllowTap {
            shouldAllowTap = false
            reduceLivesRemaining()
            updateRemainingTime()
            haptics?.notification(.error)
            withAnimation {
                shouldShowWrongAnswerView = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation {
                    self.shouldShowWrongAnswerView = false
                }
            }
        }
    }

    private func showRewardProposalView() {
        guard gameMode == .singlePlayer else { return }
        shouldShowRewardProposalView = true
        stopTimer()
    }

    public func hideRewardProposalView() {
        guard gameMode == .singlePlayer else { return }
        shouldShowRewardProposalView = false
    }

    public func incrementLives() {
        livesRemaining += 1
        showLifeGrantedView()
    }

    // MARK: - Coin Logic

    private func awardCoins(_ amount: Int) {
        coinsEarnedThisSession += amount
        progressManager?.addCoins(amount)
    }

    private func awardCoinsForCorrectAnswer() {
        awardCoins(1)
    }

    // MARK: - Power-ups

    public func canUsePowerUp(_ powerUp: PowerUp) -> Bool {
        guard let manager = progressManager else { return false }
        return !usedPowerUps.contains(powerUp) && manager.canAfford(powerUp.cost)
    }

    public func useFiftyFifty() {
        guard canUsePowerUp(.fiftyFifty) else { return }
        guard questionNumber >= 0 else { return }
        guard progressManager?.spendCoins(PowerUp.fiftyFifty.cost) == true else { return }

        usedPowerUps.insert(.fiftyFifty)
        progressManager?.recordPowerUpUsed(.fiftyFifty)
        analytics?.logPowerUpUsed(type: .fiftyFifty, coinsSpent: PowerUp.fiftyFifty.cost)

        let currentAnswers = questionData[questionNumber].answers
        let wrongIndices = currentAnswers.enumerated()
            .filter { !$0.element.correct }
            .map { $0.offset }
            .shuffled()

        let toHide = Array(wrongIndices.prefix(2))
        withAnimation {
            hiddenAnswerIndices = Set(toHide)
        }
    }

    public func useSkipQuestion() {
        guard canUsePowerUp(.skipQuestion) else { return }
        guard progressManager?.spendCoins(PowerUp.skipQuestion.cost) == true else { return }

        usedPowerUps.insert(.skipQuestion)
        progressManager?.recordPowerUpUsed(.skipQuestion)
        analytics?.logPowerUpUsed(type: .skipQuestion, coinsSpent: PowerUp.skipQuestion.cost)
        stopTimer()
        updateRemainingTime()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startTimer()
            withAnimation {
                self.goToNextQuestion()
            }
        }
    }

    public func useTimeFreeze() {
        guard canUsePowerUp(.timeFreeze) else { return }
        guard progressManager?.spendCoins(PowerUp.timeFreeze.cost) == true else { return }

        usedPowerUps.insert(.timeFreeze)
        progressManager?.recordPowerUpUsed(.timeFreeze)
        analytics?.logPowerUpUsed(type: .timeFreeze, coinsSpent: PowerUp.timeFreeze.cost)
        isTimeFrozen = true
        stopTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            guard self.isTimeFrozen else { return }
            self.isTimeFrozen = false
            self.startTimer()
        }
    }

    // MARK: - Streak Shield

    /// Whether the streak shield can be used (requires 5+ streak and not already used)
    public func canUseStreakShield() -> Bool {
        return correctAnswersInRow >= 5 && canUsePowerUp(.streakShield)
    }

    /// Activates the streak shield, protecting the current streak from one wrong answer
    public func useStreakShield() {
        guard canUseStreakShield() else { return }
        guard progressManager?.spendCoins(PowerUp.streakShield.cost) == true else { return }

        usedPowerUps.insert(.streakShield)
        progressManager?.recordPowerUpUsed(.streakShield)
        analytics?.logPowerUpUsed(type: .streakShield, coinsSpent: PowerUp.streakShield.cost)
        hasActiveStreakShield = true
    }

    public func useExtraLifeWithCoins() -> Bool {
        guard !extraLifeUsed else { return false }
        let cost = 50  // Matches the cost shown in RewardView
        guard progressManager?.spendCoins(cost) == true else { return false }

        extraLifeUsed = true
        analytics?.logExtraLifeUsed(method: .coins)
        hideRewardProposalView()  // Hide the reward view first
        incrementLives()  // This shows the life granted animation
        updateRemainingTime()
        startTimer()
        return true
    }

    private func resetPowerUpsForQuestion() {
        hiddenAnswerIndices = []
        if isTimeFrozen {
            isTimeFrozen = false
        }
    }

    private func runStreakAchievedLogicIfNeeded() {
        if correctAnswersInRow == 5 {
            haptics?.impact(.heavy)
            withAnimation(.easeInOut(duration: 0.8)) {
                shouldChangeBackground = true
            }

            showStreakView()
        }
    }

    // MARK: - Phase E8: Advanced Statistics Recording

    /// Records advanced statistics for a single question response
    /// - Parameter wasCorrect: Whether the answer was correct
    private func recordAdvancedQuestionStats(wasCorrect: Bool) {
        // Calculate response time in milliseconds
        let responseTimeMs: Int
        if let displayTime = questionDisplayTime {
            responseTimeMs = Int(Date().timeIntervalSince(displayTime) * 1000)
        } else {
            responseTimeMs = 0
        }

        // Get current question's difficulty
        let difficulty: QuestionDifficulty
        if questionNumber >= 0 && questionNumber < questionData.count {
            let currentQuestion = questionData[questionNumber]
            difficulty = QuestionDifficulty(rawValue: currentQuestion.difficulty) ?? .medium
        } else {
            difficulty = .medium
        }

        // Update session statistics
        advancedSessionStats.questionsAnswered += 1
        advancedSessionStats.totalResponseTimeMs += responseTimeMs
        advancedSessionStats.questionsByDifficulty[difficulty, default: 0] += 1

        if wasCorrect {
            advancedSessionStats.questionsCorrect += 1
            advancedSessionStats.correctByDifficulty[difficulty, default: 0] += 1
        }
    }
}
