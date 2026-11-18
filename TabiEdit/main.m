#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#include <math.h>

// ============================================================================
// Exact PC CapCut 3D LUT + 5-Channel HSL Math in C (Runs in True sRGB Space)
// ============================================================================

static void rgbToHsl(float r, float g, float b, float *hOut, float *sOut, float *lOut) {
    float maxV = fmaxf(r, fmaxf(g, b));
    float minV = fminf(r, fminf(g, b));
    float h = 0.0f, s = 0.0f;
    float l = (maxV + minV) * 0.5f;

    if (maxV != minV) {
        float d = maxV - minV;
        s = (l > 0.5f) ? (d / (2.0f - maxV - minV)) : (d / (maxV + minV));
        if (maxV == r) {
            h = (g - b) / d + (g < b ? 6.0f : 0.0f);
        } else if (maxV == g) {
            h = (b - r) / d + 2.0f;
        } else {
            h = (r - g) / d + 4.0f;
        }
        h *= 60.0f;
    }
    *hOut = h;
    *sOut = s;
    *lOut = l;
}

static float hue2rgb(float p, float q, float t) {
    if (t < 0.0f) t += 1.0f;
    if (t > 1.0f) t -= 1.0f;
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 0.5f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
    return p;
}

static void hslToRgb(float h, float s, float l, float *rOut, float *gOut, float *bOut) {
    if (s <= 0.0f) {
        *rOut = *gOut = *bOut = l;
        return;
    }
    float q = (l < 0.5f) ? (l * (1.0f + s)) : (l + s - l * s);
    float p = 2.0f * l - q;
    float hk = fmodf(fmodf(h, 360.0f) + 360.0f, 360.0f) / 360.0f;
    *rOut = hue2rgb(p, q, hk + 1.0f / 3.0f);
    *gOut = hue2rgb(p, q, hk);
    *bOut = hue2rgb(p, q, hk - 1.0f / 3.0f);
}

static float hueWeight(float hue, float center, float halfWidth) {
    float diff = fmodf(fabsf(hue - center), 360.0f);
    if (diff > 180.0f) diff = 360.0f - diff;
    if (diff >= halfWidth) return 0.0f;
    return 0.5f * (1.0f + cosf(((float)M_PI * diff) / halfWidth));
}

// True CapCut sRGB Tone Curve (Neither dark nor washed-out white; deep blacks at 0.0!)
static float applyToneChannel(float v, float br, float co, float bl) {
    // 1. Subtle CapCut Brightness & Brilliance gamma (keeps 0.0 black and 1.0 white, deepens midtones ~6%)
    float gamma = powf(2.0f, (-br * 0.25f) + (-bl * 0.30f));
    float x = powf(fmaxf(0.0f, fminf(1.0f, v)), gamma);

    // 2. CapCut Highlight Roll-off for negative Contrast (never lifts black to gray/white!)
    if (co < 0.0f) {
        float soft = (-co) * 0.16f;
        x = x * (1.0f - soft * x) + (soft * 0.16f * (1.0f - x) * x);
    } else if (co > 0.0f) {
        x = (x - 0.5f) * (1.0f + co * 0.55f) + 0.5f;
    }

    // 3. Subtle CapCut HD S-curve for rich shadow depth & glossy pop
    x = x - 0.05f * sinf(2.0f * (float)M_PI * x) / (2.0f * (float)M_PI);
    return fmaxf(0.0f, fminf(1.0f, x));
}

