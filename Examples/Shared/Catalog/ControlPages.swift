import Foundation
import SwiftUI

// Pages de calibration des contrôles : chaque contrôle seul dans ses états, puis un formulaire réaliste.
// Repères `.calibrate` sur chaque contrôle (cadres SwiftUI), couches et captures relevées sur iPhone.

enum ControlCatalog {
    static var pages: [CatalogPage] {
        [
            CatalogPage(id: "control.toggle") { AnyView(TogglePage()) },
            CatalogPage(id: "control.slider") { AnyView(SliderPage()) },
            CatalogPage(id: "control.stepper") { AnyView(StepperPage()) },
            CatalogPage(id: "control.picker") { AnyView(PickerPage()) },
            CatalogPage(id: "control.pickermenu") { AnyView(MenuPickerPage()) },
            CatalogPage(id: "control.progress") { AnyView(ProgressPage()) },
            CatalogPage(id: "control.textfield") { AnyView(TextFieldPage()) },
            CatalogPage(id: "control.form") { AnyView(FormPage()) },
            CatalogPage(id: "control.alert") { AnyView(AlertPage()) },
        ]
    }
}

struct TogglePage: View {
    @State private var off = false
    @State private var on = true
    var body: some View {
        VStack(spacing: 20) {
            PageTitle(text: "Toggle")
            Toggle("Désactivé", isOn: $off).calibrate("toggle.off")
            Toggle("Activé", isOn: $on).calibrate("toggle.on")
            Toggle("Teinté", isOn: $on).tint(.green).calibrate("toggle.tinted")
            Toggle("Inactif", isOn: $on).disabled(true).calibrate("toggle.disabled")
            Toggle(isOn: $on) { EmptyView() }.labelsHidden().calibrate("toggle.bare")
        }
        .padding(.horizontal, 20)
    }
}

struct SliderPage: View {
    @State private var zero = 0.0
    @State private var half = 0.5
    @State private var full = 1.0
    var body: some View {
        VStack(spacing: 24) {
            PageTitle(text: "Slider")
            Slider(value: $zero).calibrate("slider.0")
            Slider(value: $half).calibrate("slider.50")
            Slider(value: $full).calibrate("slider.100")
            Slider(value: $half).tint(.orange).calibrate("slider.tinted")
            Slider(value: $half) { Text("Volume") } minimumValueLabel: { Image(systemName: "speaker") }
                maximumValueLabel: { Image(systemName: "speaker.wave.3") }
                .calibrate("slider.labels")
        }
        .padding(.horizontal, 20)
    }
}

struct StepperPage: View {
    @State private var value = 3
    var body: some View {
        VStack(spacing: 20) {
            PageTitle(text: "Stepper")
            Stepper("Quantité : \(value)", value: $value, in: 0...10).calibrate("stepper.value")
            Stepper("Minimum", value: .constant(0), in: 0...10).calibrate("stepper.min")
            Stepper(value: $value) { EmptyView() }.labelsHidden().calibrate("stepper.bare")
        }
        .padding(.horizontal, 20)
    }
}

struct PickerPage: View {
    @State private var three = 0
    @State private var two = 0
    var body: some View {
        VStack(spacing: 24) {
            PageTitle(text: "Picker")
            Picker("Vue", selection: $three) {
                Text("Jour").tag(0)
                Text("Semaine").tag(1)
                Text("Mois").tag(2)
            }
            .pickerStyle(.segmented)
            .calibrate("picker.segmented3")
            Picker("Choix", selection: $two) {
                Text("Un").tag(0)
                Text("Deux").tag(1)
            }
            .pickerStyle(.segmented)
            .calibrate("picker.segmented2")
        }
        .padding(.horizontal, 20)
    }
}

struct MenuPickerPage: View {
    @State private var choice = 1
    var body: some View {
        VStack(spacing: 24) {
            PageTitle(text: "Picker menu")
            HStack {
                Text("Menu")
                Spacer()
                Picker("Menu", selection: $choice) {
                    Text("Jour").tag(0)
                    Text("Semaine").tag(1)
                    Text("Mois").tag(2)
                }
                .pickerStyle(.menu)
                .calibrate("picker.menu")
            }
        }
        .padding(.horizontal, 20)
    }
}

struct ProgressPage: View {
    var body: some View {
        VStack(spacing: 24) {
            PageTitle(text: "ProgressView")
            ProgressView(value: 0.3).calibrate("progress.30")
            ProgressView(value: 0.75).tint(.green).calibrate("progress.tinted")
            ProgressView().calibrate("progress.spinner")
            ProgressView("Chargement…").calibrate("progress.label")
        }
        .padding(.horizontal, 20)
    }
}

struct TextFieldPage: View {
    @State private var empty = ""
    @State private var filled = "Bonjour"
    var body: some View {
        VStack(spacing: 20) {
            PageTitle(text: "TextField")
            TextField("Nom", text: $empty).calibrate("textfield.plain")
            TextField("Nom", text: $empty).textFieldStyle(.roundedBorder).calibrate("textfield.rounded")
            TextField("Nom", text: $filled).textFieldStyle(.roundedBorder).calibrate("textfield.filled")
            SecureField("Mot de passe", text: $empty).textFieldStyle(.roundedBorder).calibrate("textfield.secure")
        }
        .padding(.horizontal, 20)
    }
}

struct FormPage: View {
    @State private var on = true
    @State private var choice = 1
    @State private var count = 2
    @State private var level = 0.4
    @State private var name = ""
    var body: some View {
        Form {
            Section("Réglages") {
                Toggle("Notifications", isOn: $on).calibrate("form.toggle")
                Picker("Affichage", selection: $choice) {
                    Text("Jour").tag(0); Text("Semaine").tag(1)
                }
                .calibrate("form.picker")
                Stepper("Copies : \(count)", value: $count).calibrate("form.stepper")
            }
            Section("Détails") {
                Slider(value: $level).calibrate("form.slider")
                TextField("Nom", text: $name).calibrate("form.textfield")
            }
        }
    }
}

struct AlertPage: View {
    var body: some View {
        Color.clear
            .alert("Supprimer la photo ?", isPresented: .constant(true)) {
                Button("Annuler", role: .cancel) {}
                Button("Supprimer", role: .destructive) {}
            } message: {
                Text("Cette action est définitive.")
            }
    }
}
