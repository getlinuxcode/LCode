import SwiftUI

@main
struct CounterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var count = 0
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Counter")
                .font(.largeTitle)
                .bold()

            Text("\(count)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundStyle(count < 0 ? .red : .primary)

            HStack(spacing: 12) {
                Button("−") { count -= 1 }
                    .buttonStyle(.bordered)
                Button("Reset") { count = 0 }
                    .disabled(count == 0)
                Button("+") { count += 1 }
                    .buttonStyle(.borderedProminent)
            }

            Button(showDetails ? "Hide details" : "Show details") {
                showDetails.toggle()
            }

            if showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    Text("This text is rendered by LSimUI, a SwiftUI reimplementation that runs natively on Linux.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
    }
}
