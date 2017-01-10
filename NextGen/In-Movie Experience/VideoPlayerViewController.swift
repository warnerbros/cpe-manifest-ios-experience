//
//  VideoPlayerViewController.swift
//

import Foundation
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import MessageUI
import CoreMedia
import NextGenDataManager
import UAProgressView
import MBProgressHUD
import GoogleCast

public enum VideoPlayerMode {
    case mainFeature
    case supplemental
    case supplementalInMovie
    case basicPlayer
}

public enum VideoPlayerState {
    case unknown
    case readyToPlay
    case videoLoading
    case videoSeeking
    case videoPlaying
    case videoPaused
    case suspended
    case dismissed
    case error
}

protocol VideoPlayerDelegate {
    func videoPlayer(_ videoPlayer: VideoPlayerViewController, isBuffering: Bool)
}

class VideoPlayerPlaybackView: UIView {
    
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    var playerLayer: AVPlayerLayer? {
        return (self.layer as? AVPlayerLayer)
    }
    
    var player: AVPlayer? {
        get {
            return playerLayer?.player
        }
        
        set {
            playerLayer?.player = newValue
        }
    }
    
    var isCroppingToActivePicture = false {
        didSet {
            playerLayer?.videoGravity = (isCroppingToActivePicture ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect)
        }
    }
    
}

class VideoPlayerViewController: UIViewController {
    
    private struct Constants {
        static let CommentaryEnabled = false
        
        static let CountdownTimeInterval: CGFloat = 1
        static let CountdownTotalTime: CGFloat = 5
        static let PlayerControlsAutoHideTime = 5.0
        
        struct Keys {
            static let Status = "status"
            static let Duration = "duration"
            static let PlaybackBufferEmpty = "playbackBufferEmpty"
            static let PlaybackLikelyToKeepUp = "playbackLikelyToKeepUp"
            static let CurrentItem = "currentItem"
            static let Rate = "rate"
            static let Tracks = "tracks"
            static let Playable = "playable"
            static let ExternalPlaybackActive = "externalPlaybackActive"
        }
    }
    
    var delegate: VideoPlayerDelegate?
    var mode = VideoPlayerMode.supplemental
    var shouldMute = false
    var shouldTrackOutput = false
    
    private var player: AVPlayer?
    fileprivate var playerItem: AVPlayerItem?
    private var playerItemVideoOutput: AVPlayerItemVideoOutput?
    private var originalContainerView: UIView?
    
    // State
    var didPlayInterstitial = false
    private var isManuallyPaused = false
    private var isSeeking = false
    private var lastNotifiedTime = -1.0
    var isMuted: Bool {
        get {
            return player?.isMuted ?? true
        }
        
        set {
            player?.isMuted = newValue
        }
    }
    
    private var VideoPlayerStatusObservationContext = 0
    private var VideoPlayerDurationObservationContext = 1
    private var VideoPlayerBufferEmptyObservationContext = 2
    private var VideoPlayerPlaybackLikelyToKeepUpObservationContext = 3
    private var VideoPlayerCurrentItemObservationContext = 4
    private var VideoPlayerRateObservationContext = 5
    private var VideoPlayerExternalPlaybackObservationContext = 6
    
    fileprivate var state = VideoPlayerState.unknown {
        didSet {
            if state != oldValue {
                switch state {
                case .unknown:
                    removePlayerTimeObserver()
                    syncScrubber()
                    break
                    
                case .readyToPlay:
                    // Play from playbackSyncStartTime
                    if playbackSyncStartTime > 1 && !hasSeekedToPlaybackSyncStartTime {
                        if !isSeeking {
                            seekPlayer(to: playbackSyncStartTime)
                        }
                    } else {
                        // Start from either beginning or from wherever left off
                        hasSeekedToPlaybackSyncStartTime = true
                        if !isPlaying {
                            playVideo()
                        }
                    }
                    
                    // Hide activity indicator
                    activityIndicatorVisible = false
                    
                    // Enable (not show) controls
                    playerControlsEnabled = true
                    
                    // Scrubber timer
                    initScrubberTimer()
                    break
                    
                case .videoPlaying:
                    // Hide activity indicator
                    activityIndicatorVisible = false
                    
                    // Enable (not show) controls
                    playerControlsEnabled = true
                    
                    // Auto Hide Timer
                    initAutoHideTimer()
                    
                    if isCastingActive {
                        // Scrubber timer
                        initScrubberTimer()
                    }
                    break
                    
                case .videoPaused:
                    // Hide activity indicator
                    activityIndicatorVisible = false
                    
                    // Enable (not show) controls
                    playerControlsEnabled = true
                    break
                    
                case .videoSeeking, .videoLoading:
                    // Show activity indicator
                    activityIndicatorVisible = true
                    break
                    
                default:
                    break
                }
                
                NotificationCenter.default.post(name: .videoPlayerPlaybackStateDidChange, object: self)
            }
        }
    }
    
    private var isPlaying: Bool {
        return (
            previousScrubbingRate != 0 ||
            (player != nil && player!.rate != 0) ||
            CastManager.sharedInstance.isPlaying
        )
    }
    
    private var isPlaybackLikelyToKeepUp: Bool {
        return playerItem?.isPlaybackLikelyToKeepUp ?? false
    }
    
    private var isPlaybackBufferEmpty: Bool {
        return playerItem?.isPlaybackBufferEmpty ?? false
    }
    
    var screenGrab: UIImage? {
        if let playerItem = playerItem, let cvPixelBuffer = (playerItem.outputs.first as? AVPlayerItemVideoOutput)?.copyPixelBuffer(forItemTime: playerItem.currentTime(), itemTimeForDisplay: nil) {
            return UIImage(ciImage: CIImage(cvPixelBuffer: cvPixelBuffer))
        }
        
        return nil
    }
    
    // Asset
    var url: URL? {
        return (playerItem?.asset as? AVURLAsset)?.url
    }
    
    // Playback Views
    @IBOutlet weak private var playbackView: VideoPlayerPlaybackView!
    @IBOutlet weak private var playbackOverlayView: UIView!
    @IBOutlet weak private var playbackOverlayImageView: UIImageView!
    @IBOutlet weak private var playbackOverlayLabel: UILabel!
    private var playbackOverlayTimedEvent: NGDMTimedEvent?

    // Controls
    @IBOutlet weak private var topToolbar: UIView?
    @IBOutlet weak fileprivate var commentaryButton: UIButton?
    @IBOutlet weak fileprivate var captionsButton: UIButton?
    @IBOutlet weak private var airPlayButton: MPVolumeView?
    @IBOutlet weak private var playbackToolbar: UIView?
    @IBOutlet weak private var homeButton: UIButton?
    @IBOutlet weak private var scrubber: UISlider?
    @IBOutlet weak private var timeElapsedLabel: UILabel?
    @IBOutlet weak private var durationLabel: UILabel?
    @IBOutlet weak private var cropToActivePictureButton: UIButton?
    @IBOutlet weak private var playButton: UIButton?
    @IBOutlet weak private var pauseButton: UIButton?
    @IBOutlet weak fileprivate var pictureInPictureButton: UIButton?
    @IBOutlet weak var fullScreenButton: UIButton?
    private var previousScrubbingRate: Float = 0
    
    private var playerControlsAutoHideTimer: Timer?
    
    private var isScrubbing: Bool {
        return (previousScrubbingRate != 0)
    }
    
