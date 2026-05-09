#import "YTVolumeHUD.h"
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// YouTube Settings Headers
@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(YTSettingsCell *cell,
                                              BOOL enabled))switchBlock
                      settingItemId:(int)settingItemId;
+ (instancetype)itemWithTitle:(NSString *)title
             titleDescription:(NSString *)titleDescription
      accessibilityIdentifier:(NSString *)accessibilityIdentifier
              detailTextBlock:(id)detailTextBlock
                  selectBlock:(BOOL (^)(YTSettingsCell *cell,
                                        NSUInteger arg1))selectBlock;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
                   icon:(id)icon
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
@end

@interface YTSettingsGroupData : NSObject
@property(nonatomic, assign) NSInteger type;
- (NSArray<NSNumber *> *)orderedCategories;
@end

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray<NSNumber *> *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry;
@end

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";
static NSString *const kVolumeBoostYTPersistenceEnabledKey =
    @"VolumeBoostYTPersistenceEnabled";
static NSString *const kVolumeBoostYTDefaultVolumeScalarKey =
    @"VolumeBoostYTDefaultVolumeScalar";
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";
static const void *kVolumeBoostYTTapInstalledKey =
    &kVolumeBoostYTTapInstalledKey;

static BOOL IsVolumeBoostYTEnabled() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTEnabledKey] == nil) {
    return YES; // Default to enabled
  }
  return [defaults boolForKey:kVolumeBoostYTEnabledKey];
}

static BOOL IsVolumePersistenceEnabled() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTPersistenceEnabledKey] == nil) {
    return YES; // Default to remembering the last chosen boost
  }
  return [defaults boolForKey:kVolumeBoostYTPersistenceEnabledKey];
}

static float ClampVolumeMultiplier(float multiplier);
static float GetLogarithmicAudioMultiplier(void);

static float GetConfiguredDefaultVolumeMultiplier() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTDefaultVolumeScalarKey] == nil) {
    return 1.0f; // Default to 100%
  }
  return ClampVolumeMultiplier(
      [defaults floatForKey:kVolumeBoostYTDefaultVolumeScalarKey]);
}

static NSString *FormattedVolumePercentage(float multiplier) {
  return [NSString stringWithFormat:@"%.0f%%", multiplier * 100.0f];
}

static float ClampVolumeMultiplier(float multiplier) {
  if (multiplier < 0.0f)
    return 0.0f;
  if (multiplier > 20.0f)
    return 20.0f;
  return multiplier;
}

static float currentVolumeMultiplier = -1.0f;

static NSHashTable *activeRenderers = nil;

// The tap keeps just enough state to smooth gain changes across frames.
typedef struct {
  AudioStreamBasicDescription format;
  Float32 envelope;
  Float32 *scratchBuffer;
  UInt32 scratchCapacity;
} VolumeBoostYTTapContext;

static void RegisterRenderer(id renderer) {
  if (!activeRenderers) {
    activeRenderers = [NSHashTable weakObjectsHashTable];
  }
  if (renderer) {
    [activeRenderers addObject:renderer];
  }
}

static void VolumeBoostYTTapInit(MTAudioProcessingTapRef tap, void *clientInfo,
                                 void **tapStorageOut) {
  (void)tap;
  (void)clientInfo;
  VolumeBoostYTTapContext *context =
      calloc(1, sizeof(VolumeBoostYTTapContext));
  context->envelope = 1.0f;
  *tapStorageOut = context;
}

static void VolumeBoostYTTapFinalize(MTAudioProcessingTapRef tap) {
  VolumeBoostYTTapContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (context) {
    if (context->scratchBuffer) {
      free(context->scratchBuffer);
    }
    free(context);
  }
}

