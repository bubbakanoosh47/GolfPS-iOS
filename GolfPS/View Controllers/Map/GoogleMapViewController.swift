//
//  GoogleMapViewController.swift
//  Golf Ace
//
//  Created by Greg DeJong on 4/19/18.
//  Copyright © 2018 DeJong Development. All rights reserved.
//

import UIKit
import GoogleMaps
import Firebase
import AudioToolbox
import SCSDKBitmojiKit
import SCSDKLoginKit

extension GoogleMapViewController: LocationUpdateTimerDelegate, PlayerUpdateTimerDelegate {
    func updatePlayersNow() {
        updateOtherPlayerMarkers();
    }
    
    func updateLocationsNow() {
        if let cpl = currentPlayerLocation {
            
            var yardsBetweenLocations:Int = 25
            if let ppl = previousPlayerLocation {
                let newLoc:CLLocationCoordinate2D = cpl.coordinate
                let oldLoc:CLLocationCoordinate2D = ppl.coordinate
                yardsBetweenLocations = mapTools.distanceFrom(first: newLoc, second: oldLoc)
            }
            
            let cpgp = GeoPoint(latitude: cpl.coordinate.latitude,
                                longitude: cpl.coordinate.longitude)
            if (cpl != previousPlayerLocation && yardsBetweenLocations >= 25) {
                updatePlayerPosition(with: cpgp)
            }
            
            //update previous location on device regardless of distance
            AppSingleton.shared.me.location = cpgp
        }
    }
}

extension GoogleMapViewController: CLLocationManagerDelegate {
    internal func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        let isAuthorized:Bool = (status == .authorizedWhenInUse || status == .authorizedAlways)
        self.mapView.isMyLocationEnabled = isAuthorized
        mapView.settings.myLocationButton = isAuthorized
    }
    internal func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentPlayerLocation = locations.last
        
        if let cpl = currentPlayerLocation, currentPinMarker != nil {
            let yardsToPin:Int = mapTools.distanceFrom(first: cpl.coordinate, second: currentPinMarker.position)
            delegate.updateDistanceToPin(distance: yardsToPin)
            
            let suggestedClub:Club = clubTools.getClubSuggestion(ydsTo: yardsToPin)
            delegate.updateSelectedClub(club: suggestedClub)
            
            updateDistanceMarker()
            
            //if we are not being suggested the driver -> show the resulting suggested club arcs
            if (suggestedClub.number > 1) ||
                (yardsToPinFromTee != nil &&
                    yardsToPinFromMyLocation < yardsToPinFromTee! - 30 &&
                    yardsToTeeFromMyLocation + yardsToPinFromMyLocation < yardsToPinFromTee! + 75)  {
                updateRecommendedClubLines()
            } else {
                updateDrivingDistanceLines()
            }
        }
    }
}

class GoogleMapViewController: UIViewController, GMSMapViewDelegate {
    
    let mapTools:MapTools = MapTools();
    let clubTools:ClubTools = ClubTools();
    
    var db:Firestore { return AppSingleton.shared.db }
    var mapView:GMSMapView!
    var delegate:ViewUpdateDelegate!
    
    var locationTimer:LocationUpdateTimer!
    var otherPlayerTimer:PlayerUpdateTimer!
    
    let locationManager = CLLocationManager()
    var previousPlayerLocation:CLLocation? {
        if let gp = AppSingleton.shared.me.location {
            return CLLocation(latitude: gp.latitude, longitude: gp.longitude)
        }
        return nil
    }
    var currentPlayerLocation:CLLocation? {
        didSet {
            if let myMarker = myPlayerMarker, let location = currentPlayerLocation?.coordinate {
                myMarker.position = location
            } else if (currentPlayerLocation?.coordinate) != nil {
                createPlayerMarker()
            }
        }
    }
    
    private var currentHoleNumber:Int = 1;
    
    private var course:Course!
    private var currentHole:Hole!
    
    private var playerListener:ListenerRegistration? = nil
    
