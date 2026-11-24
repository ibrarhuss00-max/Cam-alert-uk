import UIKit
import MapKit
import Combine
import CamCore

final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: SpeedCamera

    init(_ camera: SpeedCamera) {
        self.camera = camera
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: camera.coord.lat, longitude: camera.coord.lon)
    }

    var title: String? {
        let base = camera.kind == .average ? "Average speed camera" : "Speed camera"
        if let limit = camera.limitMph { return "\(base) · \(limit) mph" }
        return base
    }
}

/// The map. The same controller draws the iPhone screen and the CarPlay window; it
/// watches the engine and redraws cameras, routes, and the speed/camera HUD.
final class EngineMapViewController: UIViewController, MKMapViewDelegate {
    enum Style {
        case phone
        case carPlay
    }

    private let engine: NavigationEngine
    private let style: Style
    private let mapView = MKMapView()
    private let hud = HUDView()
    private var bag = Set<AnyCancellable>()
    private var annotations: [Int64: CameraAnnotation] = [:]
    private var overlayRoutes: [MKPolyline: UUID] = [:]
    private var lastFitKey: Set<UUID> = []

    init(engine: NavigationEngine, style: Style) {
        self.engine = engine
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        if style == .carPlay {
            mapView.pointOfInterestFilter = .excludingAll
        }
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "cam")
        view.addSubview(mapView)

        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        let guide = view.safeAreaLayoutGuide
        var constraints = [
            hud.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12)
        ]
        switch style {
        case .phone:
            constraints.append(hud.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8))
        case .carPlay:
            constraints.append(hud.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)

        bind()
        applyTracking(engine.mode)
    }

    // MARK: binding to the engine

    private func bind() {
        engine.$speedMph
            .combineLatest(engine.$nextCamera, engine.$lastAlert)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speed, next, alert in
                self?.hud.update(speedMph: speed, next: next, alert: alert)
            }
            .store(in: &bag)

        engine.$nearbyCameras
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cams in self?.syncCameras(cams) }
            .store(in: &bag)

        engine.$routes
            .combineLatest(engine.$selectedRouteID, engine.$mode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routes, selected, mode in
                self?.syncRoutes(routes, selected: selected, mode: mode)
            }
            .store(in: &bag)

        engine.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.applyTracking(mode) }
            .store(in: &bag)
    }

    private func applyTracking(_ mode: NavigationEngine.Mode) {
        switch (mode, style) {
        case (.preview, _):
            mapView.setUserTrackingMode(.none, animated: false)
        case (.navigating, _), (.idle, .carPlay):
            mapView.setUserTrackingMode(.followWithHeading, animated: true)
        case (.idle, .phone):
            mapView.setUserTrackingMode(.follow, animated: true)
        }
    }

    private func syncCameras(_ cams: [SpeedCamera]) {
        let ids = Set(cams.map { $0.id })
        let gone = annotations.filter { !ids.contains($0.key) }
        if !gone.isEmpty {
            mapView.removeAnnotations(Array(gone.values))
            for key in gone.keys { annotations[key] = nil }
        }
        var added: [CameraAnnotation] = []
        for cam in cams where annotations[cam.id] == nil {
            let a = CameraAnnotation(cam)
            annotations[cam.id] = a
            added.append(a)
        }
        if !added.isEmpty { mapView.addAnnotations(added) }
    }

    private func syncRoutes(_ routes: [PlannedRoute], selected: UUID?, mode: NavigationEngine.Mode) {
        mapView.removeOverlays(mapView.overlays)
        overlayRoutes.removeAll()

        let visible = mode == .navigating ? routes.filter { $0.id == selected } : routes
        // Unselected routes first so the selected one is drawn on top.
        let ordered = visible.sorted { $0.id != selected && $1.id == selected }
        for r in ordered {
            overlayRoutes[r.polyline] = r.id
            mapView.addOverlay(r.polyline, level: .aboveRoads)
        }

        let key = Set(routes.map { $0.id })
        if mode == .preview, !routes.isEmpty, key != lastFitKey {
            lastFitKey = key
            var rect = MKMapRect.null
            for r in routes { rect = rect.union(r.polyline.boundingMapRect) }
            let bottom: CGFloat = style == .phone ? 380 : 90
            mapView.setVisibleMapRect(rect,
                                      edgePadding: UIEdgeInsets(top: 130, left: 40, bottom: bottom, right: 40),
                                      animated: true)
        }
        if routes.isEmpty { lastFitKey = [] }
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        let selected = overlayRoutes[line] == engine.selectedRouteID
        renderer.strokeColor = selected ? UIColor.systemBlue : UIColor.systemGray.withAlphaComponent(0.8)
        renderer.lineWidth = selected ? 8 : 6
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is CameraAnnotation else { return nil }
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "cam", for: annotation) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "cam")
        view.markerTintColor = .systemRed
        view.glyphImage = UIImage(systemName: "camera.fill")
        view.clusteringIdentifier = "cam"
        view.displayPriority = .required
        view.canShowCallout = (style == .phone)
        return view
    }
}