static void VolumeBoostYTTapPrepare(MTAudioProcessingTapRef tap,
                                    CMItemCount maxFrames,
                                    const AudioStreamBasicDescription *processingFormat) {
  (void)tap;
  VolumeBoostYTTapContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (context && processingFormat) {
    context->format = *processingFormat;
    context->envelope = 1.0f;
    UInt32 channels = MAX((UInt32)processingFormat->mChannelsPerFrame, 1U);
    UInt32 neededCapacity = (UInt32)maxFrames * channels;
    if (neededCapacity > context->scratchCapacity) {
      Float32 *newBuffer =
          realloc(context->scratchBuffer, neededCapacity * sizeof(Float32));
      if (newBuffer) {
        context->scratchBuffer = newBuffer;
        context->scratchCapacity = neededCapacity;
      }
    }
  }
}

static void VolumeBoostYTTapUnprepare(MTAudioProcessingTapRef tap) {
  (void)tap;
}

static void VolumeBoostYTTapProcess(MTAudioProcessingTapRef tap,
                                    CMItemCount numberFrames,
                                    MTAudioProcessingTapFlags flags,
                                    AudioBufferList *bufferListInOut,
                                    CMItemCount *numberFramesOut,
                                    MTAudioProcessingTapFlags *flagsOut) {
  (void)flags;
  OSStatus status = MTAudioProcessingTapGetSourceAudio(
      tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
  if (status != noErr || !numberFramesOut || *numberFramesOut == 0) {
    return;
  }

  VolumeBoostYTTapContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (!context) {
    return;
  }

  const AudioStreamBasicDescription *format = &context->format;
  if (!(format->mFormatFlags & kAudioFormatFlagIsFloat) ||
      format->mBitsPerChannel != 32) {
    return;
  }

  Float32 targetGain = GetLogarithmicAudioMultiplier();
  Float32 envelope = context->envelope > 0.0f ? context->envelope : 1.0f;
  // Fast attack catches peaks quickly. Slower release avoids pumping.
  const Float32 attack = 0.08f;
  const Float32 release = 0.003f;
  const Float32 drive = 1.5f;
  const Float32 tanhNormalization = tanhf(drive);
  Float32 peak = 0.0f;
  UInt32 totalSampleCount = 0;

  for (UInt32 bufferIndex = 0; bufferIndex < bufferListInOut->mNumberBuffers;
       bufferIndex++) {
    AudioBuffer buffer = bufferListInOut->mBuffers[bufferIndex];
    Float32 *samples = (Float32 *)buffer.mData;
    if (!samples) {
      continue;
    }

    UInt32 sampleCount = (UInt32)(buffer.mDataByteSize / sizeof(Float32));
    if (sampleCount == 0) {
      continue;
    }

    Float32 bufferPeak = 0.0f;
    vDSP_maxmgv(samples, 1, &bufferPeak, sampleCount);
    peak = fmaxf(peak, bufferPeak);
    totalSampleCount += sampleCount;
  }

  Float32 desiredGain = targetGain;
  if (peak > 0.0001f) {
    Float32 limiterGain = 0.92f / peak;
    desiredGain = fminf(targetGain, limiterGain);
  }

  if (desiredGain < envelope) {
    envelope += (desiredGain - envelope) * attack;
  } else {
    envelope += (desiredGain - envelope) * release;
  }

  if (totalSampleCount == 0 || !context->scratchBuffer) {
    context->envelope = envelope;
    return;
  }

  Float32 rampGain = context->envelope;
  Float32 gainStep = (envelope - context->envelope) / totalSampleCount;

  for (UInt32 bufferIndex = 0; bufferIndex < bufferListInOut->mNumberBuffers;
       bufferIndex++) {
    AudioBuffer buffer = bufferListInOut->mBuffers[bufferIndex];
    Float32 *samples = (Float32 *)buffer.mData;
    if (!samples) {
      continue;
    }

    UInt32 sampleCount = (UInt32)(buffer.mDataByteSize / sizeof(Float32));
    if (sampleCount == 0 || sampleCount > context->scratchCapacity) {
      continue;
    }

    vDSP_vrampmul(samples, 1, &rampGain, &gainStep, samples, 1, sampleCount);
    vDSP_vsmul(samples, 1, &drive, context->scratchBuffer, 1, sampleCount);
    int sampleCountInt = (int)sampleCount;
    vvtanhf(context->scratchBuffer, context->scratchBuffer, &sampleCountInt);
    vDSP_vsdiv(context->scratchBuffer, 1, &tanhNormalization, samples, 1,
               sampleCount);
  }

  context->envelope = envelope;
}

// Helper to get current volume multiplier
static float GetCustomVolumeMultiplier() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if (IsVolumePersistenceEnabled()) {
    if ([defaults objectForKey:kCustomYouTubeVolumeScalarKey] == nil) {
      return GetConfiguredDefaultVolumeMultiplier();
    }
    return [defaults floatForKey:kCustomYouTubeVolumeScalarKey];
  }

  if (currentVolumeMultiplier < 0.0f) {
    currentVolumeMultiplier = GetConfiguredDefaultVolumeMultiplier();
  }
  return currentVolumeMultiplier;
}

