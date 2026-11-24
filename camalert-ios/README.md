# Cam Alert UK for iPhone and CarPlay

A native iPhone app with a CarPlay screen. It does turn-by-turn directions (Apple Maps routes, with avoid-tolls) and warns you about speed cameras by voice and on screen, on the phone and on the car display.

It is the native version of the web app: same alert stages (half a mile, quarter mile, now), same "is it ahead of me?" logic, same route chooser that counts cameras on each route.

## Read this first: what you need

| To do this | You need |
|---|---|
| Build and run on your iPhone | A Mac with Xcode 15 or later. Xcode can't be run on Windows. A free Apple ID is enough, but the app expires after 7 days. |
| Try CarPlay on the Mac (simulator) | The same Mac. No Apple approval needed. |
| Use it in your real car | The paid Apple Developer Program (about £79/year) **and** Apple approving a CarPlay **Navigation** entitlement for your app. Apple decides; it can take weeks and can be refused. |

Until Apple approves the entitlement, the app works fully on the phone and in the CarPlay simulator, but it will not appear on a real car screen. That is Apple's rule, not something the code can get around.

If you don't have a Mac, rent one by the hour (for example MacinCloud) or borrow one. This project was written without being able to compile Swift, so expect to fix a small thing or two on the first build (see "First build" below).

## Set up (about 10 minutes)

1. Install XcodeGen: `brew install xcodegen`
2. In this folder run: `xcodegen generate`, then open `CamAlertUK.xcodeproj`.
3. Click the project, then the **CamAlertUK** target, then **Signing & Capabilities**. Choose your Team. If the bundle ID `com.ibrar.camalertuk` is taken, change it in `project.yml` and run `xcodegen generate` again.
4. Plug in your iPhone, pick it as the run destination, press Run. On the phone, trust the developer under Settings > General > VPN & Device Management.
5. Allow location, then choose **Always** when iOS asks (this keeps alerts working with the screen locked).

No XcodeGen? Make a new iOS App in Xcode (SwiftUI, name CamAlertUK), delete its starter files, drag in the `CamAlertUK` folder, add `Packages/CamCore` with File > Add Package Dependencies > Add Local, and set Info.plist File in Build Settings to `CamAlertUK/App/Info.plist`.

## Try it without driving

* On the phone: search for a place, tap a route, tap **Demo drive**. A simulated car drives the route at about 50 mph, so you can hear and see the alerts.
* CarPlay simulator: run on an iPhone **simulator**, then in the Simulator menu choose I/O > External Displays > CarPlay. Open Cam Alert UK on the CarPlay screen, tap Search, pick a place, choose a route, tap Go. Use the phone's Demo drive or Features > Location > Freeway Drive to move the car.

## Getting it on a real car screen

1. Join the Apple Developer Program (the Account Holder must do the request).
2. Request the entitlement at https://developer.apple.com/contact/carplay. Choose the **Navigation** category and agree to the CarPlay Entitlement Addendum. Apple's page "Requesting CarPlay entitlements" has the current steps. Suggested wording:

   > Cam Alert UK is a turn-by-turn navigation app for UK drivers. It plans routes with MapKit, gives spoken and on-screen directions on the CarPlay map window using CPMapTemplate, CPNavigationSession and CPTrip, and warns of fixed speed cameras (OpenStreetMap data) along the route and ahead of the vehicle. It supports destination search, route alternatives with toll avoidance, rerouting, and hands-free voice prompts.

3. When Apple grants it, add the CarPlay Navigation capability to your App ID, let Xcode refresh the signing profile, then in `project.yml` change the line `"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]": ""` to `CamAlertUK/App/CamAlertUK.entitlements` and run `xcodegen generate`. (Before approval that line is empty so the app still installs on your phone. With the entitlement in the build and no approval, Xcode refuses to sign.)
4. Run on your iPhone, plug into the car (or connect wirelessly). The app shows up on the CarPlay home screen.

Apple also requires navigation apps to be primarily for navigation. This one is, because it has full directions, but an app that only played camera warnings would not qualify.

## How it works

* **Camera data:** OpenStreetMap, fetched from the public Overpass servers in about 20 km squares and cached on the phone for 7 days. Old data is used if you're offline. It covers fixed and average-speed cameras only. It has no mobile or temporary cameras, and OSM is not complete.
* **Alerts:** with a route, a camera counts if it is within 25 m of the route line, and alerts use distance along the route. Off route, a camera counts if it is within 50 degrees of your heading and not too far to the side. Voice at half a mile, a quarter mile, and now; "Slow down" if you're over the camera's limit. Below 10 mph it stays quiet unless **Passenger mode** is on.
* **Directions:** Apple Maps (MKDirections). Avoid tolls is a real route preference, so the M6 Toll can be avoided. Each route shows its camera count, FASTEST, FEWEST CAMERAS and TOLL tags.
* **CarPlay:** the car shows our own map with camera pins, a speed and next-camera panel, and camera alerts as CarPlay banners. Buttons: Search, Recent, voice on/off, avoid tolls.
* **Audio:** speech plays through the car speakers and ducks your music.

## Known limits

* Rerouting on CarPlay updates the turn banners and the map, but CarPlay's own trip card keeps showing the original estimate.
* CarPlay Dashboard and instrument-cluster screens are not built.
* CarPlay may limit typing while the car is moving, with voice dictation as the usual way to search. The Recent list is the quick way to start a trip.
* Camera alerts shown as CarPlay banners may be limited by CarPlay when no trip is active. The on-map panel and the voice alert always run.
* If you publish this to the App Store, Apple's developer agreement requires a notice in your end-user licence for real-time navigation apps. This project is set up for personal use.

## First build

The code has been syntax-checked and the alert logic has been checked against the unit-test scenarios, but it has not been compiled with Xcode. If Xcode shows an error, copy the message into a chat with Claude and it can be fixed quickly.

To run the logic tests on a Mac without any simulator: `cd Packages/CamCore && swift test`.

## What's where

* `Packages/CamCore`: the alert brain (maths, camera parsing, route matching, staged alerts) and its tests. Pure Swift.
* `CamAlertUK/Services`: GPS, speech, camera download/cache, route planning, and `NavigationEngine` (the one object both screens share).
* `CamAlertUK/Views`: the map controller (used on phone and car) and the SwiftUI phone screens.
* `CamAlertUK/CarPlay`: the CarPlay scene and `CarPlayCoordinator` (templates, search, route choice, banners, alerts).
* `CamAlertUK/App`: app entry, `Info.plist`, entitlements.
