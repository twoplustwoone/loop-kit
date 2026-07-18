#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LKProcessTapAppInfo : NSObject

@property(nonatomic, copy) NSString* bundleID;
@property(nonatomic, copy) NSString* displayName;
@property(nonatomic, assign) int pid;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL outputActive;

- (instancetype)initWithBundleID:(NSString*)bundleID
                     displayName:(NSString*)displayName
                             pid:(int)pid
                         running:(BOOL)running
                    outputActive:(BOOL)outputActive;

@end

@interface LKProcessTapManager : NSObject

- (instancetype)initWithMaxFrames:(uint32_t)maxFrames;
- (BOOL)isSupported;
- (NSArray<LKProcessTapAppInfo*>*)listApps;
- (void)setSelectedBundleIDs:(NSArray<NSString*>*)bundleIDs;
- (NSArray<NSString*>*)selectedBundleIDs;
- (void)reconcile;
- (NSUInteger)activeTapCount;
- (NSString*)lastWarning;
- (BOOL)isActive;
- (uint64_t)tapUnderruns;
- (uint64_t)tapOverruns;
- (double)tapSampleRate;
- (uint32_t)copyAudioForBundleID:(NSString*)bundleID
                            left:(float*)left
                           right:(float*)right
                       maxFrames:(uint32_t)maxFrames;

@end

NS_ASSUME_NONNULL_END
