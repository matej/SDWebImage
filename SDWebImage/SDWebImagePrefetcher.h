/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageManager.h"

/**
 * Prefetch some URLs in the cache for future use. Images are downloaded in low priority.
 */
@interface SDWebImagePrefetcher : NSObject

/**
 * SDWebImageOptions for prefetcher. Defaults to SDWebImageLowPriority.
 */
@property (nonatomic, assign) SDWebImageOptions options;

/**
 * Return the global image prefetcher instance.
 */
+ (SDWebImagePrefetcher *)sharedImagePrefetcher;

/**
 * Prefetches the given list of urls.
 */
- (void)prefetchURLs:(NSArray *)urls;

/**
 * Prefetches a subset of the given list of urls. Loads urls on the interval [index-extent, index+extent].
 * Usefull for preloading a scrollable list of images from the current user position in both directions. 
 */
- (void)prefetchURLs:(NSArray *)urls startIndex:(NSUInteger)index extent:(NSUInteger)extent;

/**
 * Remove and cancel queued list
 */
- (void)cancelPrefetching;


@end
