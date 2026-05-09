#import "YTVolumeHUD.h"
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>
#import <objc/runtime.h>
#import <stdatomic.h>

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
static NSString *const kVolumeBoostYTFallbackEnabledKey =
    @"VolumeBoostYTFallbackEnabled";
static NSString *const kVolumeBoostYTDefaultVolumeScalarKey =
    @"VolumeBoostYTDefaultVolumeScalar";
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";
static NSString *const kVolumeBoostYTBassAmountKey =
    @"VolumeBoostYTBassAmount";
static NSString *const kVolumeBoostYTLoudnessAmountKey =
    @"VolumeBoostYTLoudnessAmount";
static NSString *const kVolumeBoostYTClarityAmountKey =
    @"VolumeBoostYTClarityAmount";
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

static BOOL IsFallbackBoostEnabled() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTFallbackEnabledKey] == nil) {
    return YES; // Default to keeping the safety-net fallback enabled
  }
  return [defaults boolForKey:kVolumeBoostYTFallbackEnabledKey];
}

static float ClampVolumeMultiplier(float multiplier);
static float GetLogarithmicAudioMultiplier(void);
static float ClampUnitInterval(float value);
static float GetBassAmount(void);
static float GetLoudnessAmount(void);
static float GetClarityAmount(void);
static void NotifyVolumeChange(void);

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

static NSString *FormattedEffectPercentage(float amount) {
  return [NSString stringWithFormat:@"%.0f%%", amount * 100.0f];
}

static float ClampVolumeMultiplier(float multiplier) {
  if (multiplier < 0.0f)
    return 0.0f;
  if (multiplier > 20.0f)
    return 20.0f;
  return multiplier;
}

static float ClampUnitInterval(float value) {
  if (value < 0.0f)
    return 0.0f;
  if (value > 1.0f)
    return 1.0f;
  return value;
}

static float GetEffectAmountForKey(NSString *key, float defaultValue) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:key] == nil) {
    return defaultValue;
  }
  return ClampUnitInterval([defaults floatForKey:key]);
}

static void SetEffectAmountForKey(NSString *key, float amount) {
  [[NSUserDefaults standardUserDefaults] setFloat:ClampUnitInterval(amount)
                                           forKey:key];
  [[NSUserDefaults standardUserDefaults] synchronize];
  NotifyVolumeChange();
}

static float GetBassAmount(void) {
  return GetEffectAmountForKey(kVolumeBoostYTBassAmountKey, 0.6f);
}

static float GetLoudnessAmount(void) {
  return GetEffectAmountForKey(kVolumeBoostYTLoudnessAmountKey, 0.65f);
}

static float GetClarityAmount(void) {
  return GetEffectAmountForKey(kVolumeBoostYTClarityAmountKey, 0.45f);
}

static float currentVolumeMultiplier = -1.0f;

static NSHashTable *activeRenderers = nil;

// The tap keeps just enough state to smooth gain changes across frames.
typedef struct {
  AudioStreamBasicDescription format;
  Float32 envelope;
  Float32 *scratchBuffer;
  UInt32 scratchCapacity;
  Float32 *bassState;
  UInt32 bassStateChannelCount;
  Float32 *compressorState;
  UInt32 compressorStateChannelCount;
  Float32 *presenceState;
  UInt32 presenceStateChannelCount;
  Float32 *limiterEnvelopeState;
  UInt32 limiterEnvelopeChannelCount;
  Float32 *limiterDelayBuffer;
  UInt32 limiterDelayCapacity;
  UInt32 limiterDelaySamples;
  UInt32 limiterWriteIndex;
} VolumeBoostYTDSPContext;

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
  VolumeBoostYTDSPContext *context =
      calloc(1, sizeof(VolumeBoostYTDSPContext));
  context->envelope = 1.0f;
  *tapStorageOut = context;
}

static void VolumeBoostYTTapFinalize(MTAudioProcessingTapRef tap) {
  VolumeBoostYTDSPContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (context) {
    if (context->limiterDelayBuffer) {
      free(context->limiterDelayBuffer);
    }
    if (context->limiterEnvelopeState) {
      free(context->limiterEnvelopeState);
    }
    if (context->presenceState) {
      free(context->presenceState);
    }
    if (context->compressorState) {
      free(context->compressorState);
    }
    if (context->bassState) {
      free(context->bassState);
    }
    if (context->scratchBuffer) {
      free(context->scratchBuffer);
    }
    free(context);
  }
}

