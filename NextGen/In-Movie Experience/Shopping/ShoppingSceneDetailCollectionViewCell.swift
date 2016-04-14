//
//  ShoppingSceneDetailCollectionViewCell.swift
//  NextGen
//
//  Created by Alec Ananian on 2/5/16.
//  Copyright © 2016 Warner Bros. Entertainment, Inc. All rights reserved.
//

class ShoppingSceneDetailCollectionViewCell: SceneDetailCollectionViewCell {
    
    static let ReuseIdentifier = "ShoppingSceneDetailCollectionViewCellReuseIdentifier"
    
    struct ProductImageType {
        static let Product = "ProductImageTypeProduct"
        static let Scene = "ProductImageTypeScene"
    }
    
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var bullseyeView: UIView!
    @IBOutlet weak var extraDescriptionLabel: UILabel!
    
    var productImageType = ProductImageType.Product
    private var _setImageSessionDataTask: NSURLSessionDataTask?
    
    private var _extraDescriptionText: String? {
        didSet {
            extraDescriptionLabel?.text = _extraDescriptionText
        }
    }
    
    private var _imageURL: NSURL? {
        didSet {
            if let url = _imageURL {
                if url != oldValue {
                    imageView.contentMode = UIViewContentMode.ScaleAspectFit
                    _setImageSessionDataTask = imageView.setImageWithURL(url, completion: { (image) -> Void in
                        self.imageView.backgroundColor = image?.getPixelColor(CGPoint.zero)
                    })
                }
            } else {
                imageView.image = nil
                imageView.backgroundColor = UIColor.clearColor()
            }
        }
    }
    
    private var _currentProduct: TheTakeProduct?
    private var _currentProductFrameTime = -1.0
    private var _currentProductSessionDataTask: NSURLSessionDataTask?
    var theTakeProducts: [TheTakeProduct]? {
        didSet {
            if let products = theTakeProducts, product = products.first {
                if _currentProduct != product {
                    _currentProduct = product
                    _descriptionText = product.brand
                    _extraDescriptionText = product.name
                    _imageURL = (productImageType == ProductImageType.Scene ? product.sceneImageURL : product.productImageURL)
                }
            } else {
                _currentProduct = nil
                _imageURL = nil
                _descriptionText = nil
                _extraDescriptionText = nil
            }
        }
    }
    
    override func currentTimeDidChange() {
        if timedEvent != nil && timedEvent!.isProduct() {
            let newFrameTime = TheTakeAPIUtil.sharedInstance.closestFrameTime(currentTime)
            if newFrameTime != _currentProductFrameTime {
                _currentProductFrameTime = newFrameTime
                
                if let currentTask = _currentProductSessionDataTask {
                    currentTask.cancel()
                }
                
                _currentProductSessionDataTask = TheTakeAPIUtil.sharedInstance.getFrameProducts(_currentProductFrameTime, successBlock: { [weak self] (products) -> Void in
                    if let strongSelf = self {
                        dispatch_async(dispatch_get_main_queue(), {
                            strongSelf.theTakeProducts = products
                        })
                        
                        strongSelf._currentProductSessionDataTask = nil
                    }
                })
            }
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        theTakeProducts = nil
        bullseyeView.hidden = true
        
        if let task = _currentProductSessionDataTask {
            task.cancel()
            _currentProductSessionDataTask = nil
        }
        
        if let task = _setImageSessionDataTask {
            task.cancel()
            _setImageSessionDataTask = nil
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if productImageType == ProductImageType.Scene {
            bullseyeView.hidden = false
            if let product = _currentProduct {
                var bullseyeFrame = bullseyeView.frame
                let bullseyePoint = product.getSceneBullseyePoint(imageView.frame)
                bullseyeFrame.origin = CGPointMake(bullseyePoint.x + CGRectGetMinX(imageView.frame), bullseyePoint.y + CGRectGetMinY(imageView.frame))
                bullseyeView.frame = bullseyeFrame
                bullseyeView.layer.cornerRadius = CGRectGetWidth(bullseyeFrame) / 2
            }
        } else {
            bullseyeView.hidden = true
        }
    }
    
}