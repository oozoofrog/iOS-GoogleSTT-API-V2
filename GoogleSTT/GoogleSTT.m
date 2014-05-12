//
//  GoogleSTT.m
//  CoreAudioExp
//
//  Created by eyemac on 2014. 5. 8..
//  Copyright (c) 2014년 onsetel. All rights reserved.
//

#import "GoogleSTT.h"
#import "Constants.h"
#import <FLACiOS/all.h>

#define SAMPLE_RATE 44100
//#define SAMPLE_RATE 16000
#define DURATION 5.0
#define FILENAME_FORMAT @"stt_voice_data.wav"
#define FLAC_FORMAT @"stt_voice_data.flac"
#define GARBAGE_RESULT_VALUE @"{\"result\":[]}"

#define kSecondsForRecordBuffers 0.5
#define kNumberRecordBuffers 3

#pragma mark - user data struct

typedef struct STTRecorder
{
    GoogleSTT   *stt;
    AudioFileID recordFile;
    SInt64      recordPacket;
    Boolean     needWriting;
    Boolean     running;
    
    FLAC__StreamEncoder *encoder;
    NSMutableData *flacData;
    
    AudioQueueBufferRef buffers[kNumberRecordBuffers];
    
} STTRecorder;

@interface GoogleSTT ()<AVAudioRecorderDelegate>

@property (nonatomic, readonly) STTRecorder recorderData;
@property (nonatomic, readonly) AudioQueueRef queue;
@property (nonatomic, readonly) AudioStreamBasicDescription recordFormat;
@property (nonatomic, retain) NSTimer *meterTimer;
@property (nonatomic, retain) NSURL *voiceFileURL;
@property (nonatomic, assign) NSInteger silenceInterval;

@property (nonatomic, copy) void (^prepareBlock)(BOOL granted);

- (void)runPrepareRecordBlock:(BOOL)granted;

- (OSStatus)encoderCookieToFile;
- (int)computeBufferSize;
- (void)checkMeter;

- (void)restartAudioQueue;
- (void)stopRecordingForced;

- (void)sendToGoogleSTTAPI;

@end

@implementation GoogleSTT

static void CheckError(OSStatus error, const char *operation)
{
    if (noErr == error) {
        return;
    }
    
    char errorString[20];
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    }
    else
    {
        // No, format it as an integer
        sprintf(errorString, "%d", (int)error);
    }
    fprintf(stderr, "Error: %s (%s)\n", operation, errorString);
    
    exit(1);
}

static void STTInputCallback(void *sttData,
                             AudioQueueRef inputQueue,
                             AudioQueueBufferRef inputBuffer,
                             const AudioTimeStamp *inputStartTime,
                             UInt32 inputNumberPackets,
                             const AudioStreamPacketDescription *inputPacketDescription)
{
    STTRecorder *recorder = (STTRecorder *)sttData;
    
    if (0 < inputNumberPackets && recorder->needWriting) {
        
        unsigned char *buf = inputBuffer->mAudioData;
        
        FLAC__int32 pcm[inputNumberPackets * recorder->stt.recordFormat.mChannelsPerFrame];
        
        for (size_t i = 0; i < inputNumberPackets * recorder->stt.recordFormat.mChannelsPerFrame; i++) {
            uint16_t msb = *(uint8_t *)(buf + i * 2 + 1);
            uint16_t usample = CFSwapInt16BigToHost(msb);
            
            union {
                uint16_t usample;
                int16_t  ssample;
            } u;
            
            u.usample = usample;
            pcm[i] = u.ssample;
        }
        
        FLAC__bool success = FLAC__stream_encoder_process_interleaved(recorder->encoder, pcm, inputNumberPackets);
        if (false == success) {
            CheckError(1, "flac encode failed");
        }
    }
    if (recorder->running) {
        CheckError(AudioQueueEnqueueBuffer(inputQueue,
                                           inputBuffer,
                                           0,
                                           NULL),
                   "AudioQueueEnqeueBuffer failed");
    }
}

