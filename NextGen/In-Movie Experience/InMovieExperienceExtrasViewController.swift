//
//  InMovieExperienceViewController.swift
//  NextGen
//
//  Created by Alec Ananian on 1/8/16.
//  Copyright © 2016 Warner Bros. Entertainment, Inc.. All rights reserved.
//

import UIKit

class InMovieExperienceExtrasViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIViewControllerTransitioningDelegate {
    
    struct SegueIdentifier {
        static let ShowTalent = "ShowTalentSegueIdentifier"
    }
    
    @IBOutlet weak var talentTableView: UITableView!
    @IBOutlet weak var backgroundImageView: UIImageView!
    var appApperance: NGDMAppearance!
    private var _didChangeTimeObserver: NSObjectProtocol!
    private var _currentTime = -1.0
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(_didChangeTimeObserver)
    }

    // MARK: View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        appApperance = NGDMAppearance()
        backgroundImageView.image = appApperance.inMovieBackground
        
        talentTableView.registerNib(UINib(nibName: "TalentTableViewCell-Narrow", bundle: nil), forCellReuseIdentifier: "TalentTableViewCell")
        
        _didChangeTimeObserver = NSNotificationCenter.defaultCenter().addObserverForName(VideoPlayerNotification.DidChangeTime, object: nil, queue: NSOperationQueue.mainQueue()) { [weak self] (notification) -> Void in
            if let strongSelf = self, userInfo = notification.userInfo, time = userInfo["time"] as? Double {
                strongSelf._currentTime = time
            }
        }
    }
    
    // MARK: UITableViewDataSource
    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let actors = CurrentManifest.mainExperience.orderedActors {
            return actors.count
        }
        
        return 0
    }
    
    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier(TalentTableViewCell.ReuseIdentifier) as! TalentTableViewCell
        if let actors = CurrentManifest.mainExperience.orderedActors {
            cell.talent = actors[indexPath.row]
        }
        
        return cell
    }
    
    func tableView(tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return String.localize("label.actors").uppercaseString
    }
    
    func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 40
    }
    
    // MARK: UITableViewDelegate
    func tableView(tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        let header = view as! UITableViewHeaderFooterView
        header.textLabel?.textAlignment = NSTextAlignment.Center
        header.textLabel?.font = UIFont.themeCondensedFont(18)
        header.textLabel?.textColor = UIColor.whiteColor()
    }
    
    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        if let cell = tableView.cellForRowAtIndexPath(indexPath) as? TalentTableViewCell, talent = cell.talent {
            self.performSegueWithIdentifier(SegueIdentifier.ShowTalent, sender: talent)
        }
        
        tableView.deselectRowAtIndexPath(indexPath, animated: true)
    }
    
    // MARK: Storyboard Methods
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        if segue.identifier == SegueIdentifier.ShowTalent {
            let talentDetailViewController = segue.destinationViewController as! TalentDetailViewController
            talentDetailViewController.title = String.localize("talentdetail.title")
            talentDetailViewController.talent = sender as! Talent
            talentDetailViewController.mode = TalentDetailMode.Synced
        }
    }

}
