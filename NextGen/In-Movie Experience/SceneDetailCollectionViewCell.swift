//
//  SceneDetailCollectionViewCell.swift
//

import UIKit
import NextGenDataManager

class SceneDetailCollectionViewCell: UICollectionViewCell {
    
    struct Constants {
        static let UpdateInterval: Double = 15
    }
    
    @IBOutlet weak var titleLabel: UILabel?
    @IBOutlet weak var descriptionLabel: UILabel!
    
    private var _title: String? {
        didSet {
            titleLabel?.text = _title?.uppercaseString
        }
    }
    
    internal var _descriptionText: String? {
        didSet {
            descriptionLabel.text = _descriptionText
        }
    }
    
    var timedEvent: NGDMTimedEvent? {
        didSet {
            if timedEvent != oldValue {
                timedEventDidChange()
            }
        }
    }
    
    private var _lastSavedTime: Double = -1.0
    var currentTime: Double = -1.0 {
        didSet {
            if _lastSavedTime == -1 || abs(currentTime - _lastSavedTime) >= Constants.UpdateInterval {
                _lastSavedTime = currentTime
                currentTimeDidChange()
            }
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        timedEvent = nil
    }
    
    func timedEventDidChange() {
        _title = timedEvent?.experience?.title
        if timedEvent != nil && timedEvent!.isType(.ClipShare) {
            _descriptionText = String.localize("clipshare.description")
        } else {
            _descriptionText = timedEvent?.descriptionText
        }
    }
    
    func currentTimeDidChange() {
        // Override
    }
}