static void EnsureBassStateCapacity(VolumeBoostYTDSPContext *context,
                                    UInt32 channelCount) {
  if (!context || channelCount == 0 ||
      channelCount <= context->bassStateChannelCount) {
    return;
  }

  Float32 *newState =
      realloc(context->bassState, channelCount * sizeof(Float32));
  if (!newState) {
    return;
  }

  for (UInt32 index = context->bassStateChannelCount; index < channelCount;
       index++) {
    newState[index] = 0.0f;
  }

  context->bassState = newState;
  context->bassStateChannelCount = channelCount;
}

static void EnsureCompressorStateCapacity(VolumeBoostYTDSPContext *context,
                                          UInt32 channelCount) {
  if (!context || channelCount == 0 ||
      channelCount <= context->compressorStateChannelCount) {
    return;
  }

  Float32 *newState =
      realloc(context->compressorState, channelCount * sizeof(Float32));
  if (!newState) {
    return;
  }

  for (UInt32 index = context->compressorStateChannelCount;
       index < channelCount; index++) {
    newState[index] = 0.0f;
  }

  context->compressorState = newState;
  context->compressorStateChannelCount = channelCount;
}

static void EnsurePresenceStateCapacity(VolumeBoostYTDSPContext *context,
                                        UInt32 channelCount) {
  if (!context || channelCount == 0 ||
      channelCount <= context->presenceStateChannelCount) {
    return;
  }

  Float32 *newState =
      realloc(context->presenceState, channelCount * sizeof(Float32));
  if (!newState) {
    return;
  }

  for (UInt32 index = context->presenceStateChannelCount; index < channelCount;
       index++) {
    newState[index] = 0.0f;
  }

  context->presenceState = newState;
  context->presenceStateChannelCount = channelCount;
}

static void EnsureLimiterStateCapacity(VolumeBoostYTDSPContext *context,
                                       UInt32 channelCount,
                                       UInt32 delaySamples) {
  if (!context || channelCount == 0 || delaySamples == 0) {
    return;
  }

  if (channelCount > context->limiterEnvelopeChannelCount) {
    Float32 *newEnvelope =
        realloc(context->limiterEnvelopeState, channelCount * sizeof(Float32));
    if (newEnvelope) {
      for (UInt32 index = context->limiterEnvelopeChannelCount;
           index < channelCount; index++) {
        newEnvelope[index] = 1.0f;
      }
      context->limiterEnvelopeState = newEnvelope;
      context->limiterEnvelopeChannelCount = channelCount;
    }
  }

  UInt32 requiredCapacity = channelCount * delaySamples;
  if (requiredCapacity > context->limiterDelayCapacity) {
    Float32 *newDelayBuffer =
        realloc(context->limiterDelayBuffer, requiredCapacity * sizeof(Float32));
    if (newDelayBuffer) {
      for (UInt32 index = context->limiterDelayCapacity; index < requiredCapacity;
           index++) {
        newDelayBuffer[index] = 0.0f;
      }
      context->limiterDelayBuffer = newDelayBuffer;
      context->limiterDelayCapacity = requiredCapacity;
    }
  }

  if (context->limiterDelaySamples != delaySamples) {
    context->limiterDelaySamples = delaySamples;
    context->limiterWriteIndex = 0;
    if (context->limiterDelayBuffer) {
      memset(context->limiterDelayBuffer, 0,
             context->limiterDelayCapacity * sizeof(Float32));
    }
    if (context->limiterEnvelopeState) {
      for (UInt32 index = 0; index < context->limiterEnvelopeChannelCount;
           index++) {
        context->limiterEnvelopeState[index] = 1.0f;
      }
    }
  }
}

static void ApplyBassEnhancement(Float32 *samples, UInt32 sampleCount,
                                 UInt32 channelCount, Float64 sampleRate,
                                 Float32 *channelState) {
  if (!samples || sampleCount == 0 || channelCount == 0 || !channelState ||
      sampleRate <= 0.0) {
    return;
  }

  Float32 bassAmount = GetBassAmount();
  if (bassAmount <= 0.001f) {
    return;
  }

  const Float32 bassCutoffHz = 180.0f;
  const Float32 bassMix = 0.05f + 0.25f * bassAmount;
  const Float32 bassClamp = 0.35f;
  Float32 smoothing =
      expf((Float32)(-2.0 * M_PI * bassCutoffHz / sampleRate));
  smoothing = fminf(fmaxf(smoothing, 0.0f), 0.995f);
  Float32 follow = 1.0f - smoothing;

  for (UInt32 frameIndex = 0; frameIndex < sampleCount; frameIndex += channelCount) {
    for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      UInt32 sampleIndex = frameIndex + channelIndex;
      Float32 lowBand = channelState[channelIndex] +
                        follow * (samples[sampleIndex] - channelState[channelIndex]);
      channelState[channelIndex] = lowBand;
      Float32 boosted = samples[sampleIndex] + lowBand * bassMix;
      samples[sampleIndex] = fminf(fmaxf(boosted, -1.0f - bassClamp),
                                   1.0f + bassClamp);
    }
  }
}