    private var otherPlayers:[Player] = [Player]()
    private var otherPlayerMarkers:[GMSMarker] = [GMSMarker]();
    private var myPlayerMarker:GMSMarker?
    private var myPlayerImage:UIImage? {
        didSet {
            self.createPlayerMarker()
        }
    }
    
    private var currentPinMarker:GMSMarker!
    private var currentTeeMarker:GMSMarker!
    private var currentBunkerMarkers:[GMSMarker] = [GMSMarker]();
    private var currentDistanceMarker:GMSMarker?
    
    private var isDraggingDistanceMarker:Bool = false
    
    private var drivingDistanceLines:[GMSPolyline] = [GMSPolyline]();
    private let drivingDistanceLineColors:[UIColor] = [UIColor.green, UIColor.yellow, UIColor.orange];
    
    private var suggestedDistanceLines:[GMSPolyline] = [GMSPolyline]();
    
    private var lineToMyLocation:GMSPolyline?
    private var lineToPin:GMSPolyline?
    
    private var yardsToPressFromLocation:Int {
        if let playerLocation = currentPlayerLocation, let pressLocation = currentDistanceMarker?.position {
            return mapTools.distanceFrom(first: playerLocation.coordinate, second: pressLocation)
        } else {
            return -1;
        }
    }
    private var yardsToPressFromTee:Int {
        if let pressLocation = currentDistanceMarker?.position {
            return mapTools.distanceFrom(first: currentTeeMarker.position, second: pressLocation)
        } else {
            return 1000;
        }
    }
    private var yardsToPinFromMyLocation:Int {
        var yardsToPin = 1000;
        if let playerLocation = currentPlayerLocation {
            yardsToPin = mapTools.distanceFrom(first: playerLocation.coordinate, second: currentPinMarker.position)
        } else {
            yardsToPin = mapTools.distanceFrom(first: currentTeeMarker.position, second: currentPinMarker.position)
        }
        return yardsToPin
    }
    private var yardsToTeeFromMyLocation:Int {
        var yardsToTee = 1000;
        if let playerCoord = currentPlayerLocation?.coordinate,
            let teeCoord = currentTeeMarker?.position {
            yardsToTee = mapTools.distanceFrom(first: playerCoord, second: teeCoord)
        }
        return yardsToTee
    }
    private var yardsToPinFromTee:Int? {
        if let tp = currentTeeMarker?.position, let pp = currentPinMarker?.position {
            return mapTools.distanceFrom(first: tp, second: pp)
        }
        return nil
    }
    
    private func getData(from url: URL, completion: @escaping (Data?, URLResponse?, Error?) -> ()) {
        URLSession.shared.dataTask(with: url, completionHandler: completion).resume()
    }
    