    fileprivate var playerControlsEnabled = false {
        didSet {
            timeElapsedLabel?.isEnabled = playerControlsEnabled
            scrubber?.isEnabled = playerControlsEnabled
            durationLabel?.isEnabled = playerControlsEnabled
            playButton?.isEnabled = playerControlsEnabled
            pauseButton?.isEnabled = playerControlsEnabled
            commentaryButton?.isEnabled = playerControlsEnabled
            captionsButton?.isEnabled = playerControlsEnabled && (captionsSelectionGroup != nil)
            cropToActivePictureButton?.isEnabled = playerControlsEnabled && !isExternalPlaybackActive
            pictureInPictureButton?.isEnabled = (pictureInPictureController == nil || !pictureInPictureController!.isPictureInPictureActive) && playerControlsEnabled
            fullScreenButton?.isEnabled = playerControlsEnabled
            
            MPRemoteCommandCenter.shared().playCommand.isEnabled = playerControlsEnabled
            MPRemoteCommandCenter.shared().pauseCommand.isEnabled = playerControlsEnabled
            MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled = playerControlsEnabled
            MPRemoteCommandCenter.shared().skipBackwardCommand.isEnabled = playerControlsEnabled
            MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled = playerControlsEnabled
        }
    }
    
    private var playerControlsVisible = false {
        didSet {
            if let topToolbar = topToolbar {
                if playerControlsVisible {
                    topToolbar.isHidden = false
                    UIView.animate(withDuration: 0.2, animations: {
                        topToolbar.transform = .identity
                    })
                } else {
                    audioOptionsVisible = false
                    captionsOptionsVisible = false
                    UIView.animate(withDuration: 0.2, animations: {
                        topToolbar.transform = CGAffineTransform(translationX: 0, y: -topToolbar.bounds.height)
                    }, completion: { (_) in
                        topToolbar.isHidden = true
                    })
                }
            }
            
            if let playbackToolbar = playbackToolbar {
                if playerControlsVisible {
                    playbackToolbar.isHidden = false
                    UIView.animate(withDuration: 0.2, animations: {
                        playbackToolbar.transform = .identity
                    })
                } else {
                    UIView.animate(withDuration: 0.2, animations: {
                        playbackToolbar.transform = CGAffineTransform(translationX: 0, y: playbackToolbar.bounds.height)
                    }, completion: { (_) in
                        playbackToolbar.isHidden = true
                    })
                }
            }
        }
    }
    
    private var playerControlsLocked = false {
        didSet {
            if playerControlsLocked {
                topToolbar?.isHidden = true
                playbackToolbar?.isHidden = true
            }
        }
    }
    
    private var activityIndicator: MBProgressHUD?
    var activityIndicatorDisabled = false
    private var activityIndicatorVisible = false {
        didSet {
            if activityIndicatorVisible && !activityIndicatorDisabled {
                if activityIndicator == nil {
                    activityIndicator = MBProgressHUD.showAdded(to: self.playbackView, animated: true)
                }
            } else {
                activityIndicator?.hide(true)
                activityIndicator = nil
            }
        }
    }
    
    // Captions
    @IBOutlet fileprivate var captionsOptionsTableView: UITableView?
    private var captionsOptionsVisible = false {
        didSet {
            captionsButton?.isHighlighted = captionsOptionsVisible
            if let captionsOptionsTableView = captionsOptionsTableView {
                if captionsOptionsVisible && captionsOptionsTableView.isHidden {
                    removeAutoHideTimer()
                    captionsOptionsTableView.alpha = 0
                    captionsOptionsTableView.isHidden = false
                    UIView.animate(withDuration: 0.2, animations: {
                        captionsOptionsTableView.alpha = 1
                    })
                } else if !captionsOptionsTableView.isHidden {
                    initAutoHideTimer()
                    UIView.animate(withDuration: 0.2, animations: {
                        captionsOptionsTableView.alpha = 0
                    }, completion: { (_) in
                        captionsOptionsTableView.isHidden = true
                    })
                }
            }
        }
    }
    
    fileprivate var captionsSelectionGroup: AVMediaSelectionGroup?
    fileprivate var currentCaptionsSelectionOption: AVMediaSelectionOption?
    
    // Audio (Commentary)
    @IBOutlet fileprivate var audioOptionsTableView: UITableView?
    private var audioOptionsVisible = false {
        didSet {
            commentaryButton?.isHighlighted = audioOptionsVisible
            if let audioOptionsTableView = audioOptionsTableView {
                if audioOptionsVisible && audioOptionsTableView.isHidden {
                    removeAutoHideTimer()
                    audioOptionsTableView.alpha = 0
                    audioOptionsTableView.isHidden = false
                    UIView.animate(withDuration: 0.2, animations: {
                        audioOptionsTableView.alpha = 1
                    })
                } else if !audioOptionsTableView.isHidden {
                    initAutoHideTimer()
                    UIView.animate(withDuration: 0.2, animations: {
                        audioOptionsTableView.alpha = 0
                    }, completion: { (_) in
                        audioOptionsTableView.isHidden = true
                    })
                }
            }
        }
    }
    
    fileprivate var audioSelectionGroup: AVMediaSelectionGroup?
    fileprivate var mainAudioSelectionOption: AVMediaSelectionOption?
    fileprivate var commentaryAudioSelectionOption: AVMediaSelectionOption?
    
    // Picture-in-Picture
    fileprivate var pictureInPictureController: AVPictureInPictureController?
    
    // AirPlay & Casting
    private var isAirPlayActive: Bool {
        get {
            return ExternalPlaybackManager.isAirPlayActive
        }
        
        set {
            isExternalPlaybackActive = newValue
            ExternalPlaybackManager.isAirPlayActive = newValue
            airPlayButton?.tintColor = (isAirPlayActive ? UIColor.themePrimary : UIColor.white)
            
            if isAirPlayActive {
                logEvent(action: .airPlayOn)
            }
        }
    }
    
    fileprivate var isCastingActive: Bool {
        get {
            return ExternalPlaybackManager.isChromecastActive
        }
        
        set {
            isExternalPlaybackActive = newValue
            ExternalPlaybackManager.isChromecastActive = newValue
            
            if isCastingActive {
                logEvent(action: .chromecastOn)
            }
        }
    }
    