static NSData *createCapCutColorCubeData(NSDictionary *settings, int size) {
    float br = [settings[@"brightness"] ?: @(-23) floatValue] / 100.0f;
    float co = [settings[@"contrast"] ?: @(-31) floatValue] / 100.0f;
    float sa = [settings[@"saturation"] ?: @(39) floatValue] / 100.0f;
    float bl = [settings[@"brilliance"] ?: @(-9) floatValue] / 100.0f;

    float hslRed = [settings[@"hslRed"] ?: @(63) floatValue] / 100.0f;
    float hslBlue = [settings[@"hslBlue"] ?: @(15) floatValue] / 100.0f;
    float hslDarkBlue = [settings[@"hslDarkBlue"] ?: @(64) floatValue] / 100.0f;
    float hslPurple = [settings[@"hslPurple"] ?: @(60) floatValue] / 100.0f;
    float hslPink = [settings[@"hslPink"] ?: @(60) floatValue] / 100.0f;

    size_t cubeBytes = (size_t)size * (size_t)size * (size_t)size * 4 * sizeof(float);
    float *cubeData = (float *)malloc(cubeBytes);
    if (!cubeData) return nil;

    size_t offset = 0;
    for (int z = 0; z < size; z++) {
        float b0 = (float)z / (float)(size - 1);
        for (int y = 0; y < size; y++) {
            float g0 = (float)y / (float)(size - 1);
            for (int x = 0; x < size; x++) {
                float r0 = (float)x / (float)(size - 1);

                float r = applyToneChannel(r0, br, co, bl);
                float g = applyToneChannel(g0, br, co, bl);
                float b = applyToneChannel(b0, br, co, bl);

                float h, sat, l;
                rgbToHsl(r, g, b, &h, &sat, &l);

                // Protect neutral gray walls/floors (sat < 0.085 stays clean neutral gray!)
                float chromaGate = fminf(1.0f, fmaxf(0.0f, (sat - 0.085f) / 0.165f));

                // 5-Channel CapCut HSL Hue Weights (Red, Blue, Dark Blue, Purple, Pink)
                float wRed = hueWeight(h, 0.0f, 42.0f) + hueWeight(h, 16.0f, 24.0f) * 0.4f;
                float wBlue = hueWeight(h, 195.0f, 40.0f);
                float wDarkBlue = hueWeight(h, 232.0f, 42.0f);
                float wPurple = hueWeight(h, 275.0f, 40.0f);
                float wPink = hueWeight(h, 322.0f, 42.0f);

                float hslBoost =
                    wRed * hslRed * 1.45f +
                    wBlue * hslBlue * 1.30f +
                    wDarkBlue * hslDarkBlue * 1.45f +
                    wPurple * hslPurple * 1.40f +
                    wPink * hslPink * 1.45f;

                float totalBoost = (sa * 1.40f) + hslBoost;
                if (totalBoost > 0.0f && sat > 0.0f) {
                    float eff = totalBoost * chromaGate;
                    // Non-linear CapCut HSL vibrance curve + multiplier so all 5 HSL channels pop deeply!
                    sat = powf(sat, 1.0f / (1.0f + eff * 0.55f)) * (1.0f + eff * 0.45f);
                } else if (totalBoost < 0.0f) {
                    sat = sat * fmaxf(0.0f, 1.0f + totalBoost);
                }
                sat = fmaxf(0.0f, fminf(1.0f, sat));

                // Deepen color richness on saturated HSL channels so colors look deep & glowing (never white/pale!)
                if (hslBoost > 0.0f && sat > 0.15f) {
                    l = l * (1.0f - fminf(0.18f, hslBoost * 0.095f * sat * chromaGate));
                    l = fmaxf(0.0f, fminf(1.0f, l));
                }

                float ro, go, bo;
                hslToRgb(h, sat, l, &ro, &go, &bo);

                cubeData[offset++] = ro;
                cubeData[offset++] = go;
                cubeData[offset++] = bo;
                cubeData[offset++] = 1.0f;
            }
        }
    }

    return [NSData dataWithBytesNoCopy:cubeData length:cubeBytes freeWhenDone:YES];
}

// ============================================================================
// Main ViewController
// ============================================================================

@interface TabiViewController : UIViewController <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSURL *currentVideoURL;
@property (nonatomic, strong) NSURL *recordedVoiceURL;
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *exportProgressTimer;
@property (nonatomic, strong) AVAssetExportSession *activeExporter;
@end

@implementation TabiViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0];

    NSSet *websiteDataTypes = [WKWebsiteDataStore allWebsiteDataTypes];
    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:websiteDataTypes modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{}];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    [config.userContentController addScriptMessageHandler:self name:@"tabiNative"];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.opaque = NO;
    self.webView.backgroundColor = self.view.backgroundColor;
    self.webView.scrollView.backgroundColor = self.view.backgroundColor;
    self.webView.UIDelegate = self;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    if (htmlPath) {
        NSURL *htmlURL = [NSURL fileURLWithPath:htmlPath];
        NSURL *readRoot = [NSURL fileURLWithPath:@"/"];
        [self.webView loadFileURL:htmlURL allowingReadAccessToURL:readRoot];
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)sendJSEvent:(NSString *)jsCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:jsCode completionHandler:nil];
    });
}

