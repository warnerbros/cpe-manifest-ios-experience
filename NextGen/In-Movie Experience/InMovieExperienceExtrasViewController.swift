//
//  InMovieExperienceViewController.swift
//

import UIKit
import NextGenDataManager

class InMovieExperienceExtrasViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIViewControllerTransitioningDelegate {
    
    fileprivate struct Constants {
        static let HeaderHeight: CGFloat = 35
        static let FooterHeight: CGFloat = 50
    }
    
    fileprivate struct SegueIdentifier {
        static let ShowTalent = "ShowTalentSegueIdentifier"
    }
    
    @IBOutlet weak fileprivate var talentTableView: UITableView?
    @IBOutlet weak fileprivate var backgroundImageView: UIImageView!
    @IBOutlet weak fileprivate var showLessContainer: UIView!
    @IBOutlet weak fileprivate var showLessButton: UIButton!
    @IBOutlet weak fileprivate var showLessGradientView: UIView!
    fileprivate var showLessGradient = CAGradientLayer()
    fileprivate var currentTalents: [NGDMTalent]?
    fileprivate var hiddenTalents: [NGDMTalent]?
    fileprivate var isShowingMore = false
    fileprivate var numCurrentTalents: Int {
        return currentTalents?.count ?? 0
    }
    
    fileprivate var currentTime: Double = -1
    fileprivate var didChangeTimeObserver: NSObjectProtocol?
    
    deinit {
        if let observer = didChangeTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            didChangeTimeObserver = nil
        }
    }

    // MARK: View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let backgroundImageURL = NGDMManifest.sharedInstance.inMovieExperience?.appearance?.backgroundImageURL {
            backgroundImageView.af_setImage(withURL: backgroundImageURL)
        }
        
        if let actors = NGDMManifest.sharedInstance.mainExperience?.orderedActors , actors.count > 0 {
            talentTableView?.register(UINib(nibName: "TalentTableViewCell-Narrow", bundle: nil), forCellReuseIdentifier: TalentTableViewCell.ReuseIdentifier)
        } else {
            talentTableView?.removeFromSuperview()
            talentTableView = nil
        }
        
        showLessGradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        showLessGradientView.layer.insertSublayer(showLessGradient, at: 0)
        
        showLessButton.setTitle(String.localize("talent.show_less"), for: UIControlState())
        
        didChangeTimeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: VideoPlayerNotification.DidChangeTime), object: nil, queue: nil) { [weak self] (notification) -> Void in
            if let strongSelf = self, let userInfo = (notification as NSNotification).userInfo, let time = userInfo["time"] as? Double , time != strongSelf.currentTime {
                strongSelf.processTimedEvents(time)
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        if let talentTableView = talentTableView {
            showLessGradientView.frame.size.width = talentTableView.frame.width
        }
        
        showLessGradient.frame = showLessGradientView.bounds
    }
    
    func processTimedEvents(_ time: Double) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.currentTime = time
            
            let newTalents = NGDMTimedEvent.findByTimecode(time, type: .talent).sorted(by: { (timedEvent1, timedEvent2) -> Bool in
                return timedEvent1.talent!.billingBlockOrder < timedEvent2.talent!.billingBlockOrder
            }).map({ $0.talent! })
            
            if self.isShowingMore {
                self.hiddenTalents = newTalents
            } else {
                var hasNewData = newTalents.count != self.numCurrentTalents
                if !hasNewData {
                    for talent in newTalents {
                        if self.currentTalents == nil || !self.currentTalents!.contains(talent) {
                            hasNewData = true
                            break
                        }
                    }
                }
                    
                if hasNewData {
                    DispatchQueue.main.async {
                        self.currentTalents = newTalents
                        self.talentTableView?.reloadData()
                    }
                }
            }
        }
    }
    
    // MARK: UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return numCurrentTalents
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TalentTableViewCell.ReuseIdentifier) as! TalentTableViewCell
        if numCurrentTalents > (indexPath as NSIndexPath).row, let talent = currentTalents?[indexPath.row] {
            cell.talent = talent
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return String.localize("label.actors").uppercased()
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return Constants.HeaderHeight
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return Constants.FooterHeight
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return (isShowingMore ? nil : String.localize("talent.show_more"))
    }
    
    // MARK: UITableViewDelegate
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textAlignment = .center
            header.textLabel?.font = UIFont.themeCondensedFont(DeviceType.IS_IPAD ? 19 : 17)
            header.textLabel?.textColor = UIColor(netHex: 0xe5e5e5)
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        if let footer = view as? UITableViewHeaderFooterView {
            footer.textLabel?.textAlignment = .center
            footer.textLabel?.font = UIFont.themeCondensedFont(DeviceType.IS_IPAD ? 19 : 17)
            footer.textLabel?.textColor = UIColor(netHex: 0xe5e5e5)
            
            if footer.gestureRecognizers == nil || footer.gestureRecognizers!.count == 0 {
                footer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.onTapFooter)))
            }
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) as? TalentTableViewCell, let talent = cell.talent {
            self.performSegue(withIdentifier: SegueIdentifier.ShowTalent, sender: talent)
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    // MARK: Actions
    func onTapFooter() {
        toggleShowMore()
    }
    
    @IBAction func onTapShowLess() {
        toggleShowMore()
    }
    
    func toggleShowMore() {
        isShowingMore = !isShowingMore
        showLessContainer.isHidden = !isShowingMore
        
        if isShowingMore {
            currentTalents = NGDMManifest.sharedInstance.mainExperience?.orderedActors ?? [NGDMTalent]()
        } else {
            currentTalents = hiddenTalents
        }
        
        talentTableView?.contentOffset = CGPoint.zero
        talentTableView?.reloadData()
    }
    
    // MARK: Storyboard Methods
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == SegueIdentifier.ShowTalent {
            let talentDetailViewController = segue.destination as! TalentDetailViewController
            talentDetailViewController.title = String.localize("talentdetail.title")
            talentDetailViewController.talent = sender as! NGDMTalent
            talentDetailViewController.mode = TalentDetailMode.Synced
        }
    }

}