static void ApplyLoudnessCompressor(Float32 *samples, UInt32 sampleCount,
                                    UInt32 channelCount, Float64 sampleRate,
                                    Float32 *channelState) {
  if (!samples || sampleCount == 0 || channelCount == 0 || !channelState ||
      sampleRate <= 0.0) {
    return;
  }

  Float32 loudnessAmount = GetLoudnessAmount();
  if (loudnessAmount <= 0.001f) {
    return;
  }

  const Float32 threshold = 0.72f - 0.28f * loudnessAmount;
  const Float32 ratio = 1.4f + 2.8f * loudnessAmount;
  const Float32 makeupGain = 1.0f + 0.28f * loudnessAmount;
  const Float32 attackMs = 8.0f;
  const Float32 releaseMs = 140.0f;
  const Float32 attack =
      expf(-1.0f / (Float32)(sampleRate * attackMs * 0.001f));
  const Float32 release =
      expf(-1.0f / (Float32)(sampleRate * releaseMs * 0.001f));

  for (UInt32 frameIndex = 0; frameIndex < sampleCount;
       frameIndex += channelCount) {
    for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      UInt32 sampleIndex = frameIndex + channelIndex;
      Float32 sample = samples[sampleIndex];
      Float32 level = fabsf(sample);
      Float32 detector = channelState[channelIndex];

      if (level > detector) {
        detector = attack * detector + (1.0f - attack) * level;
      } else {
        detector = release * detector + (1.0f - release) * level;
      }
      channelState[channelIndex] = detector;

      Float32 gain = makeupGain;
      if (detector > threshold) {
        Float32 compressedLevel =
            threshold + (detector - threshold) / ratio;
        gain *= compressedLevel / detector;
      }

      samples[sampleIndex] = sample * gain;
    }
  }
}

static void ApplyPresenceEnhancement(Float32 *samples, UInt32 sampleCount,
                                     UInt32 channelCount, Float64 sampleRate,
                                     Float32 *channelState) {
  if (!samples || sampleCount == 0 || channelCount == 0 || !channelState ||
      sampleRate <= 0.0) {
    return;
  }

  Float32 clarityAmount = GetClarityAmount();
  if (clarityAmount <= 0.001f) {
    return;
  }

  const Float32 presenceCutoffHz = 1800.0f;
  const Float32 presenceMix = 0.32f * clarityAmount;
  Float32 smoothing =
      expf((Float32)(-2.0 * M_PI * presenceCutoffHz / sampleRate));
  smoothing = fminf(fmaxf(smoothing, 0.0f), 0.999f);
  Float32 follow = 1.0f - smoothing;

  for (UInt32 frameIndex = 0; frameIndex < sampleCount;
       frameIndex += channelCount) {
    for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      UInt32 sampleIndex = frameIndex + channelIndex;
      Float32 lowBand = channelState[channelIndex] +
                        follow *
                            (samples[sampleIndex] - channelState[channelIndex]);
      channelState[channelIndex] = lowBand;
      Float32 highBand = samples[sampleIndex] - lowBand;
      samples[sampleIndex] += highBand * presenceMix;
    }
  }
}