#pragma mark AudioSession listeners
static void interruptionListener(void   *inClientData,
                                 UInt32	inInterruptionState)
{
	STTRecorder *recorder = (STTRecorder *)inClientData;
    switch (inInterruptionState) {
        case kAudioSessionBeginInterruption:
        {
            if (recorder->running) {
                AudioQueueStart(recorder->stt.queue, NULL);
            }
        }
            break;
        case kAudioSessionEndInterruption:
        {
            AudioQueueStop(recorder->stt.queue, TRUE);
        }
            break;
        default:
            break;
    }
}

void propListener( void                     *inClientData,
                  AudioSessionPropertyID    inID,
                  UInt32                    inDataSize,
                  const void                *inData)
{
	STTRecorder *recorder = (STTRecorder *)inClientData;
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		CFDictionaryRef routeDictionary = (CFDictionaryRef)inData;

		CFNumberRef reason = (CFNumberRef)CFDictionaryGetValue(routeDictionary, CFSTR(kAudioSession_AudioRouteChangeKey_Reason));
		SInt32 reasonVal;
		CFNumberGetValue(reason, kCFNumberSInt32Type, &reasonVal);
		if (reasonVal != kAudioSessionRouteChangeReason_CategoryChange)
		{
			// stop the queue if we had a non-policy route change
			if (recorder->running) {
				[recorder->stt stopRecording];
			}
		}
	}
	else if (inID == kAudioSessionProperty_AudioInputAvailable)
	{
		if (inDataSize == sizeof(UInt32)) {
			UInt32 isAvailable = *(UInt32*)inData;
            if (0 < isAvailable) {
                NSLog(@"Audio Input Available");
                if (recorder->stt.prepareBlock) {
                    [recorder->stt runPrepareRecordBlock:YES];
                }
                else
                {
                    [recorder->stt runPrepareRecordBlock:NO];
                }
            }
		}
	}
}

FLAC__StreamEncoderWriteStatus FlacWriteCallback(const FLAC__StreamEncoder *encoder,
                                                const FLAC__byte buffer[],
                                                size_t bytes,
                                                unsigned samples,
                                                unsigned current_frame,
                                                void *client_data)
{
    STTRecorder *recorder = (STTRecorder *)client_data;
    [recorder->flacData appendBytes:buffer
                             length:bytes];
    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}

OSStatus SetupRecordFormat(AudioStreamBasicDescription *recordFormat)
{
    OSStatus error = noErr;
    recordFormat->mFormatID = kAudioFormatLinearPCM;

    // get sample rate of current device
    if (7.0 <= [[UIDevice currentDevice].systemVersion floatValue]) {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        recordFormat->mSampleRate = SAMPLE_RATE;
        recordFormat->mChannelsPerFrame = audioSession.inputNumberOfChannels;
    }
    else
    {
        UInt32 size = sizeof(recordFormat->mSampleRate);
        CheckError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                                           &size,
                                           &recordFormat->mSampleRate),
                   "Couldn't get default hardware samplerate");
        
        // get channel per frame of current device
        size = sizeof(recordFormat->mChannelsPerFrame);
        CheckError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels,
                                           &size,
                                           &recordFormat->mChannelsPerFrame),
                   "Couldn't get default input number of channels");
    }
    
    if (kAudioFormatLinearPCM == recordFormat->mFormatID) {
        recordFormat->mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        recordFormat->mBitsPerChannel = 16;
        recordFormat->mBytesPerPacket = recordFormat->mBytesPerFrame = (recordFormat->mBitsPerChannel / 8) * recordFormat->mChannelsPerFrame;
        recordFormat->mFramesPerPacket = 1;
    }
    
    return error;
}


