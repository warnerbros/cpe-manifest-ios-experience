//
//  ExtrasShoppingViewController.swift
//  NextGen
//
//  Created by Alec Ananian on 3/25/16.
//  Copyright © 2016 Warner Bros. Entertainment, Inc. All rights reserved.
//

import UIKit
import MBProgressHUD

class ExtrasShoppingViewController: MenuedViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    
    @IBOutlet weak var productsCollectionView: UICollectionView!
    
    private var _products: [TheTakeProduct]?
    private var _productListSessionDataTask: NSURLSessionDataTask?
    private var _didAutoSelectCategory = false

    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.showsSelectedMenuItem = false
        
        for category in TheTakeAPIUtil.sharedInstance.productCategories {
            let info = NSMutableDictionary()
            info[MenuSection.Keys.Title] = category.name
            info[MenuSection.Keys.Value] = String(category.id)
            
            if let children = category.children {
                if children.count > 1 {
                    var rows = [[MenuItem.Keys.Title: String.localize("label.all"), MenuItem.Keys.Value: String(category.id)]]
                    for child in children {
                        rows.append([MenuItem.Keys.Title: child.name, MenuItem.Keys.Value: String(child.id)])
                    }
                    
                    info[MenuSection.Keys.Rows] = rows
                }
            }
            
            menuSections.append(MenuSection(info: info))
        }
        
        productsCollectionView.registerNib(UINib(nibName: String(ShoppingSceneDetailCollectionViewCell), bundle: nil), forCellWithReuseIdentifier: ShoppingSceneDetailCollectionViewCell.ReuseIdentifier)
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        if !_didAutoSelectCategory {
            let selectedPath = NSIndexPath(forRow: 0, inSection: 0)
            self.menuTableView.selectRowAtIndexPath(selectedPath, animated: false, scrollPosition: UITableViewScrollPosition.Top)
            self.tableView(self.menuTableView, didSelectRowAtIndexPath: selectedPath)
            if let menuSection = menuSections.first {
                if menuSection.expandable {
                    let selectedPath = NSIndexPath(forRow: 1, inSection: 0)
                    self.menuTableView.selectRowAtIndexPath(selectedPath, animated: false, scrollPosition: UITableViewScrollPosition.Top)
                    self.tableView(self.menuTableView, didSelectRowAtIndexPath: selectedPath)
                }
            }
            
            _didAutoSelectCategory = true
        }
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        
        productsCollectionView.collectionViewLayout.invalidateLayout()
    }
    
    // MARK: UITableViewDelegate
    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        super.tableView(tableView, didSelectRowAtIndexPath: indexPath)
        
        if let cell = tableView.cellForRowAtIndexPath(indexPath) as? MenuItemCell, menuItem = cell.menuItem, categoryId = menuItem.value {
            if let currentTask = _productListSessionDataTask {
                currentTask.cancel()
            }
            
            productsCollectionView.userInteractionEnabled = false
            MBProgressHUD.showHUDAddedTo(productsCollectionView, animated: true)
            _productListSessionDataTask = TheTakeAPIUtil.sharedInstance.getCategoryProducts(categoryId, successBlock: { (products) in
                dispatch_async(dispatch_get_main_queue(), {
                    self._products = products
                    self.productsCollectionView.reloadData()
                    self.productsCollectionView.userInteractionEnabled = true
                    MBProgressHUD.hideAllHUDsForView(self.productsCollectionView, animated: true)
                })
                
                self._productListSessionDataTask = nil
            })
        }
    }
    
    // MARK: UICollectionViewDataSource
    func numberOfSectionsInCollectionView(collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if let products = _products {
            return products.count
        }
        
        return 0
    }
    
    func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier(ShoppingSceneDetailCollectionViewCell.ReuseIdentifier, forIndexPath: indexPath) as! ShoppingSceneDetailCollectionViewCell
        cell.titleLabel?.removeFromSuperview()
        cell.productImageType = ShoppingSceneDetailCollectionViewCell.ProductImageType.Scene
        
        if let product = _products?[indexPath.row] {
            cell.theTakeProducts = [product]
        }
        
        return cell
    }
    
    // MARK: UICollectionViewDelegate
    func collectionView(collectionView: UICollectionView, didSelectItemAtIndexPath indexPath: NSIndexPath) {
        if let shoppingDetailViewController = UIStoryboard.getMainStoryboardViewController(ShoppingDetailViewController) as? ShoppingDetailViewController, cell = collectionView.cellForItemAtIndexPath(indexPath) as? ShoppingSceneDetailCollectionViewCell {
            shoppingDetailViewController.experience = experience
            shoppingDetailViewController.products = cell.theTakeProducts
            shoppingDetailViewController.modalTransitionStyle = UIModalTransitionStyle.CrossDissolve
            self.presentViewController(shoppingDetailViewController, animated: true, completion: nil)
        }
    }
    
    // MARK: UICollectionViewDelegateFlowLayout
    func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAtIndexPath indexPath: NSIndexPath) -> CGSize {
        return CGSizeMake((CGRectGetWidth(collectionView.bounds) / 3) - 5, 190)
    }
    
    func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAtIndex section: Int) -> CGFloat {
        return 5.0
    }
    
    func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAtIndex section: Int) -> CGFloat {
        return 5.0
    }

}