// MARK: - HUD

/// Speed, next camera and the alert banner, drawn on top of the map.
final class HUDView: UIView {
    private let alertBox = UIView()
    private let alertTitle = UILabel()
    private let alertSub = UILabel()

    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let speedLabel = UILabel()
    private let limitBadge = UIView()
    private let limitLabel = UILabel()
    private let cameraBox = UIStackView()
    private let cameraTitle = UILabel()
    private let cameraSub = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        // Alert banner
        alertTitle.font = .systemFont(ofSize: 20, weight: .bold)
        alertTitle.textColor = .white
        alertSub.font = .systemFont(ofSize: 15, weight: .semibold)
        alertSub.textColor = .white
        let alertStack = UIStackView(arrangedSubviews: [alertTitle, alertSub])
        alertStack.axis = .vertical
        alertStack.spacing = 2
        alertStack.translatesAutoresizingMaskIntoConstraints = false
        alertBox.addSubview(alertStack)
        NSLayoutConstraint.activate([
            alertStack.topAnchor.constraint(equalTo: alertBox.topAnchor, constant: 10),
            alertStack.bottomAnchor.constraint(equalTo: alertBox.bottomAnchor, constant: -10),
            alertStack.leadingAnchor.constraint(equalTo: alertBox.leadingAnchor, constant: 14),
            alertStack.trailingAnchor.constraint(equalTo: alertBox.trailingAnchor, constant: -14)
        ])
        alertBox.layer.cornerRadius = 14
        alertBox.clipsToBounds = true
        alertBox.isHidden = true

        // Speed
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        speedLabel.textColor = .white
        speedLabel.text = "0"
        let unit = UILabel()
        unit.text = "mph"
        unit.font = .systemFont(ofSize: 12, weight: .semibold)
        unit.textColor = .lightGray
        unit.textAlignment = .center
        let speedStack = UIStackView(arrangedSubviews: [speedLabel, unit])
        speedStack.axis = .vertical
        speedStack.alignment = .center

        // Limit badge
        limitBadge.backgroundColor = .white
        limitBadge.layer.cornerRadius = 22
        limitBadge.layer.borderWidth = 4
        limitBadge.layer.borderColor = UIColor.systemRed.cgColor
        limitBadge.translatesAutoresizingMaskIntoConstraints = false
        limitLabel.font = .systemFont(ofSize: 18, weight: .heavy)
        limitLabel.textColor = .black
        limitLabel.textAlignment = .center
        limitLabel.translatesAutoresizingMaskIntoConstraints = false
        limitBadge.addSubview(limitLabel)
        NSLayoutConstraint.activate([
            limitBadge.widthAnchor.constraint(equalToConstant: 44),
            limitBadge.heightAnchor.constraint(equalToConstant: 44),
            limitLabel.centerXAnchor.constraint(equalTo: limitBadge.centerXAnchor),
            limitLabel.centerYAnchor.constraint(equalTo: limitBadge.centerYAnchor)
        ])
        limitBadge.isHidden = true

        // Next camera
        cameraTitle.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        cameraTitle.textColor = .white
        cameraSub.font = .systemFont(ofSize: 12, weight: .semibold)
        cameraSub.textColor = .lightGray
        cameraBox.axis = .vertical
        cameraBox.addArrangedSubview(cameraTitle)
        cameraBox.addArrangedSubview(cameraSub)
        cameraBox.isHidden = true

        let row = UIStackView(arrangedSubviews: [speedStack, limitBadge, cameraBox])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -14)
        ])
        card.layer.cornerRadius = 16
        card.clipsToBounds = true

        let root = UIStackView(arrangedSubviews: [alertBox, card])
        root.axis = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    func update(speedMph: Double, next: UpcomingCamera?, alert: AlertEvent?) {
        speedLabel.text = "\(Int(speedMph.rounded()))"

        if let n = next {
            cameraTitle.text = Fmt.distance(n.distance)
            cameraSub.text = n.camera.kind == .average ? "Average speed" : "Speed camera"
            if n.distance <= 402 {
                cameraTitle.textColor = .systemRed
            } else if n.distance <= 805 {
                cameraTitle.textColor = .systemOrange
            } else {
                cameraTitle.textColor = .white
            }
            cameraBox.isHidden = false
            if let limit = n.camera.limitMph {
                limitLabel.text = "\(limit)"
                limitBadge.isHidden = false
            } else {
                limitBadge.isHidden = true
            }
        } else {
            cameraBox.isHidden = true
            limitBadge.isHidden = true
        }

        if let a = alert {
            alertTitle.text = a.title
            alertSub.text = a.subtitle
            alertSub.isHidden = a.subtitle.isEmpty
            alertBox.backgroundColor = (a.overLimit || a.stage == .imminent) ? .systemRed : .systemOrange
            alertBox.isHidden = false
        } else {
            alertBox.isHidden = true
        }
    }
}
