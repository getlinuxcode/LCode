import SwiftUI

struct Fruit: Identifiable, Hashable {
    let id: Int
    let name: String
    let color: Color
    let calories: Int

    static let all: [Fruit] = [
        Fruit(id: 1, name: "Abricot", color: .orange, calories: 48),
        Fruit(id: 2, name: "Banane", color: .yellow, calories: 89),
        Fruit(id: 3, name: "Cerise", color: .red, calories: 63),
        Fruit(id: 4, name: "Citron vert", color: .green, calories: 30),
        Fruit(id: 5, name: "Figue", color: .purple, calories: 74),
        Fruit(id: 6, name: "Fraise", color: .pink, calories: 32),
        Fruit(id: 7, name: "Framboise", color: .red, calories: 52),
        Fruit(id: 8, name: "Kiwi", color: .brown, calories: 61),
        Fruit(id: 9, name: "Mangue", color: .orange, calories: 60),
        Fruit(id: 10, name: "Myrtille", color: .indigo, calories: 57),
        Fruit(id: 11, name: "Pêche", color: .orange, calories: 39),
        Fruit(id: 12, name: "Poire", color: .green, calories: 57),
        Fruit(id: 13, name: "Pomme", color: .red, calories: 52),
        Fruit(id: 14, name: "Prune", color: .purple, calories: 46),
    ]
}

@main
struct FruitsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var favorites: Set<Int> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Fruits de saison") {
                    ForEach(Fruit.all) { fruit in
                        NavigationLink(value: fruit) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(fruit.color)
                                    .frame(width: 28, height: 28)
                                Text(fruit.name)
                                Spacer()
                                if favorites.contains(fruit.id) {
                                    Text("Favori")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("À propos") {
                        AboutView()
                    }
                    Button("Effacer les favoris", role: .destructive) {
                        favorites.removeAll()
                    }
                    .disabled(favorites.isEmpty)
                } footer: {
                    Text("\(favorites.count) fruit(s) en favori.")
                }
            }
            .navigationTitle("Fruits")
            .navigationDestination(for: Fruit.self) { fruit in
                FruitDetail(fruit: fruit, isFavorite: Binding(
                    get: { favorites.contains(fruit.id) },
                    set: { if $0 { favorites.insert(fruit.id) } else { favorites.remove(fruit.id) } }
                ))
            }
        }
    }
}

struct FruitDetail: View {
    let fruit: Fruit
    @Binding var isFavorite: Bool

    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(fruit.color)
                .frame(width: 120, height: 120)
            Text(fruit.name)
                .font(.largeTitle)
                .bold()
            Text("\(fruit.calories) kcal pour 100 g")
                .foregroundStyle(.secondary)
            Button(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") {
                isFavorite.toggle()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle(fruit.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fruits")
                .font(.title2)
                .bold()
            Text("Application de démonstration de LCode : le même code source tourne dans le simulateur LSim sous Linux et sur un vrai iPhone.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("À propos")
    }
}
