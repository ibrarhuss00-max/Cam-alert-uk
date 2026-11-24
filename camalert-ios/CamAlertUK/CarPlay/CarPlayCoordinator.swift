import UIKit
import CarPlay
import MapKit
import Combine
import CamCore

/// Builds and drives everything shown on the car screen:
/// the map window (EngineMapViewController), the CarPlay map template with its buttons,
/// destination search, route choices, turn banners and the camera alerts.
final class CarPlayCoordinator: NSObject, CPMapTemplateDelegate, CPSearchTemplateDelegate {
    static let shared = CarPlayCoordinator()

    private let engine = NavigationEngine.shared
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private var session: CPNavigationSession?
    private var trip: CPTrip?
    private var bag = Set<AnyCancellable>()
    private var maneuverKey = ""

    private override init() {
        super.init()
    }

    // MARK: connect / disconnect

    func connect(_ controller: CPInterfaceController, window: CPWindow) {
        interfaceController = controller
        window.rootViewController = EngineMapViewController(engine: engine, style: .carPlay)

        let template = makeMapTemplate()
        mapTemplate = template
        controller.setRootTemplate(template, animated: false, completion: nil)

        bind()
        engine.start()
    }

    func disconnect() {
        bag.removeAll()
        session = nil
        trip = nil
        mapTemplate = nil
        interfaceController = nil
    }

    private func bind() {
        bag.removeAll()

        engine.alertSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.present(event) }
            .store(in: &bag)