static void ApplyLookaheadLimiter(Float32 *samples, UInt32 sampleCount,
                                  UInt32 channelCount,
                                  UInt32 channelOffset,
                                  VolumeBoostYTDSPContext *context) {
  if (!samples || sampleCount == 0 || channelCount == 0 || !context ||
      !context->limiterEnvelopeState || !context->limiterDelayBuffer ||
      context->limiterDelaySamples == 0) {
    return;
  }

  const Float32 ceiling = 0.96f;
  const Float32 releaseMs = 85.0f;
  Float64 sampleRate = context->format.mSampleRate;
  if (sampleRate <= 0.0) {
    return;
  }

  Float32 release =
      expf(-1.0f / (Float32)(sampleRate * releaseMs * 0.001f));
  UInt32 delaySamples = context->limiterDelaySamples;
  UInt32 writeIndex = context->limiterWriteIndex;

  for (UInt32 frameIndex = 0; frameIndex < sampleCount;
       frameIndex += channelCount) {
    for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      UInt32 sampleIndex = frameIndex + channelIndex;
      UInt32 stateChannelIndex = channelOffset + channelIndex;
      UInt32 delayIndex = stateChannelIndex * delaySamples + writeIndex;
      Float32 delayedSample = context->limiterDelayBuffer[delayIndex];
      context->limiterDelayBuffer[delayIndex] = samples[sampleIndex];

      Float32 targetGain = 1.0f;
      Float32 level = fabsf(samples[sampleIndex]);
      if (level > ceiling) {
        targetGain = ceiling / level;
      }

      Float32 envelope = context->limiterEnvelopeState[stateChannelIndex];
      if (targetGain < envelope) {
        envelope = targetGain;
      } else {
        envelope = release * envelope + (1.0f - release) * targetGain;
      }
      context->limiterEnvelopeState[stateChannelIndex] = envelope;
      samples[sampleIndex] = delayedSample * envelope;
    }

    writeIndex++;
    if (writeIndex >= delaySamples) {
      writeIndex = 0;
    }
  }

  context->limiterWriteIndex = writeIndex;
}




