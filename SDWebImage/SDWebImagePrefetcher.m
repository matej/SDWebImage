/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImagePrefetcher.h"
#import "SDWebImageManager.h"

@interface SDWebImagePrefetcher ()

@property (strong, nonatomic) SDWebImageManager *manager;
@property (strong, nonatomic) NSMutableDictionary *activeOperations;

@end

@implementation SDWebImagePrefetcher

+ (SDWebImagePrefetcher *)sharedImagePrefetcher
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    if ((self = [super init]))
    {
        _manager = [SDWebImageManager new];
        _activeOperations = [NSMutableDictionary new];
        _options = SDWebImageLowPriority;
    }
    return self;
}

- (void)prefetchURLs:(NSArray *)urls
{
    NSSet *urlsSet = [NSSet setWithArray:urls];
    NSMutableDictionary *activeOperations = self.activeOperations;
    SDWebImageManager *manager = self.manager;
    
    // Cancel active urls that are no longer relevant, butl leave others intact
    NSMutableSet *obsoleteUrls = [NSMutableSet setWithArray:[activeOperations allKeys]];
    [obsoleteUrls minusSet:urlsSet];
    for (NSURL *url in obsoleteUrls)
    {
        id<SDWebImageOperation> operation = activeOperations[url];
        [manager cancelOperation:operation];
        [activeOperations removeObjectForKey:url];
    }
    
    // Add new urls
    for (NSURL *url in urls)
    {
        id<SDWebImageOperation> operation = activeOperations[url];
        if (!operation)
        {
            __block BOOL completed = NO;
            operation = [manager downloadWithURL:url options:self.options progress:nil completed:
            ^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished)
            {
                if (finished)
                {
                    [activeOperations removeObjectForKey:url];
                    completed = YES;
                }
            }];
            if (!completed) activeOperations[url] = operation;
            
        }
    }
}

- (void)prefetchURLs:(NSArray *)urls startIndex:(NSUInteger)index extent:(NSUInteger)extent
{
    NSUInteger count = [urls count];
    NSMutableArray *subset = [NSMutableArray arrayWithCapacity:2*extent+1];
    
    if (index < count) {
        [subset addObject:urls[index]];
    }
    
    for (NSUInteger i = 1; i <= extent; i++) {
        NSInteger lowIndex = (NSInteger)index - (NSInteger)i;
        if (lowIndex >= 0) {
            [subset addObject:urls[lowIndex]];
        }
        NSUInteger upIndex = index + i;
        if (upIndex < count) {
            [subset addObject:urls[upIndex]];
        }
    }
    
    [self prefetchURLs:subset];
}

- (void)cancelPrefetching
{
    [self.activeOperations removeAllObjects];
    [self.manager cancelAll];
}

@end
