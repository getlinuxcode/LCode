import SwiftUI

struct Fruit: Identifiable, Hashable {
    let id: Int
    let name: String
    let color: Color
    let calories: Int

    static let all: [Fruit] = [
        Fruit(id: 1, name: "Apple", color: .red, calories: 52),
        Fruit(id: 2, name: "Apricot", color: .orange, calories: 48),
        Fruit(id: 3, name: "Banana", color: .yellow, calories: 89),
        Fruit(id: 4, name: "Blueberry", color: .indigo, calories: 57),
        Fruit(id: 5, name: "Cherry", color: .red, calories: 63),
        Fruit(id: 6, name: "Fig", color: .purple, calories: 74),
        Fruit(id: 7, name: "Kiwi", color: .brown, calories: 61),
        Fruit(id: 8, name: "Lime", color: .green, calories: 30),
        Fruit(id: 9, name: "Mango", color: .orange, calories: 60),
        Fruit(id: 10, name: "Peach", color: .orange, calories: 39),
        Fruit(id: 11, name: "Pear", color: .green, calories: 57),
        Fruit(id: 12, name: "Plum", color: .purple, calories: 46),
        Fruit(id: 13, name: "Raspberry", color: .red, calories: 52),
        Fruit(id: 14, name: "Strawberry", color: .pink, calories: 32),
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
                Section("Seasonal fruits") {
                    ForEach(Fruit.all) { fruit in
                        NavigationLink(value: fruit) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(fruit.color)
                                    .frame(width: 28, height: 28)
                                Text(fruit.name)
                                Spacer()
                                if favorites.contains(fruit.id) {
                                    Text("Favorite")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("About") {
                        AboutView()
                    }
                    Button("Clear favorites", role: .destructive) {
                        favorites.removeAll()
                    }
                    .disabled(favorites.isEmpty)
                } footer: {
                    Text("\(favorites.count) favorite fruit(s).")
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
            Text("\(fruit.calories) kcal per 100 g")
                .foregroundStyle(.secondary)
            Button(isFavorite ? "Remove from favorites" : "Add to favorites") {
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
            Text("LCode demo app: the same source code runs in the LSim simulator on Linux and on a real iPhone.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("About")
    }
}
