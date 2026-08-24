import SwiftUI
import SwiftData
import AudioToolbox

/// "Where was this taken?" — a photo from the library and four country
/// choices. Five rounds per game.
struct QuizView: View {
    let albums: [Album]
    @Environment(\.dismiss) private var dismiss

    private static let roundCount = 5

    @State private var rounds: [(item: MediaItem, answer: String, options: [String])] = []
    @State private var current = 0
    @State private var score = 0
    @State private var picked: String?
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                if finished {
                    resultView
                } else if rounds.indices.contains(current) {
                    roundView(rounds[current])
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text("Where was this?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !finished, !rounds.isEmpty {
                        Text("Round \(current + 1)/\(Self.roundCount) · Score \(score)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
            .onAppear { startGame() }
        }
    }

    private func roundView(_ round: (item: MediaItem, answer: String, options: [String])) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(maxWidth: 700, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                ForEach(round.options, id: \.self) { option in
                    Button {
                        guard picked == nil else { return }
                        picked = option
                        if option == round.answer { score += 1 }
                        if UserDefaults.standard.bool(forKey: "quizSounds") {
                            AudioServicesPlaySystemSound(option == round.answer ? 1054 : 1053)
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_100_000_000)
                            nextRound()
                        }
                    } label: {
                        HStack {
                            Text(option).font(.headline)
                            Spacer()
                            if picked != nil {
                                if option == round.answer {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if option == picked {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(buttonBackground(option: option, answer: round.answer),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .task(id: round.item.driveId) {
            image = nil
            image = try? await MediaCache.shared.thumbnail(for: (round.item.driveId, round.item.name), maxPixel: 900)
        }
    }

    private func buttonBackground(option: String, answer: String) -> some ShapeStyle {
        guard picked != nil else { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        if option == answer { return AnyShapeStyle(.green.opacity(0.25)) }
        if option == picked { return AnyShapeStyle(.red.opacity(0.25)) }
        return AnyShapeStyle(.quaternary.opacity(0.35))
    }

    private var resultView: some View {
        VStack(spacing: 14) {
            Text(score == Self.roundCount ? "🏆" : score >= 3 ? "🎉" : "🧭")
                .font(.system(size: 80))
            Text("\(score) out of \(Self.roundCount)")
                .font(.largeTitle.bold())
            Text("Best: \(UserDefaults.standard.integer(forKey: "quizBestScore")) · Games: \(UserDefaults.standard.integer(forKey: "quizGamesPlayed"))")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(score == Self.roundCount
                 ? "Perfect — a true globetrotter!"
                 : score >= 3 ? "Nice — you know your travels." : "Time for a World Tour refresher…")
                .foregroundStyle(.secondary)
            Button {
                startGame()
            } label: {
                Label("Play Again", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)

            if let lastAnswer = rounds.last?.answer,
               let album = albums.first(where: { $0.name == lastAnswer }) {
                Button {
                    TourController.shared.focusAlbumId = album.driveId
                    dismiss()
                } label: {
                    Label("Reveal Last Answer on Map", systemImage: "globe.europe.africa")
                }
                .padding(.top, 4)
            }

            Toggle("Sound effects", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "quizSounds") },
                set: { UserDefaults.standard.set($0, forKey: "quizSounds") }
            ))
            .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startGame() {
        let eligible = albums.filter { $0.items.contains { !$0.isVideo && !$0.isHidden } }
        let countryNames = albums.map(\.name)
        guard eligible.count >= 2, countryNames.count >= 4 else { return }
        var built: [(MediaItem, String, [String])] = []
        for _ in 0..<Self.roundCount {
            guard let album = eligible.randomElement(),
                  let item = album.items.filter({ !$0.isVideo && !$0.isHidden }).randomElement() else { continue }
            var options = Set([album.name])
            while options.count < min(4, countryNames.count) {
                if let other = countryNames.randomElement() { options.insert(other) }
            }
            built.append((item, album.name, options.shuffled()))
        }
        rounds = built
        current = 0
        score = 0
        picked = nil
        finished = false
    }

    private func nextRound() {
        picked = nil
        if current + 1 < rounds.count {
            current += 1
        } else {
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: "quizGamesPlayed") + 1, forKey: "quizGamesPlayed")
            if score > defaults.integer(forKey: "quizBestScore") {
                defaults.set(score, forKey: "quizBestScore")
            }
            finished = true
        }
    }
}
