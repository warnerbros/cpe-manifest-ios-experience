//
//  NextGenDataLoader.swift
//

import Foundation
import UIKit
import AVKit
import MediaPlayer
import GoogleMaps
import NextGenDataManager
import PromiseKit
import MBProgressHUD

@objc class NextGenDataLoader: NSObject {
    
    private enum DataLoaderError: Error {
        case titleNotFound
        case fileMissing
    }
    
    private struct Constants {
        struct ConfigKey {
            static let TheTakeAPI = "thetake_api_key"
            static let BaselineAPI = "baseline_api_key"
            static let GoogleMapsAPI = "google_maps_api_key"
        }
    }
    
    static let ManifestData = [
        "man_of_steel": [
            "title": "Man of Steel",
            "image": "MOS-Onesheet",
            "manifest": "https://cpe-manifest.s3.amazonaws.com/xml/urn:dece:cid:eidr-s:DAFF-8AB8-3AF0-FD3A-29EF-Q/mos_manifest-2.3.xml",
            "appdata": "https://cpe-manifest.s3.amazonaws.com/xml/urn:dece:cid:eidr-s:DAFF-8AB8-3AF0-FD3A-29EF-Q/mos_appdata-2.3.xml",
            "cpestyle": "https://cpe-manifest.s3.amazonaws.com/xml/urn:dece:cid:eidr-s:DAFF-8AB8-3AF0-FD3A-29EF-Q/mos_cpestyle-2.4.xml"
        ]
    ]
    
    static func supportsContent(cid: String) -> Bool {
        return ManifestData[cid] != nil
    }
    
    static let sharedInstance = NextGenDataLoader()
    private var productAPIUtilKey: String?
    private var talentAPIUtilKey: String?
    
    override init() {
        super.init()
        
        NextGenHook.delegate = self
    }
    
    func loadConfig() {
        // Load configuration file
        if let configDataPath = Bundle.main.path(forResource: "Data/config", ofType: "json") {
            do {
                let configData = try Data(contentsOf: URL(fileURLWithPath: configDataPath), options: NSData.ReadingOptions.mappedIfSafe)
                if let configJSON = try JSONSerialization.jsonObject(with: configData, options: JSONSerialization.ReadingOptions.mutableContainers) as? NSDictionary {
                    productAPIUtilKey = configJSON[Constants.ConfigKey.TheTakeAPI] as? String
                    talentAPIUtilKey = configJSON[Constants.ConfigKey.BaselineAPI] as? String
                    
                    if let key = configJSON[Constants.ConfigKey.GoogleMapsAPI] as? String {
                        GMSServices.provideAPIKey(key)
                        NGDMConfiguration.mapService = .googleMaps
                        NGDMConfiguration.googleMapsAPIKey = key
                    }
                }
            } catch let error as NSError {
                print("Error parsing NextGen config data: \(error.localizedDescription)")
            }
        } else {
            print("NextGen configuration file not found")
        }
    }
    
