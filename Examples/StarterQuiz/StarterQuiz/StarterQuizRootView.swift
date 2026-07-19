import QuizEngineCore
import QuizEngineGame
import SwiftUI

struct StarterQuizRootView: View {
    @StateObject private var model = StarterQuizModel()
    @State private var showAchievements = false

    var body: some View {
        NavigationStack {
            Group {
                if let game = model.game {
                    StarterGameView(game: game) {
                        model.game = nil
                    }
                } else {
                    List {
                        Section("Categories") {
                            ForEach(model.variant.categories) { category in
                                Button {
                                    model.start(categoryID: category.id)
                                } label: {
                                    HStack {
                                        Image(systemName: category.iconName)
                                        Text(LocalizedStringKey(category.displayNameKey))
                                        Spacer()
                                        if !model.progressManager.isCategoryUnlocked(category.id) {
                                            Image(systemName: "lock.fill")
                                        }
                                    }
                                }
                                .disabled(!model.progressManager.isCategoryUnlocked(category.id))
                            }
                        }

                        Section("Progress") {
                            LabeledContent("Coins", value: "\(model.progressManager.coins)")
                            LabeledContent("Unlocked achievements", value: "\(model.progressManager.unlockedAchievementCount)")
                        }
                    }
                }
            }
            .navigationTitle("Starter Quiz")
            .toolbar {
                Button("Achievements") { showAchievements = true }
            }
            .alert("Content error", isPresented: Binding(
                get: { model.contentError != nil },
                set: { if !$0 { model.contentError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.contentError ?? "")
            }
            .sheet(isPresented: $showAchievements) {
                NavigationStack {
                    List(model.variant.achievements) { achievement in
                        HStack {
                            Image(systemName: achievement.iconName)
                            VStack(alignment: .leading) {
                                Text(LocalizedStringKey(achievement.nameKey))
                                Text(LocalizedStringKey(achievement.descriptionKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.progressManager.isAchievementUnlocked(achievement.id) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .navigationTitle("Achievements")
                    .toolbar { Button("Done") { showAchievements = false } }
                }
            }
        }
    }
}

private struct StarterGameView: View {
    @ObservedObject var game: QuizViewModel
    let exit: () -> Void

    var body: some View {
        Group {
            if game.shouldPresentResultView {
                VStack(spacing: 16) {
                    Text("Game complete").font(.title.bold())
                    Text("Score: \(game.score)")
                    Button("Back to categories", action: exit)
                        .buttonStyle(.borderedProminent)
                }
            } else if game.questionNumber >= 0, game.questionNumber < game.questionData.count {
                let question = game.questionData[game.questionNumber]
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Score: \(game.score)")
                        Spacer()
                        Text("Time: \(game.timeRemaining)")
                    }
                    Text(question.question).font(.title3.bold())
                    ForEach(Array(question.answers.enumerated()), id: \.offset) { _, answer in
                        Button(answer.text) {
                            guard game.shouldAllowTap else { return }
                            game.shouldAllowTap = false
                            answer.correct ? game.increaseScoreForCorrectAnswer() : game.reduceLivesRemaining()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!game.shouldAllowTap)
                    }
                    Spacer()
                }
                .padding()
                .onReceive(game.timer) { _ in
                    game.updateRemainingTimeAndHandleNavigationIfNeeded()
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Quiz")
    }
}