    // Wrapper for obtaining keys from keys.plist
    private func valueForAPIKey(keyname:String) -> String {
        // Get the file path for keys.plist
        if let filePath = Bundle.main.path(forResource: "ApiKeys", ofType: "plist") {
            // Put the keys in a dictionary
            if let plist = NSDictionary(contentsOfFile: filePath) {
                // Pull the value for the key
                if let value:String = plist.object(forKey: keyname) as? String {
                    return value
                }
            }
        }
        return "no-key-found"
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !SCSDKLoginClient.isUserLoggedIn {
            myPlayerImage = nil
        } else if myPlayerImage == nil {
            downloadBitmojiImage()
        }
        
        if (course != nil) {
            locationTimer.invalidate()
            locationTimer.delegate = self
            locationTimer.startNewTimer(interval: 15)
            
            listenToPlayerLocationsOnCourse(with: course.id)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerListener?.remove()
    }
    
    //first
    override func loadView() {
        super.loadView()
        GMSServices.provideAPIKey(valueForAPIKey(keyname: "GoogleMaps"))
        
        let camera = GMSCameraPosition.camera(withLatitude: 40, longitude: -75, zoom: 2.0)
        self.mapView = GMSMapView.map(withFrame: CGRect.zero, camera: camera)
        self.mapView.mapType = GMSMapViewType.satellite
        view = mapView
    }
    
    //second
    override func viewDidLoad() {
        super.viewDidLoad()

        self.mapView.delegate = self;
        
        locationManager.delegate = self;
        locationManager.requestWhenInUseAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest;
        locationManager.pausesLocationUpdatesAutomatically = false
        
        locationManager.startUpdatingLocation()
        
        locationTimer = LocationUpdateTimer()
        locationTimer.delegate = self
        
        otherPlayerTimer = PlayerUpdateTimer()
        otherPlayerTimer.delegate = self
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    private func downloadBitmojiImage() {
        SCSDKBitmojiClient.fetchAvatarURL { (avatarURL: String?, error: Error?) in
            if let urlString = avatarURL, let url = URL(string: urlString) {
                self.getData(from: url) { data, response, error in
                    guard let data = data, error == nil else { return }
                    DispatchQueue.main.async() {
                        self.myPlayerImage = UIImage(data: data)
                    }
                }
            }
        }
    }
    
    private func updatePlayerPosition(with location: GeoPoint) {
        let userId = AppSingleton.shared.me.id
        
        if AppSingleton.shared.me.shareLocation {
            if let id = self.course?.id {
                db.collection("players")
                    .document(userId)
                    .setData([
                        "course": id,
                        "location": location,
                        "updateTime": Date().iso8601
                        ], merge: true, completion: { (err) in
                            if let err = err {
                                print("Error updating location: \(err)")
                            } else {
                                print("Document successfully written!")
                            }
                    })
            } else {
                //no course so delete
                db.collection("players").document(userId).delete()
                locationTimer.invalidate()
            }
        } else {
            locationTimer.invalidate()
        }
    }
    
    private func listenToPlayerLocationsOnCourse(with id: String) {
        otherPlayerTimer.invalidate()
        otherPlayerTimer.delegate = self
        otherPlayerTimer.startNewTimer(interval: 15)
        
        playerListener?.remove();
        
        //grab course hole information
        playerListener = db.collection("players")
            .whereField("course", isEqualTo: id)
            .addSnapshotListener { querySnapshot, error in
                guard let documents = querySnapshot?.documents else {
                    print("Error fetching documents: \(error!)")
                    return
                }
                let location = documents.map { $0["location"]! }
                print("Current players on course: \(location)")
                
                self.otherPlayers.removeAll()
                for document in documents {
                    let otherPlayer = Player()
                    otherPlayer.id = document.documentID;
                    otherPlayer.location = document["location"] as? GeoPoint
                    otherPlayer.lastLocationUpdate = (document["updateTime"] as? String)?.dateFromISO8601
                    
                    if let imageStr = document["image"] as? String, imageStr != "" {
                        otherPlayer.avatarURL = URL(string: imageStr)
                    }
                    
                    if let timeSinceLastLocationUpdate = otherPlayer.lastLocationUpdate?.timeIntervalSinceNow,
                        timeSinceLastLocationUpdate > -14400 {
                        //only add player to array if they are within the correct time period
                        self.otherPlayers.append(otherPlayer)
                    }
                }
                
                self.updateOtherPlayerMarkers()
        }
    }
    
    public func setCourse(_ course : Course) {
        self.course = course;
        
        AppSingleton.shared.me.lastLocationUpdate = nil
        AppSingleton.shared.me.location = nil
        
        listenToPlayerLocationsOnCourse(with: course.id)
        
        locationTimer.invalidate()
        locationTimer.delegate = self
        locationTimer.startNewTimer(interval: 15)
        
        //reset current hole number
        currentHoleNumber = 1;
        
        //grab course hole information
        db.collection("courses").document(course.id)
            .collection("holes").getDocuments() { (querySnapshot, err) in
            if let err = err {
                print("Error getting documents: \(err)")
            } else {
                
                course.holeInfo.removeAll();
                
                for document in querySnapshot!.documents {
                    //get all the courses and add to a course list
                    let data = document.data();
                    
                    if let holeNumber:Int = Int(document.documentID) {
                        let hole:Hole = Hole(number: holeNumber)
                        
                        guard let pinObj = data["pin"] as? GeoPoint else {
                            print("Invalid hole structure!")
                            return;
                        }
                        
                        hole.pinLocation = pinObj;
                        if let bunkerObj = data["bunkers"] as? [GeoPoint] {
                            hole.bunkerLocations = bunkerObj;
                        } else if let bunkerObj = data["bunkers"] as? GeoPoint {
                            hole.bunkerLocations = [bunkerObj];
                        }
                        if let teeObj = data["tee"] as? [GeoPoint] {
                            hole.teeLocations = teeObj;
                        } else if let teeObj = data["tee"] as? GeoPoint {
                            hole.teeLocations = [teeObj]
                        }
                        if let dlObj = data["dogLeg"] as? GeoPoint {
                            hole.dogLegLocation = dlObj
                        }
                        
                        course.holeInfo.append(hole);
                    }
                }
                
                //add marker to show clubhouse and spectators?
//                self.moveCamera(to: course.bounds, orientToHole: false);
                self.goToHole()
            }
        }
    }
    
    public func goToHole(increment: Int = 0) {
        currentDistanceMarker?.map = nil;
        currentDistanceMarker = nil;
        lineToPin?.map = nil;
        lineToMyLocation?.map = nil;
        
        currentHoleNumber += increment;
        
        if (currentHoleNumber > course.holeInfo.count) {
            currentHoleNumber = 1;
        } else if currentHoleNumber <= 0 {
            currentHoleNumber = course.holeInfo.count
        }
        
        for hole in course.holeInfo {
            if (hole.holeNumber == currentHoleNumber) {
                currentHole = hole
                break;
            }
        }
        
        //tell main to update layout
        delegate.updateCurrentHole(num: currentHoleNumber);
        
        if (currentHole != nil) {
            updatePinMarker();
            updateTeeMarker();
            updateBunkerMarkers();
            
            moveCamera(to: currentHole.bounds, orientToHole: true);
            
            mapView.selectedMarker = currentPinMarker
            
            delegate.updateDistanceToPin(distance: yardsToPinFromMyLocation)
            
            let suggestedClub:Club = clubTools.getClubSuggestion(ydsTo: yardsToPinFromMyLocation)
            delegate.updateSelectedClub(club: suggestedClub)
            
            if (suggestedClub.number > 1) ||
                (yardsToPinFromTee != nil &&
                    yardsToPinFromMyLocation < yardsToPinFromTee! - 30 &&
                    yardsToTeeFromMyLocation + yardsToPinFromMyLocation < yardsToPinFromTee! + 75) { //30 yard buffer for bad tee position
                updateRecommendedClubLines()
            } else {
                updateDrivingDistanceLines();
            }
        }
    }
    
    private func moveCamera(to bounds:GMSCoordinateBounds, orientToHole:Bool) {
        let zoom:Float = mapTools.getBoundsZoomLevel(bounds: bounds, screenSize: view.frame)
        let center:CLLocationCoordinate2D = mapTools.getBoundsCenter(bounds);
        
        var bearing:Double = 0
        var viewingAngle:Double = 0
        if (orientToHole) {
            let teeLocation:GeoPoint = currentHole.teeLocations[0]
            let pinLocation:GeoPoint = currentHole.pinLocation!
            bearing = mapTools.calcBearing(start: teeLocation, finish: pinLocation) - 20
            viewingAngle = 45
        }
//        if let dlLocation = currentHole.dogLegLocation {
//            bearing = mapTools.calcBearing(start: teeLocation, finish: dlLocation)
//        }
        let newCameraView:GMSCameraPosition = GMSCameraPosition(target: center,
                                                                zoom: zoom,
                                                                bearing: bearing,
                                                                viewingAngle: viewingAngle)
        mapView.animate(to: newCameraView)
    }
    
    
    private func removeOldPlayerMarkers() {
        for marker in otherPlayerMarkers {
            if let markerUserData = marker.userData as? [String:Any],
                let markerPlayerId = markerUserData["userId"] as? String {
                
                var foundValidPlayer:Bool = false
                for player in self.otherPlayers {
                    if player.id == markerPlayerId {
                        if let updateDate = player.lastLocationUpdate {
                            let timeSinceLastLocationUpdate = updateDate.timeIntervalSinceNow
                            if (timeSinceLastLocationUpdate > -14400) { //remove after 4 hours
                                foundValidPlayer = true
                            }
                        }
                        break;
                    }
                }
                
                if (!foundValidPlayer) {
                    marker.map = nil
                }
            } else {
                marker.map = nil
            }
        }
    }
    
    private func updateOtherPlayerMarkers() {
        //remove old markers from the array
        removeOldPlayerMarkers()
        
        var newPlayerMarkers:[GMSMarker] = otherPlayerMarkers.filter { $0.map != nil }
        
        for player in self.otherPlayers {
            if let playerGeoPoint:GeoPoint = player.location,
                player.id != AppSingleton.shared.me.id {
                
                var markerTitle:String = "Golfer"
                
                var playerLocation = CLLocationCoordinate2D(latitude: playerGeoPoint.latitude, longitude: playerGeoPoint.longitude)
                if let courseSpec = course.spectation, !course.bounds.contains(playerLocation) {
                    //not within course bounds - lets put them as spectator
                    let randomDoubleLat = Double.random(in: -0.00001...0.00001)
                    let randomDoubleLng = Double.random(in: -0.00001...0.00001)
                    playerLocation = CLLocationCoordinate2D(latitude: courseSpec.latitude + randomDoubleLat,
                                                            longitude: courseSpec.longitude + randomDoubleLng)
                    markerTitle = "Spectator"
                }
                
                var userDataForMarker:[String:Any] = ["userId":player.id, "snap":false]
                var opMarker:GMSMarker! = nil
                
                //check for existing markers first
                //update icon if there was some sort of change to the player
                for marker in newPlayerMarkers {
                    if let data = marker.userData as? [String:Any], data["userId"] as? String == player.id {
                        opMarker = marker;
                        
                        marker.position = playerLocation
                        if let avatar = player.avatarURL, data["snap"] == nil || data["snap"] as? Bool == false {
                            //did not store icon on marker initially but now have player avatar url
                            //add snap icon
                            userDataForMarker["snap"] = true
                            self.getData(from: avatar) { data, response, error in
                                guard let data = data, error == nil else { return }
                                DispatchQueue.main.async() {
                                    opMarker.icon = UIImage(data: data)?.toNewSize(CGSize(width: 35, height: 35))
                                }
                            }
                        } else if data["snap"] as? Bool == true && player.avatarURL == nil {
                            //did store icon on marker initially but now have no player avatar url
                            //remove snap icon
                            userDataForMarker["snap"] = false
                            opMarker.icon =  #imageLiteral(resourceName: "player_marker").toNewSize(CGSize(width: 35, height: 35))
                        } else {
                            userDataForMarker["snap"] = data["snap"] as? Bool ?? false
                        }
                        break;
                    }
                }
            
                //if no existing marker was found for this player, then create a new one
                if opMarker == nil {
                    
                    opMarker = GMSMarker(position: playerLocation)
                    opMarker.icon =  #imageLiteral(resourceName: "player_marker").toNewSize(CGSize(width: 35, height: 35))
                    
                    //if player has specified avatar then add the icon to the marker
                    if let avatar = player.avatarURL {
                        userDataForMarker["snap"] = true
                        self.getData(from: avatar) { data, response, error in
                            guard let data = data, error == nil else { return }
                            DispatchQueue.main.async() {
                                opMarker.icon = UIImage(data: data)?.toNewSize(CGSize(width: 35, height: 35))
                            }
                        }
                    } else {
                        userDataForMarker["snap"] = false
                    }
                    
                    newPlayerMarkers.append(opMarker)
                }
                
                //attached the potentially updated user data to the marker
                opMarker.userData = userDataForMarker
                opMarker.title = markerTitle
                
                let timeSinceLastLocationUpdate = player.lastLocationUpdate?.timeIntervalSinceNow ?? 1000
                opMarker.opacity = timeSinceLastLocationUpdate < -60 ? 0.75 : 1
                opMarker.map = self.mapView
            } else {
                //no location data available for user or myself
            }
        }
        
        //update the array
        otherPlayerMarkers = newPlayerMarkers.filter { $0.map != nil }
    }
    
    private func createPlayerMarker() {
        if (myPlayerMarker != nil) {
            myPlayerMarker!.map = nil
        }
        if let loc:CLLocationCoordinate2D = currentPlayerLocation?.coordinate,
            let bitmojiImage = self.myPlayerImage {
            myPlayerMarker = GMSMarker(position: loc)
            myPlayerMarker!.title = "Me"
            myPlayerMarker!.icon = bitmojiImage.toNewSize(CGSize(width: 55, height: 55))
            myPlayerMarker!.userData = "ME";
            myPlayerMarker!.map = mapView;
        }
    }
    
    private func updateTeeMarker() {
        if (currentTeeMarker != nil) {
            currentTeeMarker.map = nil
        }
        let teeLocation:GeoPoint = currentHole.teeLocations[0];
        let loc:CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: teeLocation.latitude, longitude: teeLocation.longitude)
        
        currentTeeMarker = GMSMarker(position: loc)
        currentTeeMarker.title = "Tee #\(currentHoleNumber)"
        currentTeeMarker.icon = #imageLiteral(resourceName: "tee_marker").toNewSize(CGSize(width: 55, height: 55))
        currentTeeMarker.userData = "\(currentHoleNumber):T";
        currentTeeMarker.map = mapView;
    }
    private func updatePinMarker() {
        let pinLocation:GeoPoint = currentHole.pinLocation!
        let pinLoc:CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: pinLocation.latitude, longitude: pinLocation.longitude)
        
        let teeLocation:GeoPoint = currentHole.teeLocations[0]
        let teeLoc:CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: teeLocation.latitude, longitude: teeLocation.longitude)
        let yardsToPin:Int = mapTools.distanceFrom(first: pinLoc, second: teeLoc)
        