    func loadTitle(id: String, completion: @escaping (_ success: Bool, _ error: Error?) -> Void) throws {
        guard let titleData = NextGenDataLoader.ManifestData[id] else { throw DataLoaderError.titleNotFound }
        
        guard let manifestXMLPath = titleData["manifest"] else { throw NGDMError.manifestMissing }
        loadXMLFile(manifestXMLPath).then(on: DispatchQueue.global(qos: .userInteractive), execute: { localFilePath -> Void in
            do {
                if let key = self.productAPIUtilKey {
                    NGDMConfiguration.productAPIUtil = TheTakeAPIUtil(apiKey: key)
                }
                
                if let key = self.talentAPIUtilKey {
                    NGDMConfiguration.talentAPIUtil = BaselineAPIUtil(apiKey: key)
                }
                
                try NGDMManifest.sharedInstance.loadManifestXMLFile(localFilePath)
                
                NGDMConfiguration.productAPIUtil?.featureAPIID = NGDMManifest.sharedInstance.mainExperience?.customIdentifier(TheTakeAPIUtil.APINamespace)
                NGDMConfiguration.talentAPIUtil?.featureAPIID = NGDMManifest.sharedInstance.mainExperience?.customIdentifier(BaselineAPIUtil.APINamespace)
                NGDMManifest.sharedInstance.loadProductData()
                NGDMManifest.sharedInstance.loadTalentData()
            } catch NGDMError.mainExperienceMissing {
                print("Error loading Manifest file: no main Experience found")
                completion(false, NGDMError.mainExperienceMissing)
            } catch NGDMError.inMovieExperienceMissing {
                print("Error loading Manifest file: no in-movie Experience found")
                completion(false, NGDMError.inMovieExperienceMissing)
            } catch NGDMError.outOfMovieExperienceMissing {
                print("Error loading Manifest file: no out-of-movie Experience found")
                completion(false, NGDMError.outOfMovieExperienceMissing)
            } catch {
                print("Error loading Manifest file: unknown error")
                completion(false, error)
            }
            
            var promises = [Promise<String>]()
            var hasAppData = false
            
            if let appDataXMLPath = titleData["appdata"] {
                promises.append(self.loadXMLFile(appDataXMLPath))
                hasAppData = true
            }
            
            if let styleXMLPath = titleData["cpestyle"] {
                promises.append(self.loadXMLFile(styleXMLPath))
            }
            
            if promises.count > 0 {
                _ = when(fulfilled: promises).then(on: DispatchQueue.global(qos: .userInteractive), execute: { results -> Void in
                    var appDataFilePath: String?
                    var cpeStyleFilePath: String?
                    if hasAppData {
                        appDataFilePath = results.first
                        if results.count > 1 {
                            cpeStyleFilePath = results.last
                        }
                    } else {
                        cpeStyleFilePath = results.first
                    }
                    
                    if let localFilePath = appDataFilePath {
                        do {
                            try NGDMManifest.sharedInstance.loadAppDataXMLFile(localFilePath)
                        } catch {
                            print("Error loading AppData file")
                        }
                    }
                    
                    if let localFilePath = cpeStyleFilePath {
                        do {
                            try NGDMManifest.sharedInstance.loadCPEStyleXMLFile(localFilePath)
                        } catch {
                            print ("Error loading CPE-Style file")
                        }
                    }
                    
                    completion(true, nil)
                })
            } else {
                completion(true, nil)
            }
        }).catch { error in
            completion(false, error)
        }
    }
    
    private func loadXMLFile(_ filePath: String) -> Promise<String> {
        return Promise { fulfill, reject in
            if let fileUrl = URL(string: filePath) {
                if let manifestXMLPath = Bundle.main.path(forResource: "Data/Manifests/" + fileUrl.lastPathComponent.replacingOccurrences(of: ".xml", with: ""), ofType: "xml") {
                    fulfill(manifestXMLPath)
                } else if let applicationSupportFileURL = NextGenCacheManager.applicationSupportFileURL(fileUrl) {
                    if NextGenCacheManager.fileExists(applicationSupportFileURL) {
                        fulfill(applicationSupportFileURL.path)
                        NextGenCacheManager.storeApplicationSupportFile(fileUrl, completionHandler: { (_) in
                            
                        })
                    } else {
                        NextGenCacheManager.storeApplicationSupportFile(fileUrl, completionHandler: { (localFileURL) in
                            if let filePath = localFileURL?.path {
                                fulfill(filePath)
                            } else {
                                reject(DataLoaderError.fileMissing)
                            }
                        })
                    }
                } else {
                    reject(DataLoaderError.fileMissing)
                }
            } else {
                reject(DataLoaderError.fileMissing)
            }
        }
    }
    
}

extension NextGenDataLoader: NextGenHookDelegate {
    
    func connectionStatusChanged(status: NextGenConnectionStatus) {
        // Respond to any changes in the user's connection status (e.g. display prompt about cellular data usage)
    }
    
    func experienceWillOpen() {
        // Any start-up tasks
    }
    
    func experienceWillClose() {
        // Any shutdown tasks
    }
    
    func experienceWillEnterDebugMode() {
        // Perform any debug tasks or unlock any debug sections of the app
        // Debug mode is activated by tapping and holding the "Extras" button on the home screen for five seconds
    }
    