    fileprivate var isExternalPlaybackActive: Bool {
        get {
            return ExternalPlaybackManager.isExternalPlaybackActive
        }
        
        set {
            if isExternalPlaybackActive != newValue && mode != .basicPlayer {
                ExternalPlaybackManager.isExternalPlaybackActive = newValue
                
                if isExternalPlaybackActive {
                    cropToActivePictureButton?.isEnabled = false
                    
                    playbackOverlayView.alpha = 0
                    playbackOverlayView.isHidden = false
                    playbackOverlayView.layer.removeAllAnimations()
                    syncPlaybackOverlayImage()
                    
                    UIView.animate(withDuration: 0.2, animations: {
                        self.playbackOverlayView.alpha = 1
                    })
                    
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + .seconds(1)) {
                        if let group = self.captionsSelectionGroup {
                            self.playerItem?.select(self.currentCaptionsSelectionOption, in: group)
                        }
                    }
                } else {
                    cropToActivePictureButton?.isEnabled = playerControlsEnabled
                    playbackOverlayView.layer.removeAllAnimations()
                    
                    UIView.animate(withDuration: 0.2, animations: {
                        self.playbackOverlayView.alpha = 0
                    }, completion: { (_) in
                        self.playbackOverlayView.isHidden = true
                    })
                }
            }
        }
    }
    
    // Playback Sync
    private var playbackSyncStartTime: Double = 0
    private var hasSeekedToPlaybackSyncStartTime = false
    
    private var isFullScreen = false {
        didSet {
            fullScreenButton?.setImage(UIImage(named: (isFullScreen ? "Minimize" : "Maximize")), for: .normal)
            fullScreenButton?.setImage(UIImage(named: (isFullScreen ? "Minimize Highlighted" : "Maximize Highlighted")), for: .highlighted)
            
            if isFullScreen {
                originalContainerView = self.view.superview
                UIApplication.shared.keyWindow?.addSubview(self.view)
            } else {
                originalContainerView?.addSubview(self.view)
                originalContainerView = nil
            }
            
            if let bounds = self.view.superview?.bounds {
                self.view.frame = bounds
            }
            
            NotificationCenter.default.post(name: .videoPlayerDidToggleFullScreen, object: nil, userInfo: [NotificationConstants.isFullScreen: isFullScreen])
        }
    }
    
    var playerItemDuration: Double = 0 {
        didSet {
            let duration = (playerItemDuration.isFinite ? playerItemDuration : 0)
            durationLabel?.text = timeString(fromSeconds: duration)
            
            // Set data for OS media player and control center widgets
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
            
            if duration != oldValue && duration > 1 {
                NotificationCenter.default.post(name: .videoPlayerItemDurationDidLoad, object: self, userInfo: [Constants.Keys.Duration: duration])
            }
        }
    }
    
    var currentTime: Double {
        if isCastingActive {
            return CastManager.sharedInstance.currentTime
        }
        
        if let seconds = playerItem?.currentTime().seconds, !seconds.isNaN, seconds.isFinite {
            return max(seconds, 0)
        }
        
        return 0
    }
    
    // Countdown/Queue
    var queueTotalCount = 0
    var queueCurrentIndex = 0
    private var countdownSeconds: CGFloat = 0 {
        didSet {
            countdownLabel.text = String.localize("label.time.seconds", variables: ["count": String(Int(Constants.CountdownTotalTime - countdownSeconds))])
            countdownProgressView?.setProgress(((countdownSeconds + 1) / Constants.CountdownTotalTime), animated: true)
        }
    }
    
    private var countdownTimer: Timer?
    private var countdownProgressView: UAProgressView?
    @IBOutlet weak private var countdownLabel: UILabel!
    
    // Skip interstitial
    @IBOutlet weak private var skipContainerView: UIView!
    @IBOutlet weak private var skipCountdownContainerView: UIView!
    @IBOutlet private var skipContainerLandscapeHeightConstraint: NSLayoutConstraint?
    @IBOutlet private var skipContainerPortraitHeightConstraint: NSLayoutConstraint?
    
    // Notifications & Observers
    private var playerItemDurationDidLoadObserver: NSObjectProtocol?
    private var videoPlayerDidPlayVideoObserver: NSObjectProtocol?
    private var sceneDetailWillCloseObserver: NSObjectProtocol?
    private var videoPlayerShouldPauseObserver: NSObjectProtocol?
    private var playerTimeObserver: Any?
    
    deinit {
        let center = NotificationCenter.default
        
        if let observer = playerItemDurationDidLoadObserver {
            center.removeObserver(observer)
            playerItemDurationDidLoadObserver = nil
        }
        
        if let observer = videoPlayerDidPlayVideoObserver {
            center.removeObserver(observer)
            videoPlayerDidPlayVideoObserver = nil
        }
        
        if let observer = sceneDetailWillCloseObserver {
            center.removeObserver(observer)
            sceneDetailWillCloseObserver = nil
        }
        
        if let observer = videoPlayerShouldPauseObserver {
            center.removeObserver(observer)
            videoPlayerShouldPauseObserver = nil
        }
        
        pictureInPictureController?.stopPictureInPicture()
        playerItem?.removeObserver(self, forKeyPath: Constants.Keys.Status)
        playerItem?.removeObserver(self, forKeyPath: Constants.Keys.Duration)
        playerItem?.removeObserver(self, forKeyPath: Constants.Keys.PlaybackBufferEmpty)
        playerItem?.removeObserver(self, forKeyPath: Constants.Keys.PlaybackLikelyToKeepUp)
        player?.removeObserver(self, forKeyPath: Constants.Keys.CurrentItem)
        player?.removeObserver(self, forKeyPath: Constants.Keys.Rate)
        player?.removeObserver(self, forKeyPath: Constants.Keys.ExternalPlaybackActive)
        removePlayerTimeObserver()
        cancelCountdown()
        UIApplication.shared.endReceivingRemoteControlEvents()
    }
    
    // MARK: View Lifecycle
    override func viewDidLoad() {
        // Setup audio to be heard even if device is on silent
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
        } catch {
            print("Error setting AVAudioSession category: \(error)")
        }
        
        // Notifications
        playerItemDurationDidLoadObserver = NotificationCenter.default.addObserver(forName: .videoPlayerItemDurationDidLoad, object: nil, queue: OperationQueue.main, using: { [weak self] (notification) in
            if let strongSelf = self, let duration = notification.userInfo?[NotificationConstants.duration] as? Double, strongSelf.countdownProgressView == nil {
                let progressView = UAProgressView(frame: strongSelf.skipCountdownContainerView.frame)
                progressView.borderWidth = 0
                progressView.lineWidth = 2
                progressView.fillOnTouch = false
                progressView.tintColor = UIColor.white
                progressView.animationDuration = duration
                strongSelf.skipContainerView.addSubview(progressView)
                strongSelf.countdownProgressView = progressView
                strongSelf.countdownProgressView?.setProgress(1, animated: true)
            }
        })
        
        videoPlayerDidPlayVideoObserver = NotificationCenter.default.addObserver(forName: .videoPlayerDidPlayVideo, object: nil, queue: OperationQueue.main, using: { [weak self] (notification) in
            if let strongSelf = self, strongSelf.didPlayInterstitial {
                if let videoURL = notification.userInfo?[NotificationConstants.videoUrl] as? URL, videoURL != strongSelf.url {
                    strongSelf.pauseVideo()
                }
            }
        })
        
        videoPlayerShouldPauseObserver = NotificationCenter.default.addObserver(forName: .videoPlayerShouldPause, object: nil, queue: OperationQueue.main, using: { [weak self] (_) in
            if let strongSelf = self, strongSelf.mode == .mainFeature {
                strongSelf.pauseVideo()
            }
        })
        
        sceneDetailWillCloseObserver = NotificationCenter.default.addObserver(forName: .inMovieExperienceWillCloseDetails, object: nil, queue: OperationQueue.main, using: { [weak self] (notification) in
            if let strongSelf = self, strongSelf.mode == .mainFeature && !strongSelf.isManuallyPaused {
                strongSelf.playVideo()
            }
        })
        
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] (_) -> MPRemoteCommandHandlerStatus in
            if let strongSelf = self {
                strongSelf.onPlay(sender: nil)
                strongSelf.logEvent(action: .remotePlayButton)
                return .success
            }
            
            return .commandFailed
        }
        
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] (_) -> MPRemoteCommandHandlerStatus in
            if let strongSelf = self {
                strongSelf.onPause(sender: nil)
                strongSelf.logEvent(action: .remotePauseButton)
                return .success
            }
            
            return .commandFailed
        }
        
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { [weak self] (_) -> MPRemoteCommandHandlerStatus in
            if let strongSelf = self {
                if strongSelf.isPlaying {
                    strongSelf.onPause(sender: nil)
                } else {
                    strongSelf.onPlay(sender: nil)
                }
                
                strongSelf.logEvent(action: .remoteTogglePlayPauseButton)
                return .success
            }
            
            return .commandFailed
        }
        
        MPRemoteCommandCenter.shared().skipBackwardCommand.addTarget { [weak self] (event) -> MPRemoteCommandHandlerStatus in
            if let strongSelf = self, let event = event as? MPSkipIntervalCommandEvent {
                strongSelf.seekPlayer(to: strongSelf.currentTime - event.interval)
                strongSelf.logEvent(action: .remoteSkipBackButton)
                return .success
            }
            
            return .commandFailed
        }
        
        MPRemoteCommandCenter.shared().skipForwardCommand.addTarget { [weak self] (event) -> MPRemoteCommandHandlerStatus in
            if let strongSelf = self, let event = event as? MPSkipIntervalCommandEvent {
                strongSelf.seekPlayer(to: strongSelf.currentTime + event.interval)
                strongSelf.logEvent(action: .remoteSkipForwardButton)
                return .success
            }
            
            return .commandFailed
        }
        
        CastManager.sharedInstance.add(remoteMediaClientListener: self)
        
        if mode == .basicPlayer {
            topToolbar?.removeFromSuperview()
            playbackToolbar?.removeFromSuperview()
        } else {
            isSeeking = false
            initScrubberTimer()
            syncPlayPauseButtons()
            syncScrubber()
            
            skipContainerView.isHidden = true
            skipContainerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTapSkip)))
            
            // Localizations
            homeButton?.setTitle(String.localize("label.home"), for: UIControlState())
            commentaryButton?.setTitle(String.localize("label.commentary"), for: .normal)
            commentaryButton?.setTitle(String.localize("label.commentary_on"), for: .selected)
            commentaryButton?.setTitle(String.localize("label.commentary_on"), for: [.selected, .highlighted])
            playbackOverlayLabel.text = String.localize("player.message.external.playing").uppercased()
            
            // View setup
            captionsButton?.setImage(UIImage(named: "ClosedCaptions-Highlighted"), for: [.selected, .highlighted])
            commentaryButton?.setImage(UIImage(named: "Commentary-Highlighted"), for: [.selected, .highlighted])
            commentaryButton?.setTitleColor(UIColor.themePrimary, for: [.selected, .highlighted])
            airPlayButton?.showsVolumeSlider = false
            airPlayButton?.sizeToFit()
            
            if let airplayButtonTemplatedImage = (airPlayButton?.subviews.last as? UIButton)?.image(for: .selected)?.withRenderingMode(.alwaysTemplate) {
                airPlayButton?.setRouteButtonImage(airplayButtonTemplatedImage, for: .normal)
                airPlayButton?.setRouteButtonImage(airplayButtonTemplatedImage, for: .highlighted)
                airPlayButton?.setRouteButtonImage(airplayButtonTemplatedImage, for: .selected)
                airPlayButton?.tintColor = UIColor.white
            }
            
            let singleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(onSingleTapPlayer))
            singleTapGestureRecognizer.numberOfTapsRequired = 1
            playbackView.addGestureRecognizer(singleTapGestureRecognizer)
            
            let doubleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(onDoubleTapPlayer))
            doubleTapGestureRecognizer.numberOfTapsRequired = 2
            playbackView.addGestureRecognizer(doubleTapGestureRecognizer)
        }
        
        if mode == .mainFeature {
            fullScreenButton?.removeFromSuperview()
            audioOptionsTableView?.register(UINib(nibName: "DropdownTableViewCell", bundle: nil), forCellReuseIdentifier: DropdownTableViewCell.ReuseIdentifier)
            captionsOptionsTableView?.register(UINib(nibName: "DropdownTableViewCell", bundle: nil), forCellReuseIdentifier: DropdownTableViewCell.ReuseIdentifier)
            
            // Picture-in-Picture setup
            if AVPictureInPictureController.isPictureInPictureSupported(), let playerLayer = playbackView.playerLayer {
                pictureInPictureController = AVPictureInPictureController(playerLayer: playerLayer)
                pictureInPictureController?.delegate = self
            } else {
                pictureInPictureButton?.removeFromSuperview()
            }
            
            if let delegate = NextGenHook.delegate {
                didPlayInterstitial = SettingsManager.didWatchInterstitial && !delegate.interstitialShouldPlayMultipleTimes()
            }
            
            playMainExperience()
        } else {
            didPlayInterstitial = true
            playerControlsVisible = false
            audioOptionsTableView?.removeFromSuperview()
            captionsOptionsTableView?.removeFromSuperview()
            captionsButton?.removeFromSuperview()
            pictureInPictureButton?.removeFromSuperview()
            homeButton?.removeFromSuperview()
            if mode == .supplementalInMovie {
                fullScreenButton?.removeFromSuperview()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        pauseVideo()
        super.viewWillDisappear(animated)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        if didPlayInterstitial {
            playerControlsVisible = true
            initAutoHideTimer()
        } else {
            countdownProgressView?.frame = skipCountdownContainerView.frame
        }
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        if !didPlayInterstitial {
            let currentOrientation = UIApplication.shared.statusBarOrientation
            skipContainerLandscapeHeightConstraint?.isActive = UIInterfaceOrientationIsLandscape(currentOrientation)
            skipContainerPortraitHeightConstraint?.isActive = UIInterfaceOrientationIsPortrait(currentOrientation)
            countdownProgressView?.frame = skipCountdownContainerView.frame
        }
    }
    
    private func setViewDisplayName() {
        /* If the item has a AVMetadataCommonKeyTitle metadata, use that instead. */
        if let items = playerItem?.asset.commonMetadata {
            for item in items {
                if item.commonKey == AVMetadataCommonKeyTitle {
                    self.title = item.stringValue
                    return
                }
            }
        }
        
        /* Or set the view title to the last component of the asset URL. */
        self.title = url?.lastPathComponent
    }
    
    private func display(error: NSError) {
        let alertController = UIAlertController(title: "", message: error.localizedDescription, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        self.present(alertController, animated: true, completion: nil)
    }
    
    // MARK: Video Playback
    /* ---------------------------------------------------------
     **  Called when the value at the specified key path relative
     **  to the given object has changed.
     **  Adjust the movie play and pause button controls when the
     **  player item "status" value changes. Update the movie
     **  scrubber control when the player item is ready to play.
     **  Adjust the movie scrubber control when the player item
     **  "rate" value changes. For updates of the player
     **  "currentItem" property, set the AVPlayer for which the
     **  player layer displays visual output.
     **  NOTE: this method is invoked on the main queue.
     ** ------------------------------------------------------- */
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        /* AVPlayerItem "status" property value observer. */
        if context == &VideoPlayerStatusObservationContext {
            if let statusNumber = (change?[NSKeyValueChangeKey.newKey] as? NSNumber)?.intValue, let status = AVPlayerStatus(rawValue: statusNumber) {
                switch status {
                    /* Indicates that the status of the player is not yet known because
                     it has not tried to load new media resources for playback */
                case .unknown:
                    state = .unknown
                    break
                    
                case .readyToPlay:
                    /* Once the AVPlayerItem becomes ready to play, i.e.
                     [playerItem status] == AVPlayerItemStatusReadyToPlay,
                     its duration can be fetched from the item. */
                    
                    if state != .videoPlaying {
                        state = .readyToPlay
                        NotificationCenter.default.post(name: .videoPlayerItemReadyToPlayer, object: nil)
                    }
                    break
                    
                case .failed:
                    if let error = (object as? AVPlayerItem)?.error as? NSError {
                        assetFailedToPrepareForPlayback(error: error)
                    }
                    break
                }
            }
        }
        // AVPlayer "duration" property value observer
        else if context == &VideoPlayerDurationObservationContext {
            if let duration = playerItem?.duration.seconds {
                playerItemDuration = duration
            }
        }
        /* AVPlayer "rate" property value observer. */
        else if context == &VideoPlayerRateObservationContext {
            if let newRate = change?[NSKeyValueChangeKey.newKey] as? Bool, newRate {
                state = .videoPlaying
            } else {
                state = .videoPaused
            }
        }
        /* AVPlayer "externalPlaybackActive" propertly value observer. */
        else if context == &VideoPlayerExternalPlaybackObservationContext {
            if let isAirPlayActive = change?[NSKeyValueChangeKey.newKey] as? Bool {
                self.isAirPlayActive = isAirPlayActive
            }
        }
        /* AVPlayer "currentItem" property observer.
         Called when the AVPlayer replaceCurrentItemWithPlayerItem:
         replacement will/did occur. */
        else if context == &VideoPlayerCurrentItemObservationContext {
            /* Replacement of player currentItem has occurred */
            if (change?[NSKeyValueChangeKey.newKey] as? AVPlayerItem) != nil {
                /* Set the AVPlayer for which the player layer displays visual output. */
                playbackView.player = player
                setViewDisplayName()
            } else {
                playerControlsEnabled = false
            }
        }
        else if context == &VideoPlayerBufferEmptyObservationContext {
            state = .videoLoading
            if isPlaybackBufferEmpty && currentTime > 0 && currentTime < (playerItemDuration - 1) && isPlaying {
                delegate?.videoPlayer(self, isBuffering: true)
                NotificationCenter.default.post(name: .videoPlayerPlaybackBufferEmpty, object: nil)
            }
        }
        else if context == &VideoPlayerPlaybackLikelyToKeepUpObservationContext {
            if state != .videoPaused && !isPlaying && isPlaybackLikelyToKeepUp {
                delegate?.videoPlayer(self, isBuffering: false)
                NotificationCenter.default.post(name: .videoPlayerPlaybackLikelyToKeepUp, object: nil)
                
                if !isSeeking && hasSeekedToPlaybackSyncStartTime {
                    playVideo()
                }
            }
        }
        else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        
        syncPlayPauseButtons()
        
        if mode == .basicPlayer {
            player?.actionAtItemEnd = .none
        }
        
    }
    
    /* --------------------------------------------------------------
     **  Called when an asset fails to prepare for playback for any of
     **  the following reasons:
     **
     **  1) values of asset keys did not load successfully,
     **  2) the asset keys did load successfully, but the asset is not
     **     playable
     **  3) the item did not become ready to play.
     ** ----------------------------------------------------------- */
    private func assetFailedToPrepareForPlayback(error: NSError?) {
        state = .error
        removePlayerTimeObserver()
        syncScrubber()
        playerControlsEnabled = false
        
        print("Asset failed to prepare for playback with error: \(error)")
        
        if let error = error {
            display(error: error)
        }
    }
    
    /*
     Invoked at the completion of the loading of the values for all keys on the asset that we require.
     Checks whether loading was successfull and whether the asset is playable.
     If so, sets up an AVPlayerItem and an AVPlayer to play the asset.
     */
    private func prepareToPlay(asset: AVURLAsset, withKeys keys: [String]? = nil) {
        state = .videoLoading
        
        /* Make sure that the value of each key has loaded successfully. */
        if let keys = keys {
            for key in keys {
                let error: NSErrorPointer = nil
                let status = asset.statusOfValue(forKey: key, error: error)
                if status == .failed {
                    assetFailedToPrepareForPlayback(error: error?.pointee)
                    return
                }
            }
        }
        
        /* Use the AVAsset playable property to detect whether the asset can be played. */
        if !asset.isPlayable {
            /* Generate and show an error describing the failure. */
            let errorDict = [NSLocalizedDescriptionKey: NSLocalizedString("player-generalError", comment: "Error"), NSLocalizedFailureReasonErrorKey: NSLocalizedString("player-asset-tracks-load-error", comment: "Can't load tracks")]
            assetFailedToPrepareForPlayback(error: NSError(domain: "VideoPlayer", code: 0, userInfo: errorDict))
            return
        }
        
        // At this point we're ready to set up for playback of the asset.
            
        // Stop observing our prior AVPlayerItem, if we have one.
        if let playerItem = playerItem {
            playerItem.removeObserver(self, forKeyPath: Constants.Keys.Status)
            playerItem.removeObserver(self, forKeyPath: Constants.Keys.Duration)
            playerItem.removeObserver(self, forKeyPath: Constants.Keys.PlaybackBufferEmpty)
            playerItem.removeObserver(self, forKeyPath: Constants.Keys.PlaybackLikelyToKeepUp)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        }
        
        // Create a new instance of AVPlayerItem from the now successfully loaded AVAsset.
        playerItem = AVPlayerItem(asset: asset)
        playerItem!.addObserver(self, forKeyPath: Constants.Keys.Status, options: [.initial, .new], context: &VideoPlayerStatusObservationContext)
        playerItem!.addObserver(self, forKeyPath: Constants.Keys.Duration, options: [.initial, .new], context: &VideoPlayerDurationObservationContext)
        playerItem!.addObserver(self, forKeyPath: Constants.Keys.PlaybackBufferEmpty, options: .new, context: &VideoPlayerBufferEmptyObservationContext)
        playerItem!.addObserver(self, forKeyPath: Constants.Keys.PlaybackLikelyToKeepUp, options: .new, context: &VideoPlayerPlaybackLikelyToKeepUpObservationContext)
        
        // Set up the captions options
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: AVMediaCharacteristicLegible), group.options.first(where: { $0.locale != nil }) != nil {
            captionsSelectionGroup = group
            captionsButton?.isSelected = false
            captionsOptionsTableView?.reloadData()
            
            var selectedIndex = 0
            if UIAccessibilityIsClosedCaptioningEnabled(), let index = group.options.index(where: { $0.locale == Locale.current }) ?? group.options.index(where: { $0.locale!.languageCode == Locale.current.languageCode }) {
                selectedIndex = index + 1
            }
            
            if selectedIndex > 0 {
                currentCaptionsSelectionOption = group.options[selectedIndex - 1]
                playerItem!.select(currentCaptionsSelectionOption, in: group)
                captionsButton?.isSelected = true
            }
            
            captionsOptionsTableView?.selectRow(at: IndexPath(row: selectedIndex, section: 0), animated: false, scrollPosition: .none)
        } else {
            captionsButton?.isEnabled = false
        }
        
        // Set up commentary options
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: AVMediaCharacteristicAudible), let option = group.options.first(where: { $0.displayName.lowercased().contains("commentary") }) {
            audioSelectionGroup = group
            mainAudioSelectionOption = group.options.first
            commentaryAudioSelectionOption = option
            commentaryButton?.isHidden = false
            audioOptionsTableView?.reloadData()
            audioOptionsTableView?.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .none)
        } else {
            commentaryButton?.isHidden = true
        }
        
        /* When the player item has played to its end time we'll toggle
         the movie controller Pause button to be the Play button */
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd(_:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: playerItem)
        
        /* Create new player, if we don't already have one. */
        if player == nil {
            /* Get a new AVPlayer initialized to play the specified player item. */
            player = AVPlayer(playerItem: playerItem)
            
            /* Observe the AVPlayer "currentItem" property to find out when any
             AVPlayer replaceCurrentItemWithPlayerItem: replacement will/did occur.*/
            player!.addObserver(self, forKeyPath: Constants.Keys.CurrentItem, options: [.initial, .new], context: &VideoPlayerCurrentItemObservationContext)
            
            /* Observe the AVPlayer "rate" property to update the scrubber control. */
            player!.addObserver(self, forKeyPath: Constants.Keys.Rate, options: [.initial, .new], context: &VideoPlayerRateObservationContext)
            
            /* Observer the AVPlayer "externalPlaybackActive" property to update the UI when AirPlay connects or disconnects. */
            player!.addObserver(self, forKeyPath: Constants.Keys.ExternalPlaybackActive, options: [.initial, .new], context: &VideoPlayerExternalPlaybackObservationContext)
        }
        
        // Set up AirPlay support
        let airPlayEnabled = (mode != .basicPlayer && didPlayInterstitial)
        player!.allowsExternalPlayback = airPlayEnabled
        player!.usesExternalPlaybackWhileExternalScreenIsActive = airPlayEnabled
        
        /* Make our new AVPlayerItem the AVPlayer's current item. */
        if player!.currentItem != playerItem {
            /* Replace the player item with a new player item. The item replacement occurs 
             asynchronously; observe the currentItem property to find out when the 
             replacement will/did occur
             
             If needed, configure player item here (example: adding outputs, setting text style rules,
             selecting media options) before associating it with a player
             */
            
            player!.replaceCurrentItem(with: playerItem)
        }
        
        playbackView.isCroppingToActivePicture = (mode == .basicPlayer || !didPlayInterstitial)
        scrubber?.value = 0
    }
    
    func removeCurrentItem() {
        player?.replaceCurrentItem(with: nil)
    }
    
    private func playVideo() {
        isManuallyPaused = false
        
        // Play
        if isCastingActive {
            CastManager.sharedInstance.playMedia()
        } else {
            player?.play()
        }
        
        // Immediately show pause button. NOTE: syncPlayPauseButtons will actually update this
        // to reflect the playback "rate", e.g. 0.0 will automatically show the pause button.
        showPauseButton()
        
        // Send notification
        var userInfo: [AnyHashable: Any]? = nil
        if let url = url {
            userInfo = [NotificationConstants.videoUrl: url]
        }
        
        NotificationCenter.default.post(name: .videoPlayerDidPlayVideo, object: nil, userInfo: userInfo)
    }
    
    private func pauseVideo() {
        // Pause media
        if isCastingActive {
            CastManager.sharedInstance.pauseMedia()
        } else {
            player?.pause()
        }
        
        // Immediately show play button. NOTE: syncPlayPauseButtons will actually update this
        // to reflect the playback "rate", e.g. 0.0 will automatically show the pause button.
        showPlayButton()
    }
    
    func play(playbackAsset: PlaybackAsset) {
        NextGenHook.delegate?.updatePlaybackAsset(playbackAsset, mode: mode, isInterstitial: !didPlayInterstitial, completion: { [weak self] (playbackAsset) in
            self?.cancelCountdown()
            SettingsManager.setVideoAsWatched(playbackAsset.url)
            self?.playbackSyncStartTime = playbackAsset.startTime
            self?.hasSeekedToPlaybackSyncStartTime = false
            
            var nowPlayingInfo = [String: Any]()
            if let title = playbackAsset.title {
                nowPlayingInfo[MPMediaItemPropertyTitle] = title
            }
            
            if #available(iOS 10.0, *) {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: playbackAsset.imageSize, requestHandler: { (_) -> UIImage in
                    return playbackAsset.image
                })
            }
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            
            if let imageUrl = playbackAsset.imageUrl {
                self?.playbackOverlayImageView.sd_setImage(with: imageUrl)
            }
            
            if playbackAsset.isCastAsset {
                self?.isCastingActive = true
                CastManager.sharedInstance.load(playbackAsset.castMediaInfo)
            } else if let urlAsset = playbackAsset.urlAsset {
                let requestedKeys = [Constants.Keys.Tracks, Constants.Keys.Playable]
                /* Tells the asset to load the values of any of the specified keys that are not already loaded. */
                urlAsset.loadValuesAsynchronously(forKeys: requestedKeys) { [weak self] in
                    /* IMPORTANT: Must dispatch to main queue in order to operate on the AVPlayer and AVPlayerItem. */
                    DispatchQueue.main.async {
                        self?.prepareToPlay(asset: urlAsset, withKeys: requestedKeys)
                    }
                }
            }
        })
    }
    
    func play(url: URL, fromStartTime startTime: Double = 0) {
        let playbackAsset = PlaybackAsset(url: url)
        playbackAsset.startTime = startTime
        play(playbackAsset: playbackAsset)
    }
    
    // MARK: Main Feature
    private func playMainExperience() {
        // Initial state of controls
        playerControlsVisible = false
        countdownProgressView?.removeFromSuperview()
        countdownProgressView = nil
        
        if !didPlayInterstitial {
            if let videoURL = NGDMManifest.sharedInstance.mainExperience?.interstitialVideoURL {
                play(url: videoURL)
                
                playerControlsLocked = true
                skipContainerView.isHidden = !SettingsManager.didWatchInterstitial
                SettingsManager.didWatchInterstitial = true
                return
            }
            
            didPlayInterstitial = true
        }
        
        playerControlsLocked = false
        skipContainerView.isHidden = true
        
        if let mainExperience = NGDMManifest.sharedInstance.mainExperience, let videoURL = mainExperience.videoURL {
            NotificationCenter.default.post(name: .videoPlayerDidPlayMainExperience, object: nil)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            play(url: videoURL)
        }
    }
    
    private func skipInterstitial() {
        pauseVideo()
        removeCurrentItem()
        didPlayInterstitial = true
        playMainExperience()
        logEvent(action: .skipInterstitial)
    }
    
    /* Set the scrubber based on the player current time. */
    @objc private func syncScrubber() {
        updateTimeLabels(time: currentTime)
        activityIndicatorVisible = false
        
        if let scrubber = scrubber {
            if playerItemDuration > 0 {
                let minValue = scrubber.minimumValue
                scrubber.value = (scrubber.maximumValue - minValue) * Float(currentTime) / Float(playerItemDuration) + minValue
            } else {
                scrubber.minimumValue = 0
            }
        }
        
        if mode == .mainFeature || mode == .basicPlayer, let player = player {
            player.isMuted = shouldMute
            
            if lastNotifiedTime != currentTime {
                lastNotifiedTime = currentTime
                NotificationCenter.default.post(name: .videoPlayerDidChangeTime, object: nil, userInfo: [NotificationConstants.time: Double(currentTime)])
                syncPlaybackOverlayImage()
            }
            
            if currentTime >= 1 && mode == .basicPlayer {
                activityIndicator?.removeFromSuperview()
            }
            
            if shouldTrackOutput, let playerItem = playerItem, playerItem.outputs.count == 0 {
                playerItem.add(AVPlayerItemVideoOutput())
            }
        }
        
        // Sync playback time with control center
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
    }
    
    private func syncPlaybackOverlayImage() {
        if !playbackOverlayView.isHidden && mode == .mainFeature {
            DispatchQueue.global(qos: .background).async {
                if let clipShareTimedEvent = NGDMTimedEvent.findClosestToTimecode(self.currentTime, type: .clipShare), clipShareTimedEvent != self.playbackOverlayTimedEvent {
                    self.playbackOverlayTimedEvent = clipShareTimedEvent
                    DispatchQueue.main.async {
                        if let imageUrl = clipShareTimedEvent.imageURL {
                            self.playbackOverlayImageView.sd_setImage(with: imageUrl)
                        }
                    }
                }
            }
        }
    }
    
    @objc private func playerItemDidReachEnd(_ notification: Notification!) {
        if let playerItem = notification.object as? AVPlayerItem, playerItem == self.playerItem {
            if !didPlayInterstitial {
                didPlayInterstitial = true
                playMainExperience()
                return
            }
            
            queueCurrentIndex += 1
            if queueCurrentIndex < queueTotalCount {
                pauseVideo()
                
                countdownLabel.isHidden = false
                countdownLabel.frame.origin = CGPoint(x: 30, y: 20)
                
                let progressView = UAProgressView(frame: countdownLabel.frame)
                progressView.centralView = countdownLabel
                progressView.borderWidth = 0
                progressView.lineWidth = 2
                progressView.fillOnTouch = false
                progressView.tintColor = UIColor.themePrimary
                progressView.animationDuration = Double(Constants.CountdownTimeInterval)
                self.view.addSubview(progressView)
                countdownProgressView = progressView
                
                countdownSeconds = 0
                countdownTimer = Timer.scheduledTimer(timeInterval: Double(Constants.CountdownTimeInterval), target: self, selector: #selector(onCountdownTimerFired), userInfo: nil, repeats: true)
            } else {
                NotificationCenter.default.post(name: .videoPlayerDidEndLastVideo, object: nil)
            }
            
            NotificationCenter.default.post(name: .videoPlayerDidEndVideo, object: nil)
            
            if mode == .mainFeature {
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(1.5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                    NextGenHook.delegate?.videoPlayerWillClose(self.mode, playbackPosition: 0)
                    self.dismiss(animated: true, completion: {
                        NotificationCenter.default.post(name: .outOfMovieExperienceShouldLaunch, object: nil)
                    })
                }
            }
        }
    }
    
    @objc private func onCountdownTimerFired() {
        countdownSeconds += Constants.CountdownTimeInterval
        
        if countdownSeconds >= Constants.CountdownTotalTime {
            if let timer = countdownTimer {
                timer.invalidate()
                countdownTimer = nil
            }
            
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(Double(Constants.CountdownTimeInterval) * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                self.cancelCountdown()
                NotificationCenter.default.post(name: .videoPlayerWillPlayNextItem, object: nil, userInfo: [NotificationConstants.index: self.queueCurrentIndex])
            }
        }
    }
    
    private func cancelCountdown() {
        if let timer = countdownTimer {
            timer.invalidate()
            countdownTimer = nil
        }
        
        countdownLabel.isHidden = true
        countdownProgressView?.removeFromSuperview()
        countdownProgressView = nil
    }
    
    private func updateTimeLabels(time: Double) {
        // Update time labels
        timeElapsedLabel?.text = timeString(fromSeconds: time)
    }
    
    private func timeString(fromSeconds seconds: Double) -> String? {
        let hours = Int(floor(seconds / 3600))
        let minutes = Int(floor((seconds / 60).truncatingRemainder(dividingBy: 60)))
        let secs = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    private func timeValue(forSlider slider: UISlider) -> Double {
        if playerItemDuration > 0 {
            let minValue = slider.minimumValue
            return Double(Float(playerItemDuration) * (slider.value - minValue) / (slider.maximumValue - minValue))
        }
        
        return 0
    }
    
    func seekPlayer(to time: Double) {
        isSeeking = true
        state = .videoSeeking
        
        if isCastingActive {
            CastManager.sharedInstance.seekMedia(to: time)
            isSeeking = false
            hasSeekedToPlaybackSyncStartTime = true
        } else {
            player?.seek(to: CMTimeMakeWithSeconds(time, 1), toleranceBefore: kCMTimeZero, toleranceAfter: kCMTimeZero, completionHandler: { [weak self] (finished) in
                if finished {
                    DispatchQueue.main.async {
                        self?.isSeeking = false
                        self?.hasSeekedToPlaybackSyncStartTime = true
                        self?.playVideo()
                    }
                }
            })
        }
    }
    
    // MARK: Actions
    @objc private func onSingleTapPlayer() {
        if !playerControlsLocked {
            if audioOptionsVisible || captionsOptionsVisible {
                audioOptionsVisible = false
                captionsOptionsVisible = false
            } else {
                playerControlsVisible = !playerControlsVisible
                initAutoHideTimer()
            }
        }
    }
    
    @objc private func onDoubleTapPlayer() {
        if !playerControlsLocked && !isExternalPlaybackActive {
            onCropToActivePicture()
        }
    }
    
    @objc private func onTapSkip() {
        if !didPlayInterstitial {
            skipInterstitial()
        }
    }
    
    @IBAction private func onPlay(sender: Any?) {
        initScrubberTimer()
        playVideo()
        
        if let button = sender as? UIButton, button == playButton {
            logEvent(action: .playButton)
        }
    }
    
    @IBAction private func onPause(sender: Any?) {
        pauseVideo()
        isManuallyPaused = true
        
        if let button = sender as? UIButton, button == pauseButton {
            logEvent(action: .pauseButton)
        }
    }
    
    @IBAction private func onToggleFullScreen() {
        isFullScreen = !isFullScreen
    }
    
    @IBAction private func onDone() {
        let dismissPlayer = { [weak self] in
            if let strongSelf = self {
                NextGenHook.delegate?.videoPlayerWillClose(strongSelf.mode, playbackPosition: strongSelf.currentTime)
                strongSelf.dismiss(animated: true, completion: nil)
            }
        }
        
        pauseVideo()
        
        if let pictureInPictureController = pictureInPictureController, pictureInPictureController.isPictureInPictureActive {
            let alertController = UIAlertController(title: "", message: String.localize("player.message.pip.exit"), preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: String.localize("label.cancel"), style: .cancel, handler: { [weak self] (_) in
                if let strongSelf = self, !strongSelf.isManuallyPaused {
                    strongSelf.playVideo()
                }
            }))
            
            alertController.addAction(UIAlertAction(title: String.localize("label.continue"), style: .default, handler: { (_) in
                dismissPlayer()
            }))
            
            self.present(alertController, animated: true, completion: nil)
        } else {
            dismissPlayer()
        }
    }
    
    @IBAction private func onToggleCommentary() {
        captionsOptionsVisible = false
        audioOptionsVisible = !audioOptionsVisible
        
        if audioOptionsVisible {
            logEvent(action: .showCommentarySelection)
        }
    }
    
    @IBAction private func onCaptionSelection() {
        audioOptionsVisible = false
        captionsOptionsVisible = !captionsOptionsVisible
        
        if captionsOptionsVisible {
            logEvent(action: .showCaptionsSelection)
        }
    }
    
    @IBAction private func onCropToActivePicture() {
        playbackView.isCroppingToActivePicture = !playbackView.isCroppingToActivePicture
        
        if playbackView.isCroppingToActivePicture {
            cropToActivePictureButton?.setImage(UIImage(named: "CropActiveCancel"), for: .normal)
            cropToActivePictureButton?.setImage(UIImage(named: "CropActiveCancel-Highlighted"), for: .highlighted)
            logEvent(action: .cropActiveOn)
        } else {
            cropToActivePictureButton?.setImage(UIImage(named: "CropActive"), for: .normal)
            cropToActivePictureButton?.setImage(UIImage(named: "CropActive-Highlighted"), for: .highlighted)
            logEvent(action: .cropActiveOff)
        }
    }
    
    @IBAction private func onPictureInPicture() {
        if let pictureInPictureController = pictureInPictureController, pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
            pictureInPictureButton?.isEnabled = false
            logEvent(action: .pictureInPictureOn)
        } else {
            let alertController = UIAlertController(title: "", message: String.localize(isExternalPlaybackActive ? "player.message.pip.external" : "player.message.pip.unavailable"), preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    /* The user is dragging the movie controller thumb to scrub through the movie. */
    @IBAction private func beginScrubbing() {
        previousScrubbingRate = player?.rate ?? 0
        pauseVideo()
        
        // Remove previous timer
        removePlayerTimeObserver()
    }
    
    /* Set the player current time to match the scrubber position. */
    @IBAction private func scrub(sender: Any?) {
        if let slider = sender as? UISlider {
            updateTimeLabels(time: timeValue(forSlider: slider))
        }
    }
    
    @IBAction private func endScrubbing(sender: Any?) {
        if playerTimeObserver == nil {
            initScrubberTimer()
        }
        
        if let slider = sender as? UISlider {
            let time = timeValue(forSlider: slider)
            
            // Update time labels
            updateTimeLabels(time: time)
            
            // Seek
            seekPlayer(to: time)
        }
        
        if previousScrubbingRate > 0 {
            player?.rate = previousScrubbingRate
            previousScrubbingRate = 0
        }
        
        logEvent(action: .seekSlider)
    }
    
    // MARK: Controls
    /* Show the pause button in the movie player controller. */
    private func showPauseButton() {
        if state != .videoLoading {
            // Disable + Hide Play Button
            playButton?.isEnabled = false
            playButton?.isHidden = true
            
            // Enable + Show Pause Button
            pauseButton?.isEnabled = true
            pauseButton?.isHidden = false
        }
    }
    
    /* Show the play button in the movie player controller. */
    private func showPlayButton() {
        if state == .videoPaused || state == .readyToPlay {
            // Disable + Hide Pause Button
            pauseButton?.isEnabled = false
            pauseButton?.isHidden = true
            
            // Enable + Show Play Button
            playButton?.isEnabled = true
            playButton?.isHidden = false
        }
    }
    
    /* If the media is playing, show the stop button; otherwise, show the play button. */
    fileprivate func syncPlayPauseButtons() {
        if isPlaying {
            showPauseButton()
        } else {
            showPlayButton()
        }
    }
    
    private func initAutoHideTimer() {
        if playerControlsVisible {
            // Invalidate existing timer
            playerControlsAutoHideTimer?.invalidate()
            playerControlsAutoHideTimer = nil
            
            // Start timer
            playerControlsAutoHideTimer = Timer.scheduledTimer(timeInterval: Constants.PlayerControlsAutoHideTime, target: self, selector: #selector(autoHideControlsIfNecessary), userInfo: nil, repeats: false)
        }
    }
    
    @objc private func autoHideControlsIfNecessary() {
        if playerControlsVisible && state == .videoPlaying {
            playerControlsVisible = false
        }
    }
    
    private func initScrubberTimer() {
        /* Requests invocation of a given block during media playback to update the movie scrubber control. */
        if playerItemDuration > 0 {
            /* Update the scrubber during normal playback. */
            if isCastingActive {
                playerTimeObserver = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(syncScrubber), userInfo: nil, repeats: true)
            } else {
                playerTimeObserver = player?.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(1, 1), queue: nil, using: { [weak self] (_) in
                    self?.syncScrubber()
                })
            }
        }
    }
    
    /* Cancels the previously registered time observer. */
    private func removePlayerTimeObserver() {
        // Player time
        if let timer = playerTimeObserver as? Timer {
            timer.invalidate()
        } else if let observer = playerTimeObserver {
            player?.removeTimeObserver(observer)
        }
        
        playerTimeObserver = nil
        removeAutoHideTimer()
    }
    
    /* Cancels the previous ly registered controls auto-hide timer */
    private func removeAutoHideTimer() {
        playerControlsAutoHideTimer?.invalidate()
        playerControlsAutoHideTimer = nil
    }
    
    fileprivate func logEvent(action: NextGenAnalyticsAction, itemId: String? = nil, itemName: String? = nil) {
        if mode == .mainFeature {
            NextGenHook.logAnalyticsEvent(.imeAction, action: action, itemId: itemId, itemName: itemName)
        }
    }
    
}

extension VideoPlayerViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == audioOptionsTableView {
            return 2
        }
        
        if tableView == captionsOptionsTableView, let options = captionsSelectionGroup?.options {
            return options.count + 1
        }
        
        return 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: DropdownTableViewCell.ReuseIdentifier, for: indexPath) as! DropdownTableViewCell
        
        if tableView == audioOptionsTableView, let option = commentaryAudioSelectionOption {
            cell.title = (indexPath.row == 0 ? String.localize("label.off") : option.displayName)
        } else if tableView == captionsOptionsTableView, let options = captionsSelectionGroup?.options {
            if indexPath.row == 0 {
                cell.title = String.localize("label.off")
                cell.isSelected = (currentCaptionsSelectionOption == nil)
            } else if options.count > (indexPath.row - 1) {
                let option = options[indexPath.row - 1]
                cell.title = option.displayName
                cell.isSelected = (option == currentCaptionsSelectionOption)
            }
        }
        
        return cell
    }
    
}