- (OSStatus)encoderCookieToFile
{
    OSStatus error = noErr;
    
    UInt32 propertySize;
    
    error = AudioQueueGetPropertySize(_queue,
                                      kAudioQueueProperty_MagicCookie,
                                      &propertySize);
    
    if (noErr == error && 0 < propertySize) {
        Byte *magicCookie = (Byte *)malloc(propertySize);
        
        CheckError(AudioQueueGetProperty(_queue,
                                      kAudioQueueProperty_MagicCookie,
                                      &magicCookie,
                                      &propertySize), "Couldn't get magic cookie");
        
        CheckError(AudioFileSetProperty(_recorderData.recordFile,
                                     kAudioFilePropertyMagicCookieData,
                                     propertySize,
                                     magicCookie), "Couldn't set magic cookie to file");
        
        free(magicCookie);
        
        if (error) {
            return error;
        }
    }
    
    return error;
}

- (int)computeBufferSize
{
    int packets, bytes, frames;
    
    frames = (int)ceil(kSecondsForRecordBuffers * _recordFormat.mSampleRate);
    
    if (0 < _recordFormat.mBytesPerFrame) {
        bytes = frames * _recordFormat.mBytesPerFrame;
    }
    else
    {
        UInt32 maxPacketSize;
        if (0 < _recordFormat.mBytesPerPacket) {
            // Constant packet size
            maxPacketSize = _recordFormat.mBytesPerPacket;
        }
        else
        {
            // Get the largest single packet size possible
            UInt32 propertySize = sizeof(maxPacketSize);
            CheckError(AudioQueueGetProperty(_queue,
                                             kAudioQueueProperty_MaximumOutputPacketSize,
                                             &maxPacketSize,
                                             &propertySize), "Couldn't get max output packet size");
        }
        if (0 < _recordFormat.mFramesPerPacket) {
            packets = frames / _recordFormat.mFramesPerPacket;
        }
        else
        {
            // Worst case scenario : 1 frame in a packet
            packets = frames;
        }
        
        // Sanity check
        if (0 == packets) {
            packets = 1;
        }
        
        bytes = packets * maxPacketSize;
    }
    
    return bytes;
}

- (id)init
{
    self = [super init];
    if (self) {
        
        _audioInputAvailable = NO;
        
        memset(&_recorderData, 0, sizeof(STTRecorder));
    }
    return self;
}

- (void)dealloc
{
    if (_recorderData.flacData) {
        [_recorderData.flacData release];
    }
    if (self.recording) {
        [self stopRecordingForced];
    }
    self.delegate = nil;
    [super dealloc];
}

- (void)runPrepareRecordBlock:(BOOL)granted
{
    if (_prepareBlock) {
        _prepareBlock(granted);
        Block_release(_prepareBlock);
        _prepareBlock = nil;
    }
}

- (void)prepareRecording:(void (^)(BOOL))prepareBlock
{
    self.prepareBlock = prepareBlock;
    if (self.audioInputAvailable) {
        self.prepareBlock(YES);
        self.prepareBlock = nil;
        return;
    }
    
    CheckError(AudioSessionInitialize(NULL,
                                      NULL,
                                      interruptionListener,
                                      &_recorderData),
               "AudioSessionIntialize failed");
    
    UInt32 category = kAudioSessionCategory_RecordAudio;
    CheckError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                                       sizeof(category),
                                       &category), "Audio Category to Record failed");
    
    CheckError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                               propListener,
                                               &_recorderData),
               "Add Audio Session Property Listener failed");
    
    UInt32 inputAvailable = 0;
    UInt32 inputAvailableSize = sizeof(inputAvailable);
    CheckError(AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable,
                                       &inputAvailableSize,
                                       &inputAvailable), "Audio Input Available Check failed");
 
    if (0 == inputAvailable) {
        _audioInputAvailable = NO;
    }
    else
    {
        _audioInputAvailable = YES;
    }
    
    CheckError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioInputAvailable,
                                               propListener,
                                               &_recorderData),
               "Add Audio Input Available Check Listener failed");
  
    CheckError(AudioSessionSetActive(TRUE), "AudioSessionSetActive failed");
    
    if (_audioInputAvailable) {
        [self runPrepareRecordBlock:YES];
    }
}

