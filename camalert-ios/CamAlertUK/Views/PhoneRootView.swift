import SwiftUI
import MapKit
import CamCore

struct MapControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EngineMapViewController {
        EngineMapViewController(engine: NavigationEngine.shared, style: .phone)
    }

    func updateUIViewController(_ uiViewController: EngineMapViewController, context: Context) {}
}

struct PhoneRootView: View {
    @ObservedObject private var engine = NavigationEngine.shared
    @AppStorage("acceptedTerms") private var accepted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapControllerView()
                .ignoresSafeArea()

            VStack(spacing: 8) {
                if engine.gpsDenied {
                    StatusPill(text: "Location is off. Turn it on in Settings > Privacy > Location Services.")
                } else if let status = engine.status {
                    StatusPill(text: status)
                }
                VStack(alignment: .leading, spacing: 10) {
                    switch engine.mode {
                    case .idle:
                        SearchPanel(engine: engine)
                    case .preview:
                        PreviewPanel(engine: engine)
                    case .navigating:
                        GuidancePanel(engine: engine)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(10)
        }
        .fullScreenCover(isPresented: Binding(get: { !accepted }, set: { _ in })) {
            DisclaimerView { accepted = true }
        }
        .onAppear { engine.start() }
    }
}

struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - Search

struct SearchPanel: View {
    @ObservedObject var engine: NavigationEngine
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Where to? Name, address or postcode", text: $query)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundColor(.secondary)
            }
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        if showSettings {
            Toggle("Voice alerts", isOn: $engine.voiceEnabled)
            Toggle("Avoid toll roads", isOn: $engine.avoidTolls)
            Toggle("Passenger mode (alert even below 10 mph)", isOn: $engine.passengerMode)
        }

        if !results.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button {
                            engine.plan(to: item)
                        } label: {
                            PlaceRow(title: item.name ?? "Place", subtitle: item.placemark.title ?? "")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        } else if query.isEmpty && !engine.recents.isEmpty {
            Text("Recent")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(engine.recents, id: \.name) { place in
                Button {
                    engine.plan(to: place.mapItem)
                } label: {
                    PlaceRow(title: place.name, subtitle: place.subtitle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        engine.search(text) { items in
            results = items
        }
    }
}

struct PlaceRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Route preview

struct PreviewPanel: View {
    @ObservedObject var engine: NavigationEngine

    var body: some View {
        Text(engine.destination?.name ?? "Destination")
            .font(.headline)

        ForEach(engine.routes) { route in
            RouteCard(route: route, selected: route.id == engine.selectedRouteID)
                .onTapGesture { engine.select(route: route) }
        }

        HStack(spacing: 10) {
            Button("Start") { engine.startNavigation() }
                .buttonStyle(.borderedProminent)
            Button("Demo drive") { engine.startDemo() }
                .buttonStyle(.bordered)
            Spacer()
            Button("Cancel", role: .cancel) { engine.cancel() }
        }
    }
}

struct RouteCard: View {
    let route: PlannedRoute
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Fmt.duration(route.travelTime)).font(.title3.bold())
                Text(Fmt.distance(route.distance)).foregroundColor(.secondary)
                Spacer()
                Label(route.cameraText, systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(route.camerasReady && route.cameras.isEmpty ? .green : .red)
            }
            if !route.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(route.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.18)))
                    }
                }
            }
            if !route.name.isEmpty {
                Text("via \(route.name)").font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1)
        )
    }
}

// MARK: - Guidance

struct GuidancePanel: View {
    @ObservedObject var engine: NavigationEngine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: GuidanceIcon.symbolName(for: engine.nextInstruction))
                .font(.system(size: 34, weight: .bold))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.distance(engine.nextInstructionDistance)).font(.title2.bold())
                Text(engine.nextInstruction).font(.subheadline)
            }
            Spacer()
        }

        HStack {
            Text("\(Fmt.duration(engine.remainingTime)) · \(Fmt.distance(engine.remainingDistance)) · arrive \(Fmt.arrivalTime(after: engine.remainingTime))")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            Button("End", role: .destructive) { engine.stopNavigation() }
                .buttonStyle(.bordered)
        }

        if engine.isDemo {
            Text("Demo drive: simulated position")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
        }
    }
}

// MARK: - First-run notice

struct DisclaimerView: View {
    let accept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 54))
                .foregroundColor(.red)
            Text("Cam Alert UK")
                .font(.largeTitle.bold())
            Text("Speed camera alerts and turn-by-turn directions for UK roads.")
                .font(.title3)
            VStack(alignment: .leading, spacing: 10) {
                Text("Camera locations come from OpenStreetMap volunteers. The map is often incomplete or out of date, and it has no mobile or temporary cameras.")
                Text("This is a driving aid, not a guarantee. Keep to the speed limit shown on road signs, follow the road rules, and stay in control of your vehicle at all times. You are responsible for how you drive.")
                Text("Directions come from Apple Maps. Real roads can differ from the map, so use your own judgement.")
            }
            .font(.callout)
            Spacer()
            Button(action: accept) {
                Text("I understand")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
