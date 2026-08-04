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
    private let clock: any QuizEngineClock
    private let calendar: Calendar
    private let scheduler: any QuizEngineScheduler
    public let rules: QuizRulesConfiguration
    private var randomNumberGenerator: any RandomNumberGenerator
    private var scheduledTasks: [ScheduledTaskKind: ScheduledTaskRegistration] = [:]
    private var timerTask: (any QuizEngineScheduledTask)?
    private var timerGeneration: UInt = 0
    private var timerSegmentStartTime: Date?
    private var timerSegmentStartingRemaining: TimeInterval
    private var timerRemainingSeconds: TimeInterval
    private var timerIsRunning = false
    private var sessionTimingPaused = false
    private var timerWasRunningBeforePause = false
    private var freezeSegmentStartTime: Date?
    private var freezeSegmentStartingRemaining: TimeInterval = 0
    private var freezeRemainingSeconds: TimeInterval = 0
    private static let timerPrecisionTolerance: TimeInterval = 0.000_001

    @Published public private(set) var questionData: [Question] = []
    @Published public private(set) var questionNumber = -1
    @Published public private(set) var score = 0
    @Published public private(set) var livesRemaining: Int
    @Published public private(set) var shouldShowCorrectView = false
    @Published public private(set) var shouldShowWrongAnswerView = false
    @Published public private(set) var shouldShowRewardProposalView = false
    @Published public private(set) var shouldShowLifeGrantedView = false
    @Published public private(set) var shouldShowAnswerDescription = false
    @Published public private(set) var shouldShowStreakView = false
    @Published public var shouldChangeBackground: Bool = false
    @Published public var timeRemaining: Int
    @Published public var shouldAllowTap = true
    @Published public var shouldPresentResultView = false
    @Published public private(set) var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public var isRewardAdAvailable: Bool {
        rules.extraLife.allowsRewardedAd
            && extraLifeUseCount < rules.extraLife.maximumUsesPerSession
            && (rewardAd?.isLoaded ?? false)
    }

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
    @Published public private(set) var lastPowerUpFunding: PowerUpSpendResult?
    private var extraLifeUseCount = 0
    private var powerUpUseCounts: [PowerUp: Int] = [:]
    private var powerUpsUsedOnCurrentQuestion: Set<PowerUp> = []

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
    private var advancedSessionStats: PlayerProgressManager.SessionStatistics

    private enum ScheduledTaskKind: Hashable {
        case wrongAnswerAdvance
        case description
        case lifeGranted
        case streak
        case nextQuestion
        case wrongAnswerOverlay
        case skipQuestion
        case timeFreeze
    }

    private final class ScheduledTaskRegistration {
        var task: (any QuizEngineScheduledTask)?
    }

    public convenience init(
        questions: [Question]?,
        gameMode: GameMode,
        selectedCategory: String?,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        rewardAd: (any RewardAdProvider)? = nil,
        leaderboard: (any LeaderboardProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        haptics: (any HapticProvider)? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        calendar: Calendar = .current,
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler(),
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.init(
            questions: questions,
            gameMode: gameMode,
            selectedCategory: selectedCategory,
            rules: .serbianCompatible,
            analytics: analytics,
            interstitialAd: interstitialAd,
            rewardAd: rewardAd,
            leaderboard: leaderboard,
            purchaseStatus: purchaseStatus,
            haptics: haptics,
            clock: clock,
            calendar: calendar,
            scheduler: scheduler,
            randomNumberGenerator: randomNumberGenerator
        )
    }

    public init(
        questions: [Question]?,
        gameMode: GameMode,
        selectedCategory: String?,
        rules: QuizRulesConfiguration,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        rewardAd: (any RewardAdProvider)? = nil,
        leaderboard: (any LeaderboardProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        haptics: (any HapticProvider)? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        calendar: Calendar = .current,
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler(),
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        var initialRandomNumberGenerator = randomNumberGenerator
        if let orderedQuestions = questions {
            // Preserve question order (difficulty progression applied in QuestionDataService)
            // Only shuffle answers within each question
            self.questionData = orderedQuestions.map { question in
                let shuffledAnswers = question.answers.shuffled(using: &initialRandomNumberGenerator)
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
        self.rules = rules
        self.livesRemaining = rules.solo.startingLives
        self.timeRemaining = rules.solo.timerDurationSeconds
        self.timerSegmentStartingRemaining = TimeInterval(rules.solo.timerDurationSeconds)
        self.timerRemainingSeconds = TimeInterval(rules.solo.timerDurationSeconds)
        self.analytics = analytics
        self.interstitialAd = interstitialAd
        self.rewardAd = rewardAd
        self.leaderboard = leaderboard
        self.purchaseStatus = purchaseStatus
        self.haptics = haptics
        self.clock = clock
        self.calendar = calendar
        self.scheduler = scheduler
        self.randomNumberGenerator = initialRandomNumberGenerator
        self.advancedSessionStats = PlayerProgressManager.SessionStatistics(
            clock: clock,
            calendar: calendar
        )

        // Log game start event
        analytics?.logGameStarted(category: selectedCategory, mode: gameMode)

        goToNextQuestion()
        startTimer()
        rewardAd?.load()
        interstitialAd?.load()
    }

    public func showWrongAnswerView() {
        stopTimer()
        schedule(.wrongAnswerAdvance, after: 1.0) {
            self.shouldAllowTap = true

            guard self.livesRemaining > 0 else {
                if self.extraLifeUseCount >= self.rules.extraLife.maximumUsesPerSession {
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
        schedule(.description, after: 1.0) {
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
        schedule(.lifeGranted, after: 1.0) {
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

        schedule(.streak, after: 1.0) {
            withAnimation {
                self.shouldShowStreakView = false
            }
        }
    }

    public func startTimer() {
        // No timer in practice mode - learning at your own pace
        guard !isPracticeMode,
              !sessionTimingPaused,
              !isTimeFrozen,
              !shouldPresentResultView,
              timerRemainingSeconds > 0,
              !timerIsRunning else { return }
        timerSegmentStartTime = clock.now
        timerSegmentStartingRemaining = timerRemainingSeconds
        timerIsRunning = true
        timerGeneration &+= 1
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        scheduleTimerTick(generation: timerGeneration)
    }

    public func stopTimer() {
        synchronizeTimer(allowTimeout: false)
        timerIsRunning = false
        timerGeneration &+= 1
        timerSegmentStartTime = nil
        timerTask?.cancel()
        timerTask = nil
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
            questionDisplayTime = clock.now
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
        timerRemainingSeconds = TimeInterval(rules.solo.timerDurationSeconds)
        timerSegmentStartingRemaining = timerRemainingSeconds
        timerSegmentStartTime = timerIsRunning ? clock.now : nil
        timeRemaining = rules.solo.timerDurationSeconds
    }

    public func increaseScoreForCorrectAnswer() {
        isTimeFrozen = false
        stopTimer()
        correctAnswersInRow += 1
        let scoring = rules.solo.scoring
        let points = correctAnswersInRow > scoring.streakThreshold
            ? scoring.streakCorrectPoints
            : scoring.baseCorrectPoints
        score = Self.saturatingAdd(score, points)
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

        schedule(.nextQuestion, after: 1.0) {
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

        let eligibility = rules.soloInterstitialEligibility
        guard eligibility.numerator > 0 else { return false }
        return Int.random(in: 0..<eligibility.denominator, using: &randomNumberGenerator) < eligibility.numerator
    }

    public func restartGame() {
        stopTimer()
        cancelScheduledTasks()
        questionData = questionData.shuffled(using: &randomNumberGenerator)
        questionNumber = 0
        questionDisplayTime = clock.now
        score = 0
        livesRemaining = rules.solo.startingLives
        coinsEarnedThisSession = 0
        usedPowerUps = []
        hiddenAnswerIndices = []
        isTimeFrozen = false
        hasActiveStreakShield = false
        lastPowerUpFunding = nil
        extraLifeUseCount = 0
        powerUpUseCounts = [:]
        powerUpsUsedOnCurrentQuestion = []
        correctAnswersInRow = 0
        shouldAllowTap = true
        shouldChangeBackground = false
        shouldShowCorrectView = false
        shouldShowWrongAnswerView = false
        shouldShowRewardProposalView = false
        shouldShowLifeGrantedView = false
        shouldShowAnswerDescription = false
        shouldShowStreakView = false
        correctAnswersThisSession = 0
        maxStreakThisSession = 0
        questionsAnsweredThisSession = 0
        missedQuestions = []
        shouldPresentResultView = false
        adRewardWasShown = false
        interstitialAdWasShown = false
        advancedSessionStats = PlayerProgressManager.SessionStatistics(
            clock: clock,
            calendar: calendar
        )
        sessionTimingPaused = false
        timerWasRunningBeforePause = false
        freezeSegmentStartTime = nil
        freezeSegmentStartingRemaining = 0
        freezeRemainingSeconds = 0
        updateRemainingTime()
        trackCurrentQuestionAsSeen()
        startTimer()
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
        cancelScheduledTasks()
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

        // Submit score to the app-provided leaderboard immediately when game ends
        // Only for competitive mode (all categories) - this ensures correct timestamps
        // for daily/weekly leaderboard filtering
        if isCompetitiveMode {
            Task {
                await leaderboard?.submitScore(score)
            }
        }
    }

    public func showRewardAd() {
        guard rules.extraLife.allowsRewardedAd,
              extraLifeUseCount < rules.extraLife.maximumUsesPerSession else {
            shouldPresentResultView = true
            return
        }
        rewardAd?.show { [weak self] userDidEarnReward in
            self?.adRewardWasShown = true
            guard userDidEarnReward else {
                self?.endGame()
                return
            }
            self?.extraLifeUseCount += 1
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
        synchronizeTimer()
    }

    /// Pauses rule-critical question and freeze timing without counting background duration.
    public func handleAppBackgrounded() {
        guard !isPracticeMode, !shouldPresentResultView, !sessionTimingPaused else { return }
        timerWasRunningBeforePause = timerIsRunning
        stopTimer()
        pauseFreezeIfNeeded()
        sessionTimingPaused = true
    }

    /// Resumes only the timing that was active before backgrounding.
    public func handleAppForegrounded() {
        guard sessionTimingPaused, !shouldPresentResultView else { return }
        sessionTimingPaused = false
        if isTimeFrozen {
            resumeFreezeIfNeeded()
        } else if timerWasRunningBeforePause {
            startTimer()
        }
        timerWasRunningBeforePause = false
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
        coinsEarnedThisSession = Self.saturatingAdd(coinsEarnedThisSession, amount)
        progressManager?.addCoins(amount)
    }

    private func awardCoinsForCorrectAnswer() {
        awardCoins(rules.economy.correctAnswerCoinReward)
    }

    // MARK: - Power-ups

    public func powerUpCost(for powerUp: PowerUp) -> Int {
        rules.powerUps.rule(for: powerUp)?.coinCost ?? powerUp.cost
    }

    public var extraLifeCoinCost: Int {
        rules.extraLife.coinCost
    }

    public func canUsePowerUp(_ powerUp: PowerUp) -> Bool {
        guard let manager = progressManager,
              let rule = rules.powerUps.rule(for: powerUp),
              rule.isEnabled,
              rule.allowedModes.contains(gameMode),
              !powerUpsUsedOnCurrentQuestion.contains(powerUp),
              powerUpUseCounts[powerUp, default: 0] < rule.maximumUsesPerSession else {
            return false
        }
        return manager.canFundPowerUp(powerUp)
    }

    public func useFiftyFifty() {
        guard canUsePowerUp(.fiftyFifty) else { return }
        guard questionNumber >= 0 else { return }
        guard let funding = progressManager?.consumePowerUp(.fiftyFifty) else { return }

        usedPowerUps.insert(.fiftyFifty)
        powerUpUseCounts[.fiftyFifty, default: 0] += 1
        powerUpsUsedOnCurrentQuestion.insert(.fiftyFifty)
        recordPowerUpFunding(funding)

        let currentAnswers = questionData[questionNumber].answers
        let wrongIndices = currentAnswers.enumerated()
            .filter { !$0.element.correct }
            .map { $0.offset }
            .shuffled(using: &randomNumberGenerator)

        let toHide = Array(wrongIndices.prefix(rules.powerUps.fiftyFiftyIncorrectAnswersRemoved))
        withAnimation {
            hiddenAnswerIndices = Set(toHide)
        }
    }

    public func useSkipQuestion() {
        guard canUsePowerUp(.skipQuestion) else { return }
        guard let funding = progressManager?.consumePowerUp(.skipQuestion) else { return }

        usedPowerUps.insert(.skipQuestion)
        powerUpUseCounts[.skipQuestion, default: 0] += 1
        powerUpsUsedOnCurrentQuestion.insert(.skipQuestion)
        recordPowerUpFunding(funding)
        stopTimer()
        updateRemainingTime()

        schedule(.skipQuestion, after: 0.3) {
            self.startTimer()
            withAnimation {
                self.goToNextQuestion()
            }
        }
    }

    public func useTimeFreeze() {
        guard canUsePowerUp(.timeFreeze) else { return }
        guard let funding = progressManager?.consumePowerUp(.timeFreeze) else { return }

        usedPowerUps.insert(.timeFreeze)
        powerUpUseCounts[.timeFreeze, default: 0] += 1
        powerUpsUsedOnCurrentQuestion.insert(.timeFreeze)
        recordPowerUpFunding(funding)
        isTimeFrozen = true
        stopTimer()
        freezeRemainingSeconds = rules.powerUps.timeFreezeDurationSeconds
        resumeFreezeIfNeeded()
    }

    // MARK: - Streak Shield

    /// Whether the streak shield can be used at the configured streak threshold.
    public func canUseStreakShield() -> Bool {
        correctAnswersInRow >= rules.powerUps.streakShieldMinimumStreak
            && !hasActiveStreakShield
            && canUsePowerUp(.streakShield)
    }

    /// Activates the streak shield, protecting the current streak from one wrong answer
    public func useStreakShield() {
        guard canUseStreakShield() else { return }
        guard let funding = progressManager?.consumePowerUp(.streakShield) else { return }

        usedPowerUps.insert(.streakShield)
        powerUpUseCounts[.streakShield, default: 0] += 1
        powerUpsUsedOnCurrentQuestion.insert(.streakShield)
        recordPowerUpFunding(funding)
        hasActiveStreakShield = true
    }

    private func recordPowerUpFunding(_ funding: PowerUpSpendResult) {
        lastPowerUpFunding = funding
        analytics?.logPowerUpUsed(
            type: funding.powerUp,
            fundingSource: funding.fundingSource,
            coinsSpent: funding.coinsSpent
        )
    }

    public func useExtraLifeWithCoins() -> Bool {
        guard rules.extraLife.allowsCoins,
              extraLifeUseCount < rules.extraLife.maximumUsesPerSession else { return false }
        let cost = rules.extraLife.coinCost
        guard progressManager?.spendCoins(cost) == true else { return false }

        extraLifeUseCount += 1
        analytics?.logExtraLifeUsed(method: .coins)
        hideRewardProposalView()  // Hide the reward view first
        incrementLives()  // This shows the life granted animation
        updateRemainingTime()
        startTimer()
        return true
    }

    private func resetPowerUpsForQuestion() {
        hiddenAnswerIndices = []
        powerUpsUsedOnCurrentQuestion = []
        if isTimeFrozen {
            isTimeFrozen = false
            cancelScheduledTask(.timeFreeze)
            freezeSegmentStartTime = nil
            freezeSegmentStartingRemaining = 0
            freezeRemainingSeconds = 0
        }
    }

    private func runStreakAchievedLogicIfNeeded() {
        if correctAnswersInRow == rules.solo.scoring.streakThreshold {
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
            responseTimeMs = Self.clampedMilliseconds(from: displayTime, to: clock.now)
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

    // MARK: - Deterministic Scheduling

    private func schedule(
        _ kind: ScheduledTaskKind,
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) {
        scheduledTasks[kind]?.task?.cancel()

        let registration = ScheduledTaskRegistration()
        scheduledTasks[kind] = registration

        let task = scheduler.schedule(after: delay) { [weak self, weak registration] in
            guard let self,
                  let registration,
                  self.scheduledTasks[kind] === registration else { return }
            operation()

            guard self.scheduledTasks[kind] === registration else { return }
            self.scheduledTasks.removeValue(forKey: kind)
        }
        registration.task = task
    }

    private func cancelScheduledTasks() {
        scheduledTasks.values.compactMap(\.task).forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }

    private func cancelScheduledTask(_ kind: ScheduledTaskKind) {
        scheduledTasks[kind]?.task?.cancel()
        scheduledTasks.removeValue(forKey: kind)
    }

    private func scheduleTimerTick(generation: UInt) {
        timerTask?.cancel()
        timerTask = scheduler.schedule(after: 1) { [weak self] in
            guard let self,
                  self.timerIsRunning,
                  self.timerGeneration == generation else { return }
            self.synchronizeTimer()
            if self.timerIsRunning, self.timerGeneration == generation {
                self.scheduleTimerTick(generation: generation)
            }
        }
    }

    private func synchronizeTimer(allowTimeout: Bool = true) {
        guard timerIsRunning, let startTime = timerSegmentStartTime else { return }
        let elapsed = max(0, clock.now.timeIntervalSince(startTime))
        let computedRemaining = max(0, timerSegmentStartingRemaining - elapsed)
        timerRemainingSeconds = min(timerRemainingSeconds, computedRemaining)
        timeRemaining = Int(ceil(max(0, timerRemainingSeconds - Self.timerPrecisionTolerance)))

        guard allowTimeout, timerRemainingSeconds <= Self.timerPrecisionTolerance else { return }
        timerRemainingSeconds = 0
        timeRemaining = 0
        timerIsRunning = false
        timerGeneration &+= 1
        timerSegmentStartTime = nil
        timerTask?.cancel()
        timerTask = nil
        handleTimerTimeoutIfNeeded()
    }

    private func handleTimerTimeoutIfNeeded() {
        // Prevent double life-loss when timeout and a tap arrive in the same turn.
        guard livesRemaining > 0, shouldAllowTap, !shouldPresentResultView else { return }
        shouldAllowTap = false
        reduceLivesRemaining()
        updateRemainingTime()
        haptics?.notification(.error)
        withAnimation {
            shouldShowWrongAnswerView = true
        }

        schedule(.wrongAnswerOverlay, after: 1.0) {
            withAnimation {
                self.shouldShowWrongAnswerView = false
            }
        }
    }

    private func pauseFreezeIfNeeded() {
        guard isTimeFrozen, let startTime = freezeSegmentStartTime else { return }
        let elapsed = max(0, clock.now.timeIntervalSince(startTime))
        let computedRemaining = max(0, freezeSegmentStartingRemaining - elapsed)
        freezeRemainingSeconds = min(freezeRemainingSeconds, computedRemaining)
        cancelScheduledTask(.timeFreeze)
        freezeSegmentStartTime = nil
    }

    private func resumeFreezeIfNeeded() {
        guard isTimeFrozen else { return }
        guard freezeRemainingSeconds > 0 else {
            isTimeFrozen = false
            startTimer()
            return
        }
        freezeSegmentStartTime = clock.now
        freezeSegmentStartingRemaining = freezeRemainingSeconds
        schedule(.timeFreeze, after: freezeRemainingSeconds) {
            guard self.isTimeFrozen else { return }
            self.isTimeFrozen = false
            self.freezeSegmentStartTime = nil
            self.freezeSegmentStartingRemaining = 0
            self.freezeRemainingSeconds = 0
            self.startTimer()
        }
    }

    private static func clampedMilliseconds(from start: Date, to end: Date) -> Int {
        let milliseconds = max(0, end.timeIntervalSince(start)) * 1_000
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int.max : Int.min
    }
}