// Native iOS Video Picker with Lossless Passthrough
- (void)openNativeVideoPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.videoExportPreset = AVAssetExportPresetPassthrough;
        [self presentViewController:picker animated:YES completion:nil];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    if (!mediaURL) return;

    NSString *ext = mediaURL.pathExtension.length > 0 ? mediaURL.pathExtension : @"mp4";
    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tabi_source_video.%@", ext]];
    [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:mediaURL toURL:[NSURL fileURLWithPath:tempFile] error:nil];

    self.currentVideoURL = [NSURL fileURLWithPath:tempFile];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.currentVideoURL options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    if (isnan(duration) || duration <= 0) duration = 10.0;

    NSString *urlStr = self.currentVideoURL.absoluteString;
    NSString *js = [NSString stringWithFormat:@"window.onNativeVideoSelected('%@', %.3f);", urlStr, duration];
    [self sendJSEvent:js];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// Native Microphone Voiceover Recorder
- (void)toggleVoiceRecording {
    if (self.audioRecorder && self.audioRecorder.isRecording) {
        [self.audioRecorder stop];
        self.audioRecorder = nil;
        [self sendJSEvent:@"window.onVoiceRecordState(false, '✅ Mic Voiceover Recorded');"];
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session requestRecordPermission:^(BOOL granted) {
        if (!granted) {
            [self sendJSEvent:@"window.onVoiceRecordState(false, '❌ Mic Permission Denied');"];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
            [session setActive:YES error:nil];

            NSString *voicePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tabi_voiceover.m4a"];
            [[NSFileManager defaultManager] removeItemAtPath:voicePath error:nil];
            self.recordedVoiceURL = [NSURL fileURLWithPath:voicePath];

            NSDictionary *recSettings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @44100.0,
                AVNumberOfChannelsKey: @2,
                AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
            };

            NSError *err = nil;
            self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:self.recordedVoiceURL settings:recSettings error:&err];
            if (self.audioRecorder && !err) {
                [self.audioRecorder prepareToRecord];
                [self.audioRecorder record];
                [self sendJSEvent:@"window.onVoiceRecordState(true, '🔴 Recording Mic...');"];
            } else {
                [self sendJSEvent:@"window.onVoiceRecordState(false, '❌ Mic Error');"];
            }
        });
    }];
}