extension VideoPlayerViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        (tableView.cellForRow(at: indexPath) as? DropdownTableViewCell)?.updateStyle()
        
        if tableView == audioOptionsTableView, let group = audioSelectionGroup {
            if indexPath.row > 0, let option = commentaryAudioSelectionOption {
                playerItem?.select(option, in: group)
                commentaryButton?.isSelected = true
                logEvent(action: .commentaryOn)
            } else if let option = mainAudioSelectionOption {
                playerItem?.select(option, in: group)
                commentaryButton?.isSelected = false
                logEvent(action: .commentaryOff)
            }
        } else if tableView == captionsOptionsTableView, let group = captionsSelectionGroup {
            if indexPath.row > 0 && group.options.count > (indexPath.row - 1) {
                currentCaptionsSelectionOption = group.options[indexPath.row - 1]
                logEvent(action: .captionsOn, itemName: currentCaptionsSelectionOption?.displayName)
            } else {
                currentCaptionsSelectionOption = nil
                logEvent(action: .captionsOff)
            }
            
            playerItem?.select(currentCaptionsSelectionOption, in: group)
            captionsButton?.isSelected = (currentCaptionsSelectionOption != nil)
        }
    }
    
}

extension VideoPlayerViewController: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.pictureInPictureButton?.isEnabled = playerControlsEnabled
    }
    
    func picture(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let alertController = UIAlertController(title: "", message: String.localize("player.message.pip.error"), preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        self.present(alertController, animated: true, completion: nil)
    }
    
}

extension VideoPlayerViewController: GCKRemoteMediaClientListener {
    
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didStartMediaSessionWithID sessionID: Int) {
        print("Remote media client started with ID: \(sessionID)")
    }
    
    func remoteMediaClientDidUpdatePreloadStatus(_ client: GCKRemoteMediaClient) {
        print("Remote media client updated preload status")
    }
    
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus) {
        print("Remote media client updated media status")
        
        if let duration = mediaStatus.mediaInformation?.streamDuration {
            playerItemDuration = duration
        }
        
        switch mediaStatus.playerState {
        case .unknown, .idle:
            state = .unknown
            break
            
        case .playing:
            state = .videoPlaying
            break
            
        case .paused:
            state = .videoPaused
            break
            
        case .buffering, .loading:
            state = .videoLoading
            break
        }
        
        syncPlayPauseButtons()
    }
    
}
