/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import <ImageIO/ImageIO.h>

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

@interface SDWebImageDownloaderObserverOperation : NSObject <SDWebImageOperation>

@property (strong, nonatomic) SDWebImageDownloaderOperation *downloadOperation;
@property (copy, nonatomic) SDWebImageDownloaderProgressBlock progressBlock;
@property (copy, nonatomic) SDWebImageDownloaderCompletedBlock completionBlock;
@property (copy, nonatomic) BOOL (^cancelBlock)();

@end

@interface SDWebImageDownloader ()

@property (strong, nonatomic) NSOperationQueue *downloadQueue;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t workingQueue;
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;

@end

@implementation SDWebImageDownloader

+ (void)initialize
{
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator"))
    {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (SDWebImageDownloader *)sharedDownloader
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
        _downloadQueue = NSOperationQueue.new;
        _downloadQueue.maxConcurrentOperationCount = 2;
        _URLCallbacks = NSMutableDictionary.new;
        _workingQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloader", DISPATCH_QUEUE_SERIAL);
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc
{
    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_workingQueue);
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads
{
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSInteger)maxConcurrentDownloads
{
    return _downloadQueue.maxConcurrentOperationCount;
}

- (id<SDWebImageOperation>)downloadImageWithURL:(NSURL *)url options:(SDWebImageDownloaderOptions)options progress:(void (^)(NSUInteger, long long))progressBlock completed:(void (^)(UIImage *, NSData *, NSError *, BOOL))completedBlock
{

    SDWebImageDownloaderObserverOperation *observerOperation = [[SDWebImageDownloaderObserverOperation alloc] init];
    observerOperation.progressBlock = progressBlock;
    observerOperation.completionBlock = completedBlock;

    __weak SDWebImageDownloader *wself = self;
    __weak SDWebImageDownloaderObserverOperation *wobserverOperation = observerOperation;

    [self addObserverOperation:observerOperation forURL:url createCallback:^(SDWebImageDownloaderOperation *downloadOperation)
     {
         if (!downloadOperation) {
             // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests
             NSMutableURLRequest *request = [NSMutableURLRequest.alloc initWithURL:url cachePolicy:NSURLCacheStorageNotAllowed timeoutInterval:15];
             request.HTTPShouldHandleCookies = NO;
             request.HTTPShouldUsePipelining = YES;
             [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

             downloadOperation = [SDWebImageDownloaderOperation.alloc initWithRequest:request queue:wself.workingQueue options:options
             progress:^(NSUInteger receivedSize, long long expectedSize)
             {
                 if (!wself) return;
                 SDWebImageDownloader *sself = wself;
                 NSArray *observers = [sself observerOperationsForURL:url];
                 for (SDWebImageDownloaderObserverOperation *observer in observers)
                 {
                     SDWebImageDownloaderProgressBlock callback = observer.progressBlock;
                     if (callback) callback(receivedSize, expectedSize);
                 }
             }
             completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished)
             {
                 if (!wself) return;
                 SDWebImageDownloader *sself = wself;
                 NSArray *observers = [sself observerOperationsForURL:url];
                 if (finished)
                 {
                     [sself removeObserverOperationsForURL:url];
                 }
                 for (SDWebImageDownloaderObserverOperation *observer in observers)
                 {
                     SDWebImageDownloaderCompletedBlock callback = observer.completionBlock;
                     if (callback) callback(image, data, error, finished);
                 }
             }];
             [wself.downloadQueue addOperation:downloadOperation];
         }
         observerOperation.downloadOperation = downloadOperation;
     }];

    observerOperation.cancelBlock = ^BOOL
    {
        return [self removeObserverOperation:wobserverOperation forURL:url];
    };

    return observerOperation;
}

- (void)addObserverOperation:(SDWebImageDownloaderObserverOperation *)observerOperation forURL:(NSURL *)url
              createCallback:(void (^)(SDWebImageDownloaderOperation *existingDownload))createCallback
{
    __block SDWebImageDownloaderOperation *existingDownload = nil;
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        if (!self.URLCallbacks[url])
        {
            self.URLCallbacks[url] = NSMutableArray.new;
        } else
        {
            SDWebImageDownloaderObserverOperation *existingObserver = [self.URLCallbacks[url] lastObject];
            existingDownload = existingObserver.downloadOperation;
        }
        // Handle single download of simultaneous download request for the same URL
        NSMutableArray *callbacksForURL = self.URLCallbacks[url];
        [callbacksForURL addObject:observerOperation];

        createCallback(existingDownload);
    });
}

- (NSArray *)observerOperationsForURL:(NSURL *)url
{
    __block NSArray *observersForURL;
    dispatch_sync(self.barrierQueue, ^
    {
        observersForURL = self.URLCallbacks[url];
    });
    return observersForURL;
}

- (BOOL)removeObserverOperation:(SDWebImageDownloaderObserverOperation *)observerOperation forURL:(NSURL *)url {
    __block BOOL removedLast = NO;
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        NSMutableArray *observersForURL = self.URLCallbacks[url];
        [observersForURL removeObject:observerOperation];
        if ([observersForURL count] == 0) {
            [self.URLCallbacks removeObjectForKey:url];
            removedLast = YES;
        }
    });
    return removedLast;
}

- (void)removeObserverOperationsForURL:(NSURL *)url
{
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        [self.URLCallbacks removeObjectForKey:url];
    });
}

@end

@implementation SDWebImageDownloaderObserverOperation

- (void)cancel
{
    BOOL shouldCacncelOperation = self.cancelBlock();
    if (shouldCacncelOperation)
    {
        [self.downloadOperation cancel];
    }
}

- (NSString *)description
{
    NSString *objectDescription = [super description];
    return [NSString stringWithFormat:@"%@ {progress: %@, completion: %@}",
            objectDescription, self.progressBlock, self.completionBlock];
}

@end