- (void)startRecording
{
    self.silenceInterval = 0;
    
    memset(&_recorderData, 0, sizeof(STTRecorder));
    
    memset(&_recordFormat, 0, sizeof(AudioStreamBasicDescription));

    _recorderData.stt = self;
    
    _recorderData.flacData = [[NSMutableData alloc] init];
    
    // Set up format
    SetupRecordFormat(&_recordFormat);

    UInt32 propSize = sizeof(AudioStreamBasicDescription);
    CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                      0,
                                      NULL,
                                      &propSize,
                                      &_recordFormat), "AudioFormatGetProperty failed");
    
    // Set up queue
    AudioQueueRef queue = {0};
    _queue = queue;
    
    CheckError(AudioQueueNewInput(&_recordFormat,
                                  STTInputCallback,
                                  &_recorderData,
                                  NULL,
                                  NULL,
                                  0,
                                  &_queue), "AudioQueueNewInput failed");
    
    UInt32 size = sizeof(_recordFormat);
    CheckError(AudioQueueGetProperty(_queue,
                                     kAudioConverterCurrentOutputStreamDescription,
                                     &_recordFormat,
                                     &size), "Couldn't get queue's format");
    
    // Set up check level metering enable
    UInt32 enableLevelMetering = 1;
    CheckError(AudioQueueSetProperty(_queue, kAudioQueueProperty_EnableLevelMetering, &enableLevelMetering, sizeof(UInt32)), "Couldn't set enable level metering");
    
    int bufferByteSize = [self computeBufferSize];
    
    int bufferIndex;
    for (bufferIndex = 0; bufferIndex < kNumberRecordBuffers; bufferIndex++) {
        CheckError(AudioQueueAllocateBuffer(_queue, bufferByteSize, &_recorderData.buffers[bufferIndex]), "AudioQueueAllocateBuffer failed");
        CheckError(AudioQueueEnqueueBuffer(_queue, _recorderData.buffers[bufferIndex], 0, NULL), "AudioQueueEnqueueBuffer failed");
    }
    
    // setup flac
    
    FLAC__StreamEncoder *encoder = FLAC__stream_encoder_new();
    _recorderData.encoder = encoder;
    FLAC__stream_encoder_set_verify(encoder, true);
    FLAC__stream_encoder_set_compression_level(encoder, 0);
    FLAC__stream_encoder_set_channels(encoder, _recordFormat.mChannelsPerFrame);
    FLAC__stream_encoder_set_bits_per_sample(encoder, _recordFormat.mBitsPerChannel);
    FLAC__stream_encoder_set_sample_rate(encoder, _recordFormat.mSampleRate);
    
    FLAC__StreamEncoderInitStatus status = FLAC__stream_encoder_init_stream(encoder, FlacWriteCallback, NULL, NULL, NULL, &_recorderData);
    NSAssert((FLAC__STREAM_ENCODER_INIT_STATUS_OK == status), @"flac init failed");
    
    
    // Start queue
    
    _recorderData.running = TRUE;
    _recorderData.needWriting = FALSE;
    CheckError(AudioQueueStart(_queue, NULL), "AudioQueueStart failed");
    
    NSLog(@"Recording started~");
    
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                              target:self
                                            selector:@selector(checkMeter)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)stopRecording
{
    [self stopRecordingForced];
}

- (void)stopRecordingForced
{
    _recorderData.running = FALSE;
    _recorderData.needWriting = FALSE;
    
    [self.meterTimer invalidate];
    self.meterTimer = nil;
    
    NSURL *flacFile = [NSURL fileURLWithPath:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:FLAC_FORMAT]];
    
    [_recorderData.flacData writeToURL:flacFile
                            atomically:YES];
    FLAC__stream_encoder_finish(_recorderData.encoder);
    FLAC__stream_encoder_delete(_recorderData.encoder);
    
    CheckError(AudioQueueStop(_queue, TRUE), "AudioQueueStop failed");
    
    for (int i = 0; i<kNumberBuffers; i++) {
        AudioQueueFreeBuffer(_queue, _recorderData.buffers[i]);
    }
    
    CheckError(AudioQueueDispose(_queue, TRUE), "AudioQueueDispose failed");
    
    [self.delegate googleSTTRecordingFinished];
    
    [self sendToGoogleSTTAPI];
}

