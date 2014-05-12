//
//  GoogleSTT.h
//  CoreAudioExp
//
//  Created by DevLife1978 on 2014. 5. 8..
//  Copyleft for everyone.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

#define kNumberBuffers 3
#define kNumVolumeSamples 10
#define kSilenceThresholdDB -30.0

#define kVolumeSamplingInterval 0.05
#define kSilenceTimeThreshold 3
#define kSilenceThresholdNumSamples kSilenceTimeThreshold / kVolumeSamplingInterval

// For scaling display
#define kMinVolumeSampleValue 0.01
#define kMaxVolumeSampleValue 1.0

@protocol GoogleSTTDelegate;

@interface GoogleSTT : NSObject

@property (nonatomic, assign) id<GoogleSTTDelegate> delegate;
@property (nonatomic, readonly) NSURL *voiceFileURL;
@property (nonatomic, readonly) CGFloat currentVolumePeak;
@property (nonatomic, assign) NSString *languageCode;
@property (nonatomic, readonly) BOOL audioInputAvailable;

- (void)prepareRecording:(void (^)(BOOL granted))prepareBlock;

- (void)startRecording;
- (void)stopRecording;
- (BOOL)recording;

@end

@protocol GoogleSTTDelegate <NSObject>

- (void)googleSTTRequested;
- (void)googleSTTResult:(NSArray *)translates;

- (void)googleSTTRecordingFinished;
- (void)googleSTTRecordingPitch:(CGFloat)pitch
                   timeInterval:(CGFloat)timeInterval;

@end