static float GetLogarithmicAudioMultiplier() {
  float m = GetCustomVolumeMultiplier();
  if (m <= 1.0f) {
    return m;
  }
  // This is the fallback curve for players that cannot use our sample tap.
  // Keep it conservative so non-tap playback still sounds reasonably smooth.
  static const float kMaxSafeAudioGain = 4.0f;
  float normalized = (m - 1.0f) / 19.0f;
  float eased = 1.0f - powf(1.0f - normalized, 2.0f);
  return 1.0f + eased * (kMaxSafeAudioGain - 1.0f);
}

static BOOL HasVolumeBoostYTTap(id playerItem) {
  return [objc_getAssociatedObject(playerItem, kVolumeBoostYTTapInstalledKey)
      boolValue];
}

static void InstallVolumeBoostYTTapOnPlayerItem(AVPlayerItem *playerItem) {
  if (!playerItem || HasVolumeBoostYTTap(playerItem)) {
    return;
  }

  // Some streaming paths expose the player item before audio tracks are ready.
  // In that case we leave it unmarked and retry later from AVPlayer hooks.
  AVAsset *asset = playerItem.asset;
  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  if (audioTracks.count == 0) {
    return;
  }

  MTAudioProcessingTapCallbacks callbacks;
  callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
  callbacks.clientInfo = NULL;
  callbacks.init = VolumeBoostYTTapInit;
  callbacks.finalize = VolumeBoostYTTapFinalize;
  callbacks.prepare = VolumeBoostYTTapPrepare;
  callbacks.unprepare = VolumeBoostYTTapUnprepare;
  callbacks.process = VolumeBoostYTTapProcess;

  AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
  NSMutableArray *inputParameters = [NSMutableArray array];

  for (AVAssetTrack *track in audioTracks) {
    AVMutableAudioMixInputParameters *params =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(
        kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
        &tap);
    if (status == noErr && tap) {
      params.audioTapProcessor = tap;
      CFRelease(tap);
      [inputParameters addObject:params];
    }
  }

  if (inputParameters.count == 0) {
    return;
  }

  audioMix.inputParameters = inputParameters;
  playerItem.audioMix = audioMix;
  objc_setAssociatedObject(playerItem, kVolumeBoostYTTapInstalledKey, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void NotifyVolumeChange() {
  for (id renderer in [activeRenderers allObjects]) {
    if ([renderer respondsToSelector:@selector(setVolume:)]) {
      // Re-apply base volume 1.0, which then gets intercepted by our hook to
      // apply the multiplier
      [renderer setVolume:1.0f];
    }
  }
}

static void SetCustomVolumeMultiplier(float multiplier) {
  multiplier = ClampVolumeMultiplier(multiplier);

  if (IsVolumePersistenceEnabled()) {
    [[NSUserDefaults standardUserDefaults]
        setFloat:multiplier
          forKey:kCustomYouTubeVolumeScalarKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
  } else {
    currentVolumeMultiplier = multiplier;
  }

  NotifyVolumeChange();
}

static void SetConfiguredDefaultVolumeMultiplier(float multiplier) {
  multiplier = ClampVolumeMultiplier(multiplier);

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setFloat:multiplier forKey:kVolumeBoostYTDefaultVolumeScalarKey];

  if (IsVolumePersistenceEnabled()) {
    [defaults setFloat:multiplier forKey:kCustomYouTubeVolumeScalarKey];
  } else {
    currentVolumeMultiplier = multiplier;
  }

  [defaults synchronize];
  NotifyVolumeChange();
}

static UIViewController *TopViewController(UIViewController *viewController) {
  UIViewController *top = viewController;
  while (top.presentedViewController) {
    top = top.presentedViewController;
  }
  return top;
}

// -----------------------------------------------------
// High level AVFoundation / MediaPlayer Hooks
// -----------------------------------------------------

%hook AVPlayer
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
  InstallVolumeBoostYTTapOnPlayerItem(item);
  id orig = %orig(item);
  RegisterRenderer(orig);
  return orig;
}
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
  InstallVolumeBoostYTTapOnPlayerItem(item);
  %orig(item);
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  AVPlayerItem *currentItem = [self currentItem];
  if (IsVolumeBoostYTEnabled() && currentItem &&
      !HasVolumeBoostYTTap(currentItem)) {
    InstallVolumeBoostYTTapOnPlayerItem(currentItem);
  }
  if (IsVolumeBoostYTEnabled() &&
      !HasVolumeBoostYTTap(currentItem)) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVPlayerItem
- (instancetype)initWithAsset:(AVAsset *)asset {
  id orig = %orig(asset);
  InstallVolumeBoostYTTapOnPlayerItem(orig);
  return orig;
}
- (instancetype)initWithAsset:(AVAsset *)asset
    automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
  id orig = %orig(asset, keys);
  InstallVolumeBoostYTTapOnPlayerItem(orig);
  return orig;
}
%end