        engine.guidanceSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushGuidance() }
            .store(in: &bag)

        engine.rerouteSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.maneuverKey = ""
                self?.pushGuidance()
            }
            .store(in: &bag)

        engine.arrivalSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.session?.finishTrip()
                self?.session = nil
                self?.trip = nil
            }
            .store(in: &bag)

        // If the trip is ended or cancelled from the iPhone, tidy up the car screen too.
        engine.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self = self else { return }
                if mode != .navigating, let s = self.session {
                    s.cancelTrip()
                    self.session = nil
                    self.trip = nil
                }
                if mode == .idle { self.mapTemplate?.hideTripPreviews() }
            }
            .store(in: &bag)
    }

    // MARK: map template

    private func makeMapTemplate() -> CPMapTemplate {
        let template = CPMapTemplate()
        template.mapDelegate = self
        template.guidanceBackgroundColor = .black
        template.tripEstimateStyle = .dark

        template.leadingNavigationBarButtons = [
            CPBarButton(title: "Search") { [weak self] _ in self?.showSearch() },
            CPBarButton(title: "Recent") { [weak self] _ in self?.showRecents() }
        ]

        let voice = CPMapButton { [weak self] button in
            guard let self = self else { return }
            self.engine.voiceEnabled.toggle()
            button.image = self.voiceImage()
        }
        voice.image = voiceImage()

        let tolls = CPMapButton { [weak self] button in
            guard let self = self else { return }
            self.engine.avoidTolls.toggle()
            button.image = self.tollImage()
        }
        tolls.image = tollImage()

        template.mapButtons = [voice, tolls]
        return template
    }

    private func voiceImage() -> UIImage? {
        UIImage(systemName: engine.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
    }

    /// Filled pound sign = "avoid tolls" is on (applies to the next route you plan).
    private func tollImage() -> UIImage? {
        UIImage(systemName: engine.avoidTolls ? "sterlingsign.circle.fill" : "sterlingsign.circle")
    }

    // MARK: search and recents

    private func showSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        interfaceController?.pushTemplate(search, animated: true, completion: nil)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        guard searchText.trimmingCharacters(in: .whitespaces).count >= 2 else {
            completionHandler([])
            return
        }
        engine.search(searchText) { [weak self] items in
            guard let self = self else {
                completionHandler([])
                return
            }
            completionHandler(items.prefix(12).map { self.listItem(for: $0) })
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        completionHandler()
        if let mapItem = item.userInfo as? MKMapItem {
            chooseDestination(mapItem)
        }
    }

    private func listItem(for mapItem: MKMapItem) -> CPListItem {
        let item = CPListItem(text: mapItem.name ?? "Place", detailText: mapItem.placemark.title)
        item.userInfo = mapItem
        return item
    }

    private func showRecents() {
        let items: [CPListItem] = engine.recents.map { place in
            let item = CPListItem(text: place.name, detailText: place.subtitle)
            item.handler = { [weak self] _, completion in
                completion()
                self?.chooseDestination(place.mapItem)
            }
            return item
        }
        let template = CPListTemplate(title: "Recent", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: route choice

    private func chooseDestination(_ destination: MKMapItem) {
        interfaceController?.popToRootTemplate(animated: true) { _, _ in }
        engine.plan(to: destination, waitForCameras: true) { [weak self] routes in
            self?.showPreview(destination: destination, routes: routes)
        }
    }

    private func showPreview(destination: MKMapItem, routes: [PlannedRoute]) {
        guard let template = mapTemplate, !routes.isEmpty, let loc = engine.location else { return }

        let choices: [CPRouteChoice] = routes.map { route in
            var info = [route.detailLine]
            if let tag = route.tags.first { info.insert(tag.capitalized, at: 0) }
            let choice = CPRouteChoice(summaryVariants: [route.summaryLine, Fmt.duration(route.travelTime)],
                                       additionalInformationVariants: info,
                                       selectionSummaryVariants: [route.cameraText])
            choice.userInfo = route
            return choice
        }

        let origin = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
        let newTrip = CPTrip(origin: origin, destination: destination, routeChoices: choices)
        newTrip.destinationNameVariants = [destination.name ?? "Destination"]
        trip = newTrip

        let text = CPTripPreviewTextConfiguration(startButtonTitle: "Go",
                                                  additionalRoutesButtonTitle: "Routes",
                                                  overviewButtonTitle: "Overview")
        template.showTripPreviews([newTrip], textConfiguration: text)
    }

    // MARK: CPMapTemplateDelegate

    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        if let route = routeChoice.userInfo as? PlannedRoute {
            engine.select(route: route)
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        guard let route = routeChoice.userInfo as? PlannedRoute else { return }
        mapTemplate.hideTripPreviews()
        engine.startNavigation(route: route)
        self.trip = trip
        session = mapTemplate.startNavigationSession(for: trip)
        maneuverKey = ""
        pushGuidance()
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        engine.stopNavigation()
    }

    // MARK: guidance banners

    private func pushGuidance() {
        guard let s = session else { return }
        let steps = engine.upcomingSteps(limit: 2)

        // Only rebuild the maneuver list when the turn actually changes.
        let key = steps.map { $0.instruction }.joined(separator: "|")
        if key != maneuverKey {
            maneuverKey = key
            s.upcomingManeuvers = steps.map { step -> CPManeuver in
                let m = CPManeuver()
                m.instructionVariants = [step.instruction]
                m.symbolImage = GuidanceIcon.image(for: step.instruction)
                m.initialTravelEstimates = estimates(distance: step.distance, speed: 15)
                return m
            }
        }
        if let first = s.upcomingManeuvers.first {
            s.updateEstimates(estimates(distance: engine.nextInstructionDistance, speed: 15), for: first)
        }
        if let t = trip, let template = mapTemplate {
            let overall = CPTravelEstimates(distanceRemaining: Measurement(value: engine.remainingDistance, unit: UnitLength.meters),
                                            timeRemaining: engine.remainingTime)
            template.update(overall, for: t, with: .default)
        }
    }

    private func estimates(distance: Double, speed: Double) -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: Measurement(value: distance, unit: UnitLength.meters),
                          timeRemaining: distance / speed)
    }

    // MARK: camera alerts

    private func present(_ event: AlertEvent) {
        guard let template = mapTemplate else { return }
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPNavigationAlert(titleVariants: [event.title],
                                      subtitleVariants: [event.subtitle.isEmpty ? "Check your speed" : event.subtitle],
                                      image: UIImage(systemName: "camera.fill"),
                                      primaryAction: action,
                                      secondaryAction: nil,
                                      duration: 8)
        if template.currentNavigationAlert != nil {
            template.dismissNavigationAlert(animated: false) { _ in
                template.present(navigationAlert: alert, animated: true)
            }
        } else {
            template.present(navigationAlert: alert, animated: true)
        }
    }
}