    public func previewModeShouldLaunchBuy() {
        // Callback for when the user taps the home screen buy button
    }
    
    func interstitialShouldPlayMultipleTimes() -> Bool {
        // Return true if interstitial video should play again after user has already seen it (with ability to skip)
        return true
    }
    
    func urlForSharedContent(id: String, type: NextGenSharedContentType, completion: @escaping (URL?) -> Void) {
        var shareUrl = "your-domain.com"
        
        if type == .image {
            shareUrl += "/share/images"
        } else {
            shareUrl += "/share/videos"
        }
        
        shareUrl += "/" + id
        completion(URL(string: shareUrl))
    }
    
    func didFinishPlayingAsset(_ playbackAsset: NextGenPlaybackAsset, mode: VideoPlayerMode) {
        // Handle end of playback
        
        if mode == .mainFeature {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
    
    func playbackAsset(withURL url: URL, title: String?, imageURL: URL?, forMode mode: VideoPlayerMode, completion: @escaping (NextGenPlaybackAsset) -> Void) {
        // Handle DRM
        if mode == .mainFeature {
            // TODO: Replace the this asset handler with your DRM flow
            completion(NextGenExamplePlaybackAsset(id: url.absoluteString, url: URL(string: "http://pdl.warnerbros.com/digitalcopy2/s/bbb/big_buck_bunny_480p_h264.mov")!, title: "Big Buck Bunny"))
        } else {
            completion(NextGenExamplePlaybackAsset(id: url.absoluteString, url: url, title: title, imageURL: imageURL))
        }
    }
    
    func didTapFilmography(forTitle title: String, fromViewController viewController: UIViewController) {
        let showQueryNotFound = {
            let alertController = UIAlertController(title: "", message: "Sorry, but this movie is currently unavailable on iTunes", preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            viewController.present(alertController, animated: true, completion: nil)
        }
        
        if let searchUrl = URL(string: "https://itunes.apple.com/search?media=movie&entity=movie&term=\(title.replacingOccurrences(of: " ", with: "+"))") {
            let hud = MBProgressHUD.showAdded(to: viewController.view, animated: true)
            URLSession.shared.dataTask(with: searchUrl, completionHandler: { (data, _, error) in
                DispatchQueue.main.async {
                    hud?.hide(true)
                    if let data = data {
                        do {
                            if let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? NSDictionary, let urlString = (jsonResult["results"] as? [NSDictionary])?.first?["trackViewUrl"] as? String, let url = URL(string: urlString) {
                                url.promptLaunch(type: .itunes)
                            } else {
                                showQueryNotFound()
                            }
                        } catch {
                            print("Error parsing iTunes data: \(error)")
                            showQueryNotFound()
                        }
                    }
                }
            }).resume()
        } else {
            showQueryNotFound()
        }
    }
    
    func logAnalyticsEvent(_ event: NextGenAnalyticsEvent, action: NextGenAnalyticsAction, itemId: String?, itemName: String?) {
        // Adjust values as needed for your analytics implementation
        
        /* Take the provided parameters and construct the Google Analytics-specific properties that will be sent to log the event */
        /* let category = event.rawValue
        let action = action.rawValue
        var label: String
        if let itemId = itemId, let itemName = itemName {
            label = itemId + " - " + itemName
        } else {
            label = itemId ?? itemName ?? ""
        } */
        
        /* Google Analytics allows you to add custom dimensions. Use this dictionary to insert values related to this event, 
           where they key is the custom dimension ID provided by Google Analytics */
        /* let tracker = GAI.sharedInstance().defaultTracker
        var customDimensions = [Int: String]() 
        
        for (customDimension, value) in customDimensions {
            tracker?.set(GAIFields.customDimension(for: customDimension.rawValue), value: value)
        } */
        
        /* Build the Google Analytics event dictionary and send to tracker */
        /* if let builder = GAIDictionaryBuilder.createEvent(withCategory: category, action: action, label: label, value: nil), let parameters = NSDictionary(dictionary: builder.build()) as? [AnyHashable: Any] {
            tracker?.send(parameters)
        } */
    }
    
}