%hook AVAudioPlayerNode
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayer
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVSampleBufferAudioRenderer
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

    // -----------------------------------------------------
    // UI Hooks for Configuration (Native Touch Tracking via sendEvent:)
    // -----------------------------------------------------

    static float gestureStartMultiplier = 1.0f;
static BOOL possibleVolumeGesture = NO;
static BOOL isTrackingVolumeGesture = NO;
static CGPoint initialTouchPoint;

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  // Escape early if tweak is globally disabled in YouTube settings
  if (!IsVolumeBoostYTEnabled()) {
    %orig(event);
    return;
  }

  // Only track touches from the main screen
  if (self.screen != [UIScreen mainScreen]) {
    %orig(event);
    return;
  }

  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0) {
    %orig(event);
    return;
  }

  UITouch *touch = [touches anyObject];
  CGPoint location = [touch locationInView:self];

  switch (touch.phase) {
  case UITouchPhaseBegan: {
    // Check if the touch is within 25 points of the right edge
    CGFloat screenWidth = self.bounds.size.width;
    if (location.x >= screenWidth - 25.0f) {
      possibleVolumeGesture = YES;
      isTrackingVolumeGesture = NO;
      initialTouchPoint = location;
      return; // Swallow the touch, start evaluating gesture
    }
    break;
  }
  case UITouchPhaseMoved: {
    if (possibleVolumeGesture) {
      CGFloat dx = initialTouchPoint.x - location.x; // Positive if moving left
      CGFloat dy = fabs(location.y - initialTouchPoint.y);

      // Require moving left (inwards) by at least 15 points before locking in
      if (dx > 15.0f && dx > dy) {
        isTrackingVolumeGesture = YES;
        possibleVolumeGesture = NO;

        // Lock in! Now calculate relative vertical drag from this exact point
        initialTouchPoint = location;
        gestureStartMultiplier = GetCustomVolumeMultiplier();
        [[YTVolumeHUD sharedHUD] showWithValue:gestureStartMultiplier];
        return; // Swallow
      } else if (dy > 20.0f || dx < -10.0f) {
        // Failed gesture (moved up/down too early, or moved further right off
        // screen)
        possibleVolumeGesture = NO;
      } else {
        return; // Still evaluating, swallow touch
      }
    }

    if (isTrackingVolumeGesture) {
      CGFloat translationY = location.y - initialTouchPoint.y;

      // Sweeping vertically up (negative Y) increases volume
      // A full 570-point swipe upward reaches the 20x multiplier
      float deltaMultiplier = -translationY / 30.0f;
      float newMultiplier = gestureStartMultiplier + deltaMultiplier;
      newMultiplier = ClampVolumeMultiplier(newMultiplier);

      SetCustomVolumeMultiplier(newMultiplier);
      [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
      return; // Swallow the touch
    }
    break;
  }
  case UITouchPhaseEnded:
  case UITouchPhaseCancelled: {
    if (possibleVolumeGesture) {
      possibleVolumeGesture = NO;
      return; // Swallowed aborted tap
    }
    if (isTrackingVolumeGesture) {
      isTrackingVolumeGesture = NO;
      [[YTVolumeHUD sharedHUD] performSelector:@selector(hide)
                                    withObject:nil
                                    afterDelay:1.0];
      return; // Swallow the touch
    }
    break;
  }
  default:
    break;
  }

  // Pass the event to the app if we are not tracking our custom gesture
  %orig(event);
}
%end

        // -----------------------------------------------------
        // YouTube In-App Settings Integration
        // -----------------------------------------------------

        %group YouTubeSettings

        %hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  // Only inject into the main settings group (type 1)
  if (self.type != 1)
    return %orig;

  // If another tweak (YouGroupSettings) handles grouping, let it do so
  Class settingsGroupDataClass = objc_getClass("YTSettingsGroupData");
  if (class_getClassMethod(settingsGroupDataClass, @selector(tweaks)) &&
      [settingsGroupDataClass respondsToSelector:@selector(tweaks)]) {
    NSArray<NSNumber *> *tweaks =
        [settingsGroupDataClass performSelector:@selector(tweaks)];
    if ([tweaks containsObject:@(TweakSection)]) {
      return %orig;
    }
  }

  NSMutableArray *mutableCategories = %orig.mutableCopy;
  if (mutableCategories &&
      ![mutableCategories containsObject:@(TweakSection)]) {
    // Insert our tweak section near the top
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
  }
  return mutableCategories.copy ?: %orig;
}