static void VolumeBoostYTTapPrepare(MTAudioProcessingTapRef tap,
                                    CMItemCount maxFrames,
                                    const AudioStreamBasicDescription *processingFormat) {
  (void)tap;
  VolumeBoostYTDSPContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (context && processingFormat) {
    context->format = *processingFormat;
    context->envelope = 1.0f;
    UInt32 channels = MAX((UInt32)processingFormat->mChannelsPerFrame, 1U);
    UInt32 lookaheadSamples =
        (UInt32)fmin(fmax(processingFormat->mSampleRate * 0.003, 32.0), 256.0);
    EnsureBassStateCapacity(context, channels);
    EnsureCompressorStateCapacity(context, channels);
    EnsurePresenceStateCapacity(context, channels);
    EnsureLimiterStateCapacity(context, channels, lookaheadSamples);
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

  VolumeBoostYTDSPContext *context =
      MTAudioProcessingTapGetStorage(tap);
  if (!context) {
    return;
  }

  const AudioStreamBasicDescription *format = &context->format;
  if (!(format->mFormatFlags & kAudioFormatFlagIsFloat) ||
      format->mBitsPerChannel != 32) {
    return;
  }

  const BOOL isNonInterleaved =
      (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  
  UInt32 totalSampleCount = 0;
  for (UInt32 bufferIndex = 0; bufferIndex < bufferListInOut->mNumberBuffers; bufferIndex++) {
    UInt32 sampleCount = (UInt32)(bufferListInOut->mBuffers[bufferIndex].mDataByteSize / sizeof(Float32));
    totalSampleCount += sampleCount;
  }
  if (totalSampleCount == 0) {
    return;
  }

  UInt32 channelCursor = 0;

  for (UInt32 bufferIndex = 0; bufferIndex < bufferListInOut->mNumberBuffers;
       bufferIndex++) {
    AudioBuffer buffer = bufferListInOut->mBuffers[bufferIndex];
    Float32 *samples = (Float32 *)buffer.mData;
    if (!samples) continue;

    UInt32 sampleCount = (UInt32)(buffer.mDataByteSize / sizeof(Float32));
    if (sampleCount == 0) continue;

    UInt32 bufferChannelCount = MAX((UInt32)buffer.mNumberChannels, 1U);
    if (!isNonInterleaved) {
      bufferChannelCount = MAX((UInt32)format->mChannelsPerFrame, 1U);
    }
    
    if (isNonInterleaved && bufferListInOut->mNumberBuffers > 1) {
      // Inline the original DSP chain with channelCursor offset
      Float32 targetGain = GetLogarithmicAudioMultiplier();
      Float32 envelope = context->envelope > 0.0f ? context->envelope : 1.0f;
      const Float32 attack = 0.08f;
      const Float32 release = 0.003f;
      Float32 peak = 0.0f;
      vDSP_maxmgv(samples, 1, &peak, sampleCount);
      
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
      
      Float32 rampGain = context->envelope;
      Float32 gainStep = (envelope - context->envelope) / sampleCount;
      const Float32 drive = 1.5f;
      const Float32 tanhNormalization = tanhf(drive);
      
      vDSP_vrampmul(samples, 1, &rampGain, &gainStep, samples, 1, sampleCount);
      
      EnsureBassStateCapacity(context, bufferChannelCount);
      EnsureCompressorStateCapacity(context, bufferChannelCount);
      EnsurePresenceStateCapacity(context, bufferChannelCount);
      UInt32 lookaheadSamples = (UInt32)fmin(fmax(format->mSampleRate * 0.003, 32.0), 256.0);
      EnsureLimiterStateCapacity(context, bufferChannelCount, lookaheadSamples);
      
      if (context->bassState && bufferChannelCount <= context->bassStateChannelCount) {
        ApplyBassEnhancement(samples, sampleCount, bufferChannelCount, format->mSampleRate, context->bassState + channelCursor);
      }
      if (context->compressorState && bufferChannelCount <= context->compressorStateChannelCount) {
        ApplyLoudnessCompressor(samples, sampleCount, bufferChannelCount, format->mSampleRate, context->compressorState + channelCursor);
      }
      if (context->presenceState && bufferChannelCount <= context->presenceStateChannelCount) {
        ApplyPresenceEnhancement(samples, sampleCount, bufferChannelCount, format->mSampleRate, context->presenceState + channelCursor);
      }
      
      ApplyLookaheadLimiter(samples, sampleCount, bufferChannelCount, channelCursor, context);
      
      UInt32 neededCapacity = sampleCount;
      if (neededCapacity > context->scratchCapacity) {
        Float32 *newBuf = realloc(context->scratchBuffer, neededCapacity * sizeof(Float32));
        if (newBuf) {
          context->scratchBuffer = newBuf;
          context->scratchCapacity = neededCapacity;
        }
      }
      if (context->scratchBuffer) {
        vDSP_vsmul(samples, 1, &drive, context->scratchBuffer, 1, sampleCount);
        int sampleCountInt = (int)sampleCount;
        vvtanhf(context->scratchBuffer, context->scratchBuffer, &sampleCountInt);
        vDSP_vsdiv(context->scratchBuffer, 1, &tanhNormalization, samples, 1, sampleCount);
      }
      context->envelope = envelope;
    } else {
      ApplyVolumeBoostYTDSPChain(samples, sampleCount, bufferChannelCount, format->mSampleRate, context);
    }
    
    channelCursor += bufferChannelCount;
  }
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
  
  if (IsVolumeBoostYTEnabled() && currentItem && HasVolumeBoostYTTap(currentItem)) {
    volume = 1.0f;
  } else if (IsVolumeBoostYTEnabled() && IsFallbackBoostEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
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
  if (IsVolumeBoostYTEnabled() && IsFallbackBoostEnabled()) {
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
  if (IsVolumeBoostYTEnabled() && IsFallbackBoostEnabled()) {
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


// Flag to track DSP initialization for fallback logic

@interface VolumeBoostYTRendererState : NSObject {
@public
  VolumeBoostYTDSPContext *_state;
  atomic_bool _dspActive;
  atomic_bool _hasLogged;
}
@end

@implementation VolumeBoostYTRendererState
- (instancetype)init {
  self = [super init];
  if (self) {
    _state = calloc(1, sizeof(VolumeBoostYTDSPContext));
    if (_state) {
      _state->envelope = 1.0f;
    }
    atomic_init(&_dspActive, false);
    atomic_init(&_hasLogged, false);
  }
  return self;
}

- (void)dealloc {
  if (_state) {
    if (_state->limiterDelayBuffer) free(_state->limiterDelayBuffer);
    if (_state->limiterEnvelopeState) free(_state->limiterEnvelopeState);
    if (_state->presenceState) free(_state->presenceState);
    if (_state->compressorState) free(_state->compressorState);
    if (_state->bassState) free(_state->bassState);
    if (_state->scratchBuffer) free(_state->scratchBuffer);
    free(_state);
  }
}
@end

static void ResetVolumeBoostYTDSPState(VolumeBoostYTDSPContext *context) {
  if (!context) return;
  context->envelope = 1.0f;
  if (context->bassState) {
    memset(context->bassState, 0, context->bassStateChannelCount * sizeof(Float32));
  }
  if (context->compressorState) {
    memset(context->compressorState, 0, context->compressorStateChannelCount * sizeof(Float32));
  }
  if (context->presenceState) {
    memset(context->presenceState, 0, context->presenceStateChannelCount * sizeof(Float32));
  }
  if (context->limiterDelayBuffer) {
    memset(context->limiterDelayBuffer, 0, context->limiterDelayCapacity * sizeof(Float32));
  }
  if (context->limiterEnvelopeState) {
    for (UInt32 i = 0; i < context->limiterEnvelopeChannelCount; ++i) {
      context->limiterEnvelopeState[i] = 1.0f;
    }
  }
  context->limiterWriteIndex = 0;
}

static void ApplyVolumeBoostYTDSPChain(Float32 *samples, UInt32 sampleCount, UInt32 channelCount, Float64 sampleRate, VolumeBoostYTDSPContext *state) {
  if (!samples || sampleCount == 0 || channelCount == 0 || !state) return;
  
  Float32 targetGain = GetLogarithmicAudioMultiplier();
  Float32 envelope = state->envelope > 0.0f ? state->envelope : 1.0f;
  const Float32 attack = 0.08f;
  const Float32 release = 0.003f;
  
  Float32 peak = 0.0f;
  vDSP_maxmgv(samples, 1, &peak, sampleCount);
  
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
  
  Float32 rampGain = state->envelope;
  Float32 gainStep = (envelope - state->envelope) / sampleCount;
  const Float32 drive = 1.5f;
  const Float32 tanhNormalization = tanhf(drive);
  
  vDSP_vrampmul(samples, 1, &rampGain, &gainStep, samples, 1, sampleCount);
  
  EnsureBassStateCapacity(state, channelCount);
  EnsureCompressorStateCapacity(state, channelCount);
  EnsurePresenceStateCapacity(state, channelCount);
  UInt32 lookaheadSamples = (UInt32)fmin(fmax(sampleRate * 0.003, 32.0), 256.0);
  EnsureLimiterStateCapacity(state, channelCount, lookaheadSamples);
  
  if (state->bassState && channelCount <= state->bassStateChannelCount) {
    ApplyBassEnhancement(samples, sampleCount, channelCount, sampleRate, state->bassState);
  }
  if (state->compressorState && channelCount <= state->compressorStateChannelCount) {
    ApplyLoudnessCompressor(samples, sampleCount, channelCount, sampleRate, state->compressorState);
  }
  if (state->presenceState && channelCount <= state->presenceStateChannelCount) {
    ApplyPresenceEnhancement(samples, sampleCount, channelCount, sampleRate, state->presenceState);
  }
  
  ApplyLookaheadLimiter(samples, sampleCount, channelCount, 0, state);
  
  UInt32 neededCapacity = sampleCount;
  if (neededCapacity > state->scratchCapacity) {
    Float32 *newBuf = realloc(state->scratchBuffer, neededCapacity * sizeof(Float32));
    if (newBuf) {
      state->scratchBuffer = newBuf;
      state->scratchCapacity = neededCapacity;
    }
  }
  
  if (state->scratchBuffer) {
    vDSP_vsmul(samples, 1, &drive, state->scratchBuffer, 1, sampleCount);
    int sampleCountInt = (int)sampleCount;
    vvtanhf(state->scratchBuffer, state->scratchBuffer, &sampleCountInt);
    vDSP_vsdiv(state->scratchBuffer, 1, &tanhNormalization, samples, 1, sampleCount);
  }
  
  state->envelope = envelope;
}

static const void *kVolumeBoostYTRendererContextKey = &kVolumeBoostYTRendererContextKey;

%hook AVSampleBufferAudioRenderer
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}

- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  VolumeBoostYTRendererState *wrapper = objc_getAssociatedObject(self, kVolumeBoostYTRendererContextKey);
  BOOL isActive = wrapper ? atomic_load(&wrapper->_dspActive) : NO;
  
  if (IsVolumeBoostYTEnabled() && isActive) {
    volume = 1.0f;
  } else if (IsVolumeBoostYTEnabled() && IsFallbackBoostEnabled()) {
    volume *= GetLogarithmicAudioMultiplier();
  }
  
  %orig(volume);
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  if (!sampleBuffer || !IsVolumeBoostYTEnabled() || !IsFallbackBoostEnabled()) {
    %orig(sampleBuffer);
    return;
  }
  
  CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
  if (!formatDesc) {
    %orig(sampleBuffer);
    return;
  }
  
  const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
  if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) {
    %orig(sampleBuffer);
    return;
  }
  
  if (asbd->mBytesPerFrame == 0 || asbd->mChannelsPerFrame == 0) {
    %orig(sampleBuffer);
    return;
  }
  
  if (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
    %orig(sampleBuffer);
    return;
  }
  
  BOOL isInt16 = (asbd->mBitsPerChannel == 16 && (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger));
  BOOL isFloat = (asbd->mBitsPerChannel == 32 && (asbd->mFormatFlags & kAudioFormatFlagIsFloat));
  if (!isInt16 && !isFloat) {
    %orig(sampleBuffer);
    return;
  }
  
  VolumeBoostYTRendererState *wrapper = objc_getAssociatedObject(self, kVolumeBoostYTRendererContextKey);
  if (!wrapper) {
    wrapper = [[VolumeBoostYTRendererState alloc] init];
    wrapper->_state->format = *asbd;
    objc_setAssociatedObject(self, kVolumeBoostYTRendererContextKey, wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  } else if (wrapper->_state->format.mSampleRate != asbd->mSampleRate || wrapper->_state->format.mChannelsPerFrame != asbd->mChannelsPerFrame) {
    ResetVolumeBoostYTDSPState(wrapper->_state);
    wrapper->_state->format = *asbd;
  }
  
  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (!blockBuffer) {
    %orig(sampleBuffer);
    return;
  }
  
  size_t length = CMBlockBufferGetDataLength(blockBuffer);
  if (length == 0) {
    %orig(sampleBuffer);
    return;
  }
  
  CMBlockBufferRef contiguousBuffer = NULL;
  OSStatus status = CMBlockBufferCreateContiguous(kCFAllocatorDefault, blockBuffer, kCFAllocatorDefault, NULL, 0, length, kCMBlockBufferAlwaysCopyDataFlag, &contiguousBuffer);
  if (status != noErr || !contiguousBuffer) {
    %orig(sampleBuffer);
    return;
  }
  
  char *dataPtr = NULL;
  status = CMBlockBufferGetDataPointer(contiguousBuffer, 0, NULL, &length, &dataPtr);
  if (status != noErr || !dataPtr || length == 0) {
    CFRelease(contiguousBuffer);
    %orig(sampleBuffer);
    return;
  }
  
  char *outBuf = malloc(length);
  if (!outBuf) {
    CFRelease(contiguousBuffer);
    %orig(sampleBuffer);
    return;
  }
  
  UInt32 frames = (UInt32)(length / asbd->mBytesPerFrame);
  UInt32 channels = asbd->mChannelsPerFrame;
  UInt32 totalSamples = frames * channels;
  
  Float32 *processBuffer = NULL;
  
  if (isInt16) {
    processBuffer = malloc(totalSamples * sizeof(Float32));
    if (!processBuffer) {
      free(outBuf);
      CFRelease(contiguousBuffer);
      %orig(sampleBuffer);
      return;
    }
    float scale = 1.0f / 32768.0f;
    vDSP_vflt16((SInt16 *)dataPtr, 1, processBuffer, 1, totalSamples);
    vDSP_vsmul(processBuffer, 1, &scale, processBuffer, 1, totalSamples);
  } else {
    processBuffer = (Float32 *)outBuf; // operate in place on our copied buffer
    memcpy(outBuf, dataPtr, length);
  }
  
  ApplyVolumeBoostYTDSPChain(processBuffer, totalSamples, channels, asbd->mSampleRate, wrapper->_state);
  
  if (isInt16) {
    float scale = 32768.0f;
    float maxVal = 32767.0f;
    float minVal = -32768.0f;
    vDSP_vsmul(processBuffer, 1, &scale, processBuffer, 1, totalSamples);
    vDSP_vclip(processBuffer, 1, &minVal, &maxVal, processBuffer, 1, totalSamples);
    vDSP_vfix16(processBuffer, 1, (SInt16 *)outBuf, 1, totalSamples);
    free(processBuffer);
  }
  
  CMBlockBufferRef newBlockBuffer = NULL;
  status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, outBuf, length, kCFAllocatorMalloc, NULL, 0, length, 0, &newBlockBuffer);
  if (status != noErr || !newBlockBuffer) {
    free(outBuf);
    CFRelease(contiguousBuffer);
    %orig(sampleBuffer);
    return;
  }
  
  CMSampleBufferRef newSampleBuffer = NULL;
  status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, 0, NULL, &newSampleBuffer);
  if (status == noErr && newSampleBuffer) {
    status = CMSampleBufferSetDataBuffer(newSampleBuffer, newBlockBuffer);
    if (status == noErr) {
      atomic_store(&wrapper->_dspActive, true);
      
      bool expected = false;
      if (atomic_compare_exchange_strong(&wrapper->_hasLogged, &expected, true)) {
        NSLog(@"[VolumeBoostYT] AVSampleBufferAudioRenderer DSP active: %u channels, %f Hz, %u bits", (unsigned int)asbd->mChannelsPerFrame, asbd->mSampleRate, (unsigned int)asbd->mBitsPerChannel);
      }
      
      %orig(newSampleBuffer);
      CFRelease(newSampleBuffer);
    } else {
      CFRelease(newSampleBuffer);
      %orig(sampleBuffer);
    }
  } else {
    %orig(sampleBuffer);
  }
  
  CFRelease(newBlockBuffer);
  CFRelease(contiguousBuffer);
}
%end


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

  YTSettingsSectionItem *fallbackBoost = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Fallback boost"
             titleDescription:
                 @"Apply DSP boost chain to YouTube's primary playback engine"
      accessibilityIdentifier:nil
                     switchOn:IsFallbackBoostEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTFallbackEnabledKey];
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    NotifyVolumeChange();
                    return YES;
                  }
                settingItemId:2];
  [sectionItems addObject:fallbackBoost];

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

  YTSettingsSectionItem *bassEditor = [YTSettingsSectionItemClass
          itemWithTitle:@"Bass"
             titleDescription:@"Adjust low-end emphasis in the tap-based DSP chain"
      accessibilityIdentifier:nil
              detailTextBlock:^NSString * {
                return FormattedEffectPercentage(GetBassAmount());
              }
                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"Bass"
                                         message:@"Enter bass strength (0-100)."
                                  preferredStyle:UIAlertControllerStyleAlert];

                    [alert addTextFieldWithConfigurationHandler:^(
                               UITextField *textField) {
                      textField.keyboardType =
                          UIKeyboardTypeNumbersAndPunctuation;
                      textField.placeholder = @"60";
                      textField.text =
                          [NSString stringWithFormat:@"%.0f",
                                                     GetBassAmount() * 100.0f];
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
                                                   if (percentage > 100.0f)
                                                     percentage = 100.0f;

                                                   SetEffectAmountForKey(
                                                       kVolumeBoostYTBassAmountKey,
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
  [sectionItems addObject:bassEditor];

  YTSettingsSectionItem *loudnessEditor = [YTSettingsSectionItemClass
          itemWithTitle:@"Loudness"
             titleDescription:
                 @"Adjust compression and makeup gain for perceived loudness"
      accessibilityIdentifier:nil
              detailTextBlock:^NSString * {
                return FormattedEffectPercentage(GetLoudnessAmount());
              }
                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"Loudness"
                                         message:
                                             @"Enter loudness strength (0-100)."
                                  preferredStyle:UIAlertControllerStyleAlert];

                    [alert addTextFieldWithConfigurationHandler:^(
                               UITextField *textField) {
                      textField.keyboardType =
                          UIKeyboardTypeNumbersAndPunctuation;
                      textField.placeholder = @"65";
                      textField.text = [NSString
                          stringWithFormat:@"%.0f",
                                           GetLoudnessAmount() * 100.0f];
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
                                                   if (percentage > 100.0f)
                                                     percentage = 100.0f;

                                                   SetEffectAmountForKey(
                                                       kVolumeBoostYTLoudnessAmountKey,
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
  [sectionItems addObject:loudnessEditor];

  YTSettingsSectionItem *clarityEditor = [YTSettingsSectionItemClass
          itemWithTitle:@"Clarity"
             titleDescription:@"Adjust presence boost for speech and detail"
      accessibilityIdentifier:nil
              detailTextBlock:^NSString * {
                return FormattedEffectPercentage(GetClarityAmount());
              }
                  selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"Clarity"
                                         message:@"Enter clarity strength (0-100)."
                                  preferredStyle:UIAlertControllerStyleAlert];

                    [alert addTextFieldWithConfigurationHandler:^(
                               UITextField *textField) {
                      textField.keyboardType =
                          UIKeyboardTypeNumbersAndPunctuation;
                      textField.placeholder = @"45";
                      textField.text = [NSString
                          stringWithFormat:@"%.0f",
                                           GetClarityAmount() * 100.0f];
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
                                                   if (percentage > 100.0f)
                                                     percentage = 100.0f;

                                                   SetEffectAmountForKey(
                                                       kVolumeBoostYTClarityAmountKey,
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
  [sectionItems addObject:clarityEditor];

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