- (BOOL)recording
{
    return _recorderData.running;
}

- (void)sendToGoogleSTTAPI
{
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }
    
    [self.delegate googleSTTRequested];
    
    NSURL *url = [NSURL URLWithString:@"https://www.google.com/speech-api/v2/recognize?output=json&lang=ko-kr&key=AIzaSyCnl6MRydhw_5fLXIdASxkLJzcJh5iX0M4"];
    if (self.languageCode) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/speech-api/v2/recognize?output=json&lang=%@&key=AIzaSyCnl6MRydhw_5fLXIdASxkLJzcJh5iX0M4", self.languageCode]];
    }
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:_recorderData.flacData];
    [request addValue:[NSString stringWithFormat:@"audio/x-flac; rate=%d", SAMPLE_RATE]
   forHTTPHeaderField:@"Content-Type"];
    [request setURL:url];
    [request setTimeoutInterval:15];
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                               // remove garbage data
                               if (connectionError) {
                                   [self.delegate googleSTTResult:nil];
                                   return;
                               }
                               if ('.' == (char)((const char *)data.bytes)[data.length-1]) {
                                   data = [data subdataWithRange:NSMakeRange(0, data.length-1)];
                               }
                               NSString *jsonString = [[NSString alloc] initWithData:data
                                                                            encoding:NSUTF8StringEncoding];
                               NSLog(@"%@", jsonString);
                               if ([jsonString hasPrefix:GARBAGE_RESULT_VALUE]) {
                                   jsonString = [jsonString stringByReplacingOccurrencesOfString:GARBAGE_RESULT_VALUE
                                                                                      withString:@""];
                               }
                               
                               NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding]
                                                                            options:NSJSONReadingAllowFragments
                                                                              error:nil];
                               NSMutableArray *translates = nil;
                               if (result) {
                                   NSArray *results = result[@"result"];
                                   if (results && 0 < results.count) {
                                       NSArray *translatedInfos = results[0][@"alternative"];
                                       if (translatedInfos && 0 < translatedInfos.count) {
                                           translates = [NSMutableArray arrayWithCapacity:translatedInfos.count];
                                           for (NSDictionary *translateInfo in translatedInfos) {
                                               [translates addObject:translateInfo[@"transcript"]];
                                           }
                                       }
                                   }
                               }
                               if (translates) {
                                   [self.delegate googleSTTResult:[NSArray arrayWithArray:translates]];
                               }
                               else
                               {
                                   [self.delegate googleSTTResult:nil];
                               }
                           }];
    [request release];
}

- (void)checkMeter
{
    AudioQueueLevelMeterState meter;
    AudioQueueLevelMeterState meterDB;
    UInt32 meterSize = sizeof(AudioQueueLevelMeterState);
    CheckError(AudioQueueGetProperty(_queue,
                                     kAudioQueueProperty_CurrentLevelMeter,
                                     &meter,
                                     &meterSize), "Couldn't get level meter");
    CheckError(AudioQueueGetProperty(_queue,
                                     kAudioQueueProperty_CurrentLevelMeterDB,
                                     &meterDB,
                                     &meterSize), "Couldn't get level meter db");
    _currentVolumePeak = meter.mPeakPower;
    if (kSilenceThresholdDB < meterDB.mAveragePower) {
        _recorderData.needWriting = TRUE;
        [self.delegate googleSTTRecordingPitch:MAX(kMinVolumeSampleValue, meter.mPeakPower)
                                  timeInterval:self.meterTimer.timeInterval];
    }
    else
    {
        [self.delegate googleSTTRecordingPitch:MIN(kMaxVolumeSampleValue, meter.mPeakPower)
                                  timeInterval:self.meterTimer.timeInterval];
    }
    
    if (_recorderData.needWriting) {
        if (kSilenceThresholdNumSamples < self.silenceInterval) {
            [self stopRecordingForced];
        }
        self.silenceInterval++;
    }
}


@end
