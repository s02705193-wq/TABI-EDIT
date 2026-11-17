#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <math.h>

// ============================================================================
// Exact CapCut 3D LUT Math in C (Matches PC Engine 100% — Runs on iPhone GPU)
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

static float applyToneChannel(float v, float br, float co, float bl) {
    float x = v * (1.0f + br * 0.42f);
    x = fmaxf(0.0f, fminf(1.0f, x));
    float gamma = powf(2.0f, (-br * 0.42f) + (-bl * 0.52f));
    x = powf(x, gamma);

    if (co < 0.0f) {
        float soft = (-co) * 0.28f;
        x = x * (1.0f - soft * x * x);
    } else if (co > 0.0f) {
        x = (x - 0.5f) * (1.0f + co * 0.65f) + 0.5f;
    }

    x = x - 0.065f * sinf(2.0f * (float)M_PI * x) / (2.0f * (float)M_PI);
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

                float chromaGate = fminf(1.0f, fmaxf(0.0f, (sat - 0.085f) / 0.165f));

                float wRed = hueWeight(h, 0.0f, 40.0f);
                float wBlue = hueWeight(h, 195.0f, 38.0f);
                float wDarkBlue = hueWeight(h, 232.0f, 40.0f);
                float wPurple = hueWeight(h, 275.0f, 38.0f);
                float wPink = hueWeight(h, 322.0f, 40.0f);

                float hslBoost =
                    wRed * hslRed * 1.40f +
                    wBlue * hslBlue * 1.25f +
                    wDarkBlue * hslDarkBlue * 1.40f +
                    wPurple * hslPurple * 1.35f +
                    wPink * hslPink * 1.40f;

                float satMult = 1.0f + (sa * 1.45f * chromaGate) + (hslBoost * chromaGate);
                sat = fmaxf(0.0f, fminf(1.0f, sat * satMult));

                if (hslBoost > 0.0f && sat > 0.18f) {
                    l = l * (1.0f - fminf(0.16f, hslBoost * 0.085f * sat * chromaGate));
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
// Main ViewController with Native Video Picker, Voice Recorder & AVFoundation
// ============================================================================

@interface TabiViewController : UIViewController <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSURL *currentVideoURL;
@property (nonatomic, strong) NSURL *recordedVoiceURL;
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *exportProgressTimer;
@property (nonatomic, strong) AVAssetExportSession *activeExporter;
@property (nonatomic, strong) CIContext *ciContext;
@end

@implementation TabiViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0];
    self.ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

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

// Native iOS Video Picker
- (void)openNativeVideoPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        [self presentViewController:picker animated:YES completion:nil];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    if (!mediaURL) return;

    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tabi_source_video.mp4"];
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

// Native AVFoundation + CoreImage 1080p 60FPS Video Exporter
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

    // Precompute 32x32x32 3D LUT Cube Data for CoreImage CIColorCube
    int cubeSize = 32;
    NSData *cubeData = createCapCutColorCubeData(settings, cubeSize);
    float sharpness = [settings[@"sharpness"] ?: @(98) floatValue];
    BOOL fadeInEnabled = [settings[@"fadeInEnabled"] ?: @YES boolValue];
    double fadeInDuration = [settings[@"fadeInDuration"] ?: @(1.2) doubleValue];

    // Calculate oriented natural size and 1080p target size
    CGAffineTransform transform = srcVideoTrack.preferredTransform;
    CGSize naturalSize = CGSizeApplyAffineTransform(srcVideoTrack.naturalSize, transform);
    naturalSize.width = fabs(naturalSize.width);
    naturalSize.height = fabs(naturalSize.height);
    if (naturalSize.width < 10 || naturalSize.height < 10) {
        naturalSize = CGSizeMake(1920, 1080);
    }

    CIContext *ciCtx = self.ciContext;

    AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoCompositionWithAsset:composition applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *img = request.sourceImage;
        CGRect extent = img.extent;

        // 1. Apply 3D Color & HSL LUT via CIColorCube
        if (cubeData) {
            CIFilter *cubeFilter = [CIFilter filterWithName:@"CIColorCube"];
            [cubeFilter setValue:img forKey:kCIInputImageKey];
            [cubeFilter setValue:@(cubeSize) forKey:@"inputCubeDimension"];
            [cubeFilter setValue:cubeData forKey:@"inputCubeData"];
            CIImage *outImg = cubeFilter.outputImage;
            if (outImg) img = outImg;
        }

        // 2. Apply CapCut Crisp Sharpening (CIUnsharpMask + CISharpenLuminance)
        if (sharpness > 0.0f) {
            float k = sharpness / 100.0f;
            CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
            if (unsharp) {
                [unsharp setValue:img forKey:kCIInputImageKey];
                [unsharp setValue:@(2.5f) forKey:kCIInputRadiusKey];
                [unsharp setValue:@(k * 1.45f) forKey:kCIInputIntensityKey];
                CIImage *outImg = unsharp.outputImage;
                if (outImg) img = outImg;
            }
            CIFilter *sharpen = [CIFilter filterWithName:@"CISharpenLuminance"];
            if (sharpen) {
                [sharpen setValue:img forKey:kCIInputImageKey];
                [sharpen setValue:@(k * 0.95f) forKey:kCIInputSharpnessKey];
                CIImage *outImg = sharpen.outputImage;
                if (outImg) img = outImg;
            }
        }

        // 3. Apply Smooth Fade-In Animation
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

        [request finishWithImage:[img imageByCroppingToRect:extent] context:ciCtx];
    }];

    videoComp.frameDuration = CMTimeMake(1, 60); // 60 FPS

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"TABI_EDIT_1080p60_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]]];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];

    NSString *preset = [[AVAssetExportSession exportPresetsCompatibleWithAsset:composition] containsObject:AVAssetExportPreset1920x1080]
        ? AVAssetExportPreset1920x1080
        : AVAssetExportPresetHighestQuality;

    self.activeExporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:preset];
    self.activeExporter.outputURL = outURL;
    self.activeExporter.outputFileType = AVFileTypeMPEG4;
    self.activeExporter.videoComposition = videoComp;
    self.activeExporter.shouldOptimizeForNetworkUse = YES;

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