// True sRGB 3D LUT + Tear-Free Unsharp Exporter (100% Identical to PC Engine!)
- (void)exportVideoWithPayload:(NSDictionary *)payload {
    if (!self.currentVideoURL || ![[NSFileManager defaultManager] fileExistsAtPath:self.currentVideoURL.path]) {
        [self sendJSEvent:@"window.onExportError('Please select a video first!');"];
        return;
    }

    NSDictionary *settings = payload[@"settings"] ?: @{};
    NSArray *segments = payload[@"segments"] ?: @[];

    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:self.currentVideoURL options:nil];
    AVMutableComposition *composition = [AVMutableComposition composition];

    AVAssetTrack *srcVideoTrack = [[sourceAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!srcVideoTrack) {
        [self sendJSEvent:@"window.onExportError('Could not read video track.');"];
        return;
    }

    AVMutableCompositionTrack *compVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    compVideoTrack.preferredTransform = srcVideoTrack.preferredTransform;

    AVAssetTrack *srcAudioTrack = [[sourceAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    AVMutableCompositionTrack *compAudioTrack = nil;
    if (srcAudioTrack) {
        compAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    }

    CMTime insertCursor = kCMTimeZero;
    double assetDuration = CMTimeGetSeconds(sourceAsset.duration);

    if (segments.count > 0) {
        for (NSDictionary *seg in segments) {
            double st = [seg[@"start"] doubleValue];
            double en = [seg[@"end"] doubleValue];
            if (en > assetDuration) en = assetDuration;
            double dur = en - st;
            if (dur <= 0.05) continue;

            CMTime startCM = CMTimeMakeWithSeconds(st, 600);
            CMTime durCM = CMTimeMakeWithSeconds(dur, 600);
            CMTimeRange range = CMTimeRangeMake(startCM, durCM);

            [compVideoTrack insertTimeRange:range ofTrack:srcVideoTrack atTime:insertCursor error:nil];
            if (srcAudioTrack && compAudioTrack) {
                [compAudioTrack insertTimeRange:range ofTrack:srcAudioTrack atTime:insertCursor error:nil];
            }
            insertCursor = CMTimeAdd(insertCursor, durCM);
        }
    } else {
        CMTimeRange fullRange = CMTimeRangeMake(kCMTimeZero, sourceAsset.duration);
        [compVideoTrack insertTimeRange:fullRange ofTrack:srcVideoTrack atTime:kCMTimeZero error:nil];
        if (srcAudioTrack && compAudioTrack) {
            [compAudioTrack insertTimeRange:fullRange ofTrack:srcAudioTrack atTime:kCMTimeZero error:nil];
        }
        insertCursor = sourceAsset.duration;
    }

    // Audio Mix (Original Volume + Voice Overlay)
    NSMutableArray<AVMutableAudioMixInputParameters *> *audioMixParams = [NSMutableArray array];
    float origVol = [settings[@"originalVolume"] ?: @(100) floatValue] / 100.0f;
    float voiceVol = [settings[@"voiceVolume"] ?: @(120) floatValue] / 100.0f;

    if (compAudioTrack) {
        AVMutableAudioMixInputParameters *origParam = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compAudioTrack];
        [origParam setVolume:origVol atTime:kCMTimeZero];
        [audioMixParams addObject:origParam];
    }

    if (self.recordedVoiceURL && [[NSFileManager defaultManager] fileExistsAtPath:self.recordedVoiceURL.path]) {
        AVURLAsset *voiceAsset = [AVURLAsset URLAssetWithURL:self.recordedVoiceURL options:nil];
        AVAssetTrack *vTrack = [[voiceAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (vTrack) {
            AVMutableCompositionTrack *compVoiceTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime maxDur = CMTimeMinimum(voiceAsset.duration, insertCursor);
            [compVoiceTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, maxDur) ofTrack:vTrack atTime:kCMTimeZero error:nil];

            AVMutableAudioMixInputParameters *vParam = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compVoiceTrack];
            [vParam setVolume:voiceVol atTime:kCMTimeZero];
            [audioMixParams addObject:vParam];
        }
    }

    // Generate 32x32x32 3D LUT with exact PC CapCut Color & 5-Channel HSL Math
    int cubeSize = 32;
    NSData *cubeData = createCapCutColorCubeData(settings, cubeSize);
    float sharpness = [settings[@"sharpness"] ?: @(98) floatValue];
    float unsharpIntensity = (sharpness / 100.0f) * 0.34f; // Tear-free crisp edge pop!

    BOOL fadeInEnabled = [settings[@"fadeInEnabled"] ?: @NO boolValue];
    double fadeInDuration = [settings[@"fadeInDuration"] ?: @(1.2) doubleValue];

    AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoCompositionWithAsset:composition applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *img = request.sourceImage;
        CGRect extent = img.extent;

        // Step 1: Convert CoreImage Linear RGB -> True sRGB (0..1 Display Space, same as PC FFmpeg!)
        CIFilter *linToSrgb = [CIFilter filterWithName:@"CILinearToSRGBToneCurve"];
        if (linToSrgb) {
            [linToSrgb setValue:img forKey:kCIInputImageKey];
            CIImage *outImg = linToSrgb.outputImage;
            if (outImg) img = outImg;
        }

        // Step 2: Apply Exact PC CapCut 3D LUT (Brightness, Contrast, Brilliance, Saturation & 5-Ch HSL) in sRGB!
        if (cubeData) {
            CIFilter *cubeFilter = [CIFilter filterWithName:@"CIColorCube"];
            if (cubeFilter) {
                [cubeFilter setValue:img forKey:kCIInputImageKey];
                [cubeFilter setValue:@(cubeSize) forKey:@"inputCubeDimension"];
                [cubeFilter setValue:cubeData forKey:@"inputCubeData"];
                CIImage *outImg = cubeFilter.outputImage;
                if (outImg) img = outImg;
            }
        }

        // Step 3: Convert sRGB -> CoreImage Linear RGB (Prevents both linear darkening AND white washout!)
        CIFilter *srgbToLin = [CIFilter filterWithName:@"CISRGBToneCurveToLinear"];
        if (srgbToLin) {
            [srgbToLin setValue:img forKey:kCIInputImageKey];
            CIImage *outImg = srgbToLin.outputImage;
            if (outImg) img = outImg;
        }

        // Step 4: Tear-Free Surface Clean + Crisp Unsharp Mask (No pixel tearing!)
        if (unsharpIntensity > 0.01f) {
            CIFilter *denoise = [CIFilter filterWithName:@"CINoiseReduction"];
            if (denoise) {
                [denoise setValue:img forKey:kCIInputImageKey];
                [denoise setValue:@(0.010f) forKey:@"inputNoiseLevel"];
                [denoise setValue:@(0.45f) forKey:kCIInputSharpnessKey];
                CIImage *outImg = denoise.outputImage;
                if (outImg) img = outImg;
            }
            CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
            if (unsharp) {
                [unsharp setValue:img forKey:kCIInputImageKey];
                [unsharp setValue:@(1.6f) forKey:kCIInputRadiusKey];
                [unsharp setValue:@(unsharpIntensity) forKey:kCIInputIntensityKey];
                CIImage *outImg = unsharp.outputImage;
                if (outImg) img = outImg;
            }
        }

        // Step 5: Optional Fade-In Animation
        double sec = CMTimeGetSeconds(request.compositionTime);
        if (fadeInEnabled && fadeInDuration > 0.05 && sec < fadeInDuration) {
            double prog = fmax(0.0, fmin(1.0, sec / fadeInDuration));
            CGFloat alpha = (CGFloat)(prog * prog * (3.0 - 2.0 * prog));
            CIFilter *fadeFilter = [CIFilter filterWithName:@"CIColorMatrix"];
            if (fadeFilter) {
                [fadeFilter setValue:img forKey:kCIInputImageKey];
                [fadeFilter setValue:[CIVector vectorWithX:alpha Y:0 Z:0 W:0] forKey:@"inputRVector"];
                [fadeFilter setValue:[CIVector vectorWithX:0 Y:alpha Z:0 W:0] forKey:@"inputGVector"];
                [fadeFilter setValue:[CIVector vectorWithX:0 Y:0 Z:alpha W:0] forKey:@"inputBVector"];
                CIImage *outImg = fadeFilter.outputImage;
                if (outImg) img = outImg;
            }
        }

        [request finishWithImage:[img imageByCroppingToRect:extent] context:nil];
    }];

    videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
    videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
    videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;

    float srcFps = srcVideoTrack.nominalFrameRate;
    int targetFps = (srcFps >= 24.0f && srcFps <= 60.0f) ? (int)roundf(srcFps) : 30;
    videoComp.frameDuration = CMTimeMake(1, targetFps);

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"TABI_EDIT_HD_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]]];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];

    self.activeExporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
    self.activeExporter.outputURL = outURL;
    self.activeExporter.outputFileType = AVFileTypeMPEG4;
    self.activeExporter.videoComposition = videoComp;
    self.activeExporter.shouldOptimizeForNetworkUse = NO;

    if (audioMixParams.count > 0) {
        AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
        audioMix.inputParameters = audioMixParams;
        self.activeExporter.audioMix = audioMix;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.exportProgressTimer invalidate];
        self.exportProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer * _Nonnull timer) {
            int pct = (int)roundf(self.activeExporter.progress * 100.0f);
            [self sendJSEvent:[NSString stringWithFormat:@"window.onExportProgress(%d);", pct]];
        }];
    });

    __weak typeof(self) weakSelf = self;
    [self.activeExporter exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.exportProgressTimer invalidate];
            weakSelf.exportProgressTimer = nil;

            if (weakSelf.activeExporter.status == AVAssetExportSessionStatusCompleted) {
                if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(outPath)) {
                    UISaveVideoAtPathToSavedPhotosAlbum(outPath, nil, nil, nil);
                }
                [weakSelf sendJSEvent:@"window.onExportComplete();"];

                UIActivityViewController *shareVC = [[UIActivityViewController alloc] initWithActivityItems:@[outURL] applicationActivities:nil];
                if (shareVC.popoverPresentationController) {
                    shareVC.popoverPresentationController.sourceView = weakSelf.view;
                    shareVC.popoverPresentationController.sourceRect = CGRectMake(weakSelf.view.bounds.size.width / 2, weakSelf.view.bounds.size.height / 2, 1, 1);
                }
                [weakSelf presentViewController:shareVC animated:YES completion:nil];
            } else {
                NSString *errMsg = weakSelf.activeExporter.error.localizedDescription ?: @"Export failed";
                errMsg = [errMsg stringByReplacingOccurrencesOfString:@"'" withString:@""];
                [weakSelf sendJSEvent:[NSString stringWithFormat:@"window.onExportError('%@');", errMsg]];
            }
        });
    }];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"tabiNative"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *payload = (NSDictionary *)message.body;
    NSString *action = payload[@"action"];

    if ([action isEqualToString:@"pickVideo"]) {
        [self openNativeVideoPicker];
    } else if ([action isEqualToString:@"toggleVoiceRecord"]) {
        [self toggleVoiceRecording];
    } else if ([action isEqualToString:@"exportVideo"]) {
        [self exportVideoWithPayload:payload];
    }
}

@end

@interface TabiAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TabiAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[TabiViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TabiAppDelegate class]));
    }
}