%end

        %hook YTAppSettingsPresentationData

    + (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  NSUInteger insertIndex = [order indexOfObject:@(1)];

  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }

  return order ?: %orig;
}

%end

        %hook YTSettingsSectionItemManager

        %new(v@:@)
    - (void)updateVolumeBoostYTSectionWithEntry:(id)entry {
  NSMutableArray<YTSettingsSectionItem *> *sectionItems =
      [NSMutableArray array];
  Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);

  // Fallback if class not available (though it should be)
  if (!YTSettingsSectionItemClass)
    return;

  YTSettingsViewController *settingsViewController =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:@"Allow custom right-edge pan volume gesture"
      accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTEnabledKey];
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    NotifyVolumeChange();
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enableTweak];

  YTSettingsSectionItem *rememberBoost = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Remember boost"
             titleDescription:
                 @"When enabled, gesture changes become the new default after restart"
      accessibilityIdentifier:nil
                     switchOn:IsVolumePersistenceEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    NSUserDefaults *defaults =
                        [NSUserDefaults standardUserDefaults];
                    float currentMultiplier = GetCustomVolumeMultiplier();
                    [defaults setBool:enabled
                               forKey:kVolumeBoostYTPersistenceEnabledKey];

                    if (enabled) {
                      [defaults setFloat:currentMultiplier
                                  forKey:kCustomYouTubeVolumeScalarKey];
                    } else {
                      [defaults removeObjectForKey:kCustomYouTubeVolumeScalarKey];
                      currentVolumeMultiplier = currentMultiplier;
                    }

                    [defaults synchronize];
                    NotifyVolumeChange();
                    return YES;
                  }
                settingItemId:1];
  [sectionItems addObject:rememberBoost];

  NSString *defaultBoostDescription =
      @"Tap to choose the startup boost for all videos";

  YTSettingsSectionItem *defaultBoostEditor = [YTSettingsSectionItemClass
          itemWithTitle:@"Default boost"
             titleDescription:defaultBoostDescription
      accessibilityIdentifier:nil
              detailTextBlock:^NSString * {
                return FormattedVolumePercentage(
                    GetConfiguredDefaultVolumeMultiplier());
              }
                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"Default boost"
                                         message:
                                             @"Enter the startup volume boost percentage (0-2000)."
                                  preferredStyle:
                                      UIAlertControllerStyleAlert];

                    [alert addTextFieldWithConfigurationHandler:^(
                               UITextField *textField) {
                      textField.keyboardType =
                          UIKeyboardTypeNumbersAndPunctuation;
                      textField.placeholder = @"100";
                      textField.text = [NSString
                          stringWithFormat:@"%.0f",
                                           GetConfiguredDefaultVolumeMultiplier() *
                                               100.0f];
                    }];

                    [alert
                        addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];

                    __weak typeof(self) weakSelf = self;
                    [alert addAction:[UIAlertAction
                                         actionWithTitle:@"Save"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(
                                                     UIAlertAction *action) {
                                                   UITextField *textField =
                                                       alert.textFields
                                                           .firstObject;
                                                   float percentage =
                                                       [textField.text floatValue];
                                                   if (percentage < 0.0f)
                                                     percentage = 0.0f;
                                                   if (percentage > 2000.0f)
                                                     percentage = 2000.0f;

                                                   SetConfiguredDefaultVolumeMultiplier(
                                                       percentage / 100.0f);

                                                   if (weakSelf) {
                                                     [weakSelf
                                                         updateVolumeBoostYTSectionWithEntry:
                                                             entry];
                                                   }
                                                 }]];

                    UIViewController *presentingController =
                        TopViewController(settingsViewController);
                    if (!presentingController && cell.window) {
                      presentingController =
                          TopViewController(cell.window.rootViewController);
                    }

                    if (!presentingController) {
                      return NO;
                    }

                    [presentingController presentViewController:alert
                                                       animated:YES
                                                     completion:nil];
                    return YES;
                  }
                ];
  [sectionItems addObject:defaultBoostEditor];

  if ([settingsViewController
          respondsToSelector:@selector
          (setSectionItems:
               forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector
                 (setSectionItems:
                      forCategory:title:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                           titleDescription:nil
                               headerHidden:NO];
  }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
  if (category == TweakSection) {
    [self updateVolumeBoostYTSectionWithEntry:entry];
    return;
  }
  %orig;
}

%end

    %end // end group YouTubeSettings

static BOOL IsYouTubeProcess() {
  return NSClassFromString(@"YTSettingsGroupData") != nil ||
         NSClassFromString(@"YTPlayerViewController") != nil;
}

static BOOL HasYouTubeSettingsClasses() {
  return NSClassFromString(@"YTSettingsGroupData") != nil &&
         NSClassFromString(@"YTAppSettingsPresentationData") != nil &&
         NSClassFromString(@"YTSettingsSectionItemManager") != nil &&
         NSClassFromString(@"YTSettingsSectionItem") != nil;
}

%ctor {
  // Never inject into SpringBoard (Home Screen)
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    return;
  }

  // Only initialize inside a YouTube process. Sideloaded builds may use
  // different bundle identifiers, so class presence is safer than bundle ID.
  if (!IsYouTubeProcess()) {
    return;
  }

  // Settings integration is optional and should only load when the full set of
  // expected YouTube settings classes is available.
  if (HasYouTubeSettingsClasses()) {
    %init(YouTubeSettings);
  }

  // Core player and gesture hooks are only intended for YouTube itself.
  %init;
}