        if (currentPinMarker != nil) {
            currentPinMarker.map = nil
        }
        currentPinMarker = GMSMarker(position: pinLoc)
        currentPinMarker.title = "Pin #\(currentHoleNumber)"
        currentPinMarker.snippet = "\(yardsToPin) yds"
        currentPinMarker.icon = #imageLiteral(resourceName: "flag_marker").toNewSize(CGSize(width: 55, height: 55))
        currentPinMarker.userData = "\(currentHoleNumber):P";
        currentPinMarker.map = mapView;
    }
    private func updateBunkerMarkers() {
        for bunkerMarker in currentBunkerMarkers {
            bunkerMarker.map = nil
        }
        currentBunkerMarkers.removeAll()
        
        let bunkerLocationsForHole:[GeoPoint] = currentHole.bunkerLocations
        for (bunkerIndex,bunkerLocation) in bunkerLocationsForHole.enumerated() {
            let bunkerLoc = CLLocationCoordinate2D(latitude: bunkerLocation.latitude,
                                                   longitude: bunkerLocation.longitude)
            let teeLoc = CLLocationCoordinate2D(latitude: currentTeeMarker.position.latitude,
                                                longitude: currentTeeMarker.position.longitude)
            let yardsToBunker:Int = mapTools.distanceFrom(first: bunkerLoc, second: teeLoc)
            
            let bunkerMarker = GMSMarker(position: bunkerLoc)
            bunkerMarker.title = "Hazard"
            bunkerMarker.snippet = "\(yardsToBunker) yds"
            bunkerMarker.icon = #imageLiteral(resourceName: "hazard_marker").toNewSize(CGSize(width: 35, height: 35))
            bunkerMarker.userData = "\(currentHoleNumber):B\(bunkerIndex)";
            bunkerMarker.map = mapView;
            
            currentBunkerMarkers.append(bunkerMarker);
        }
    }
    private func updateDrivingDistanceLines() {
        clearDistanceLines()
        
        let teeLocation:GeoPoint = currentHole.teeLocations[0];
        let pinLocation:GeoPoint = currentHole.pinLocation!;
        let bearingToPin:Double = mapTools.calcBearing(start: teeLocation, finish: currentHole.pinLocation!)
        var bearingToDogLeg:Double = bearingToPin
        if let dll = currentHole.dogLegLocation {
            bearingToDogLeg = mapTools.calcBearing(start: teeLocation, finish: dll)
        }
        
        let minBearing:Int = Int(bearingToDogLeg - 12)
        let maxBearing:Int = Int(bearingToDogLeg + 12)
//        let minBearing:Int = Int(min(bearingToPin, bearingToDogLeg) - 12)
//        let maxBearing:Int = Int(max(bearingToPin, bearingToDogLeg) + 12)
        
        let teeLoc:CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: teeLocation.latitude, longitude: teeLocation.longitude)
        let pinLoc:CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: pinLocation.latitude, longitude: pinLocation.longitude)
        let teeYardsToPin:Int = mapTools.distanceFrom(first: teeLoc, second: pinLoc)
        
        let driver:Club = Club(number: 1)
        if (driver.distance < teeYardsToPin) {
            for i in 0..<3 {
                let drivingClub:Club = Club(number: i + 1)
                let lineColor:UIColor = drivingDistanceLineColors[i]
                
                let distancePath = GMSMutablePath()
                for angle in minBearing..<maxBearing {
                    let distanceCoords = mapTools.coordinates(startingCoordinates: teeLoc, atDistance: Double(drivingClub.distance), atAngle: Double(angle))
                    distancePath.add(distanceCoords)
                }
                let distanceLine = GMSPolyline(path: distancePath)
                distanceLine.strokeColor = lineColor;
                distanceLine.strokeWidth = 2
                distanceLine.map = mapView
                
                drivingDistanceLines.append(distanceLine)
            }
        }
    }
    
    private func clearDistanceLines() {
        for line in drivingDistanceLines {
            line.map = nil;
        }
        for line in suggestedDistanceLines {
            line.map = nil;
        }
        drivingDistanceLines.removeAll()
        suggestedDistanceLines.removeAll()
    }
    
    private func updateRecommendedClubLines() {
        clearDistanceLines()
        
        guard let myLocation = currentPlayerLocation else {
            return
        }
        
        let myGeopoint:GeoPoint = GeoPoint(latitude: myLocation.coordinate.latitude, longitude: myLocation.coordinate.longitude)
        let pinGeopoint:GeoPoint = currentHole.pinLocation!;
        let bearingToPin:Double = mapTools.calcBearing(start: myGeopoint, finish: pinGeopoint)
        
        let minBearing:Int = Int(bearingToPin - 12)
        let maxBearing:Int = Int(bearingToPin + 12)
        
        let shortestWedge:Club = Club(number: 13)
        //only show suggestion line if the min distance is less than current distance
        if (shortestWedge.distance < yardsToPinFromMyLocation) {
            let suggestedClub:Club = clubTools.getClubSuggestion(ydsTo: yardsToPinFromMyLocation)
            
            //show up to 2 club ups - if suggesting driver then 0 change allowed
            let minChange:Int = -min(suggestedClub.number - 1, 2)
            
            //show up to 2 club downs but not past smallest club
            let maxChange:Int = min(13 - suggestedClub.number, 2) + 1
            
            for i in minChange..<maxChange {
                var lineColor:UIColor = UIColor.white
                switch i {
                case -1: lineColor = UIColor.red;
                case 0: lineColor = UIColor.green;
                case 1: lineColor = UIColor.yellow;
                default: lineColor = UIColor(white: 1, alpha: 0.25)
                }
                
                let distancePath = GMSMutablePath()
                for angle in minBearing..<maxBearing {
                    let distanceCoords = mapTools.coordinates(startingCoordinates: myLocation.coordinate,
                                                              atDistance: Double(suggestedClub.distance),
                                                              atAngle: Double(angle))
                    distancePath.add(distanceCoords)
                }
                let distanceLine = GMSPolyline(path: distancePath)
                distanceLine.strokeColor = lineColor;
                distanceLine.strokeWidth = 2
                distanceLine.map = mapView
                
                suggestedDistanceLines.append(distanceLine)
            }
        }
    }
    
    internal func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        //Long press interferes with dragging - make new marker if not already dragging it
        if !isDraggingDistanceMarker {
            AudioServicesPlaySystemSound(1519)
            currentDistanceMarker?.map = nil
            currentDistanceMarker = GMSMarker(position: coordinate)
            currentDistanceMarker!.isDraggable = true
            currentDistanceMarker!.map = mapView;
            let markerImage = #imageLiteral(resourceName: "golf_ball_blank")
            currentDistanceMarker!.icon = markerImage.toNewSize(CGSize(width: 30, height: 30))
            currentDistanceMarker!.userData = "distance_marker";
            
            mapView.selectedMarker = currentDistanceMarker;
            
            updateDistanceMarker()
        }
    }
    
    internal func mapView(_ mapView: GMSMapView, didBeginDragging marker: GMSMarker) {
        AudioServicesPlaySystemSound(1519)
        self.isDraggingDistanceMarker = true
        mapView.selectedMarker = currentDistanceMarker;
    }
    internal func mapView(_ mapView: GMSMapView, didEndDragging marker: GMSMarker) {
        self.isDraggingDistanceMarker = false
    }
    internal func mapView(_ mapView: GMSMapView, didDrag marker: GMSMarker) {
        if (marker == currentDistanceMarker) {
            updateDistanceMarker()
        }
    }
    
    internal func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        mapView.selectedMarker = marker;
        return true;
    }
    
    internal func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        currentDistanceMarker?.map = nil
        mapView.selectedMarker = nil
        
        lineToPin?.map = nil;
        lineToMyLocation?.map = nil;
        currentDistanceMarker = nil
    }
    
    private func updateDistanceMarker() {
        if (currentDistanceMarker != nil && yardsToPressFromTee > 0) {
            let usingLocation:Bool = (yardsToPressFromLocation < yardsToPressFromTee + 25 && yardsToPressFromLocation > 0)
            let suggestedClub:Club = clubTools.getClubSuggestion(ydsTo: (usingLocation) ? yardsToPressFromLocation : yardsToPressFromTee);
            
            currentDistanceMarker!.title = usingLocation ? "\(yardsToPressFromLocation) yds" : "\(yardsToPressFromTee) yds"
            currentDistanceMarker!.snippet = suggestedClub.name
            
            let pinPath = GMSMutablePath()
            pinPath.add(currentDistanceMarker!.position)
            pinPath.add(currentPinMarker.position)
            if (lineToPin == nil) {
                lineToPin = GMSPolyline(path: pinPath)
                lineToPin!.strokeWidth = 2
                lineToPin!.strokeColor = UIColor.white
                lineToPin!.geodesic = true
                lineToPin!.map = mapView
            } else {
                lineToPin!.map = mapView
                lineToPin!.path = pinPath
            }
            
            let playerPath = GMSMutablePath()
            if (usingLocation) {
                if let playerLocation = currentPlayerLocation {
                    playerPath.add(playerLocation.coordinate)
                    playerPath.add(currentDistanceMarker!.position)
                }
            } else {
                playerPath.add(currentTeeMarker.position)
                playerPath.add(currentDistanceMarker!.position)
            }
            if (lineToMyLocation == nil) {
                lineToMyLocation = GMSPolyline(path: playerPath)
                lineToMyLocation!.strokeWidth = 2
                lineToMyLocation!.strokeColor = UIColor.white
                lineToMyLocation!.geodesic = true
                lineToMyLocation!.map = mapView
            } else {
                lineToMyLocation!.map = mapView
                lineToMyLocation!.path = playerPath
            }
        }
    }
}
