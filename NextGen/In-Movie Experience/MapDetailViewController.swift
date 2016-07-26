//
//  MapDetailViewController.swift
//

import UIKit
import MapKit
import NextGenDataManager

class MapDetailViewController: SceneDetailViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    
    @IBOutlet weak private var mapView: MultiMapView!
    @IBOutlet private var mapAspectRatioConstraint: NSLayoutConstraint!
    @IBOutlet weak private var mediaCollectionView: UICollectionView?
    @IBOutlet weak private var descriptionLabel: UILabel?
    
    @IBOutlet weak var locationDetailView: UIView!
    @IBOutlet weak var videoContainerView: UIView!
    private var videoPlayerViewController: VideoPlayerViewController?
    
    @IBOutlet weak var galleryScrollView: ImageGalleryScrollView!
    private var galleryDidToggleFullScreenObserver: NSObjectProtocol?
    
    private var appData: NGDMAppData!
    private var location: NGDMLocation!
    
    deinit {
        if let observer = galleryDidToggleFullScreenObserver {
            NSNotificationCenter.defaultCenter().removeObserver(observer)
            galleryDidToggleFullScreenObserver = nil
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        
        galleryScrollView.cleanInvisibleImages()
    }
    
    // MARK: View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        appData = timedEvent!.appData!
        location = appData.location!
        
        if appData.hasVideo || appData.hasGallery {
            descriptionLabel?.removeFromSuperview()
            mediaCollectionView?.registerNib(UINib(nibName: String(SimpleMapCollectionViewCell), bundle: nil), forCellWithReuseIdentifier: SimpleMapCollectionViewCell.ReuseIdentifier)
            mediaCollectionView?.registerNib(UINib(nibName: String(SimpleImageCollectionViewCell), bundle: nil), forCellWithReuseIdentifier: SimpleImageCollectionViewCell.BaseReuseIdentifier)
        } else {
            mediaCollectionView?.removeFromSuperview()
            
            if let text = appData.displayText {
                descriptionLabel?.text = text
                descriptionLabel?.hidden = false
            } else {
                descriptionLabel?.removeFromSuperview()
                mapAspectRatioConstraint.active = false
            }
        }
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        let center = CLLocationCoordinate2DMake(location.latitude, location.longitude)
        mapView.setLocation(center, zoomLevel: appData.zoomLevel, animated: false)
        mapView.addMarker(center, title: location.name, subtitle: location.address, icon: UIImage(named: "MOSMapPin"), autoSelect: true)
        mapView.addControls()
        mapView.maxZoomLevel = appData.zoomLevel
    }
    
    // MARK: Actions
    func playVideo(videoURL: NSURL) {
        closeDetailView()
        
        if let videoPlayerViewController = UIStoryboard.getNextGenViewController(VideoPlayerViewController) as? VideoPlayerViewController {
            videoPlayerViewController.mode = VideoPlayerMode.SupplementalInMovie
            
            videoPlayerViewController.view.frame = videoContainerView.bounds
            videoContainerView.addSubview(videoPlayerViewController.view)
            self.addChildViewController(videoPlayerViewController)
            videoPlayerViewController.didMoveToParentViewController(self)
            
            videoPlayerViewController.playVideoWithURL(videoURL)
            
            locationDetailView.hidden = false
            self.videoPlayerViewController = videoPlayerViewController
        }
    }
    
    func showGallery(gallery: NGDMGallery) {
        closeDetailView()
        
        galleryScrollView.loadGallery(gallery)
        galleryScrollView.hidden = false
        
        locationDetailView.hidden = false
    }
    
    func closeDetailView() {
        locationDetailView.hidden = true
        
        galleryScrollView.destroyGallery()
        galleryScrollView.hidden = true
        
        videoPlayerViewController?.willMoveToParentViewController(nil)
        videoPlayerViewController?.view.removeFromSuperview()
        videoPlayerViewController?.removeFromParentViewController()
        videoPlayerViewController = nil
    }
    
    // MARK: UICollectionViewDataSource
    func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return appData.hasVideo || appData.hasGallery ? 2 : 0
    }
    
    func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        if indexPath.row == 0 {
            let cell = collectionView.dequeueReusableCellWithReuseIdentifier(SimpleMapCollectionViewCell.ReuseIdentifier, forIndexPath: indexPath) as! SimpleMapCollectionViewCell
            cell.setLocation(CLLocationCoordinate2DMake(location.latitude, location.longitude), zoomLevel: appData.zoomLevel - 4)
            return cell
        }
        
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier(SimpleImageCollectionViewCell.BaseReuseIdentifier, forIndexPath: indexPath) as! SimpleImageCollectionViewCell
        cell.playButtonVisible = appData.hasVideo
        cell.imageURL = appData.getImageURL(.MediaThumbnail)
        
        return cell
    }
    
    // MARK: UICollectionViewDelegate
    func collectionView(collectionView: UICollectionView, didSelectItemAtIndexPath indexPath: NSIndexPath) {
        if indexPath.row == 0 {
            closeDetailView()
        } else if let videoURL = appData.videoURL {
            playVideo(videoURL)
        } else if let gallery = appData.gallery {
            showGallery(gallery)
        }
    }
    
    // MARK: UICollectionViewDelegateFlowLayout
    func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAtIndexPath indexPath: NSIndexPath) -> CGSize {
        return CGSizeMake((CGRectGetWidth(collectionView.frame) / 4), CGRectGetHeight(collectionView.frame))
    }
    
}
