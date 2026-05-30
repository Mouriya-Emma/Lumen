/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper process to create and hold a CGVirtualDisplay.
 *
 * Spawned by Sunshine to create virtual displays in a clean process context.
 * Usage: vd_helper <width> <height> <fps>
 * Outputs: displayID on stdout (or "0" on failure)
 * Stays alive holding the display until SIGTERM is received.
 *
 * CGVirtualDisplay creates the display object, then we:
 *   1. SLSConfigureDisplayEnabled activates it in WindowServer's display list
 *   2. CGConfigureDisplayMirrorOfDisplay(kCGNullDirectDisplay) forces extend mode
 *      (macOS may auto-mirror new displays, hiding them from CGGetActiveDisplayList)
 * Compiled with ARC (-fobjc-arc).
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <float.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

// Standard 16:9 and 16:10 logical resolution rungs.
// Used to populate settings.modes so the virtual display advertises a rich
// ladder of HiDPI-eligible logical resolutions; setDisplayResolution() then
// picks the rung closest to (clientWidth/scale, clientHeight/scale).
typedef struct { unsigned int w, h; } LumenResMode;
static const LumenResMode kStandardLogicalModes[] = {
  // 16:9
  {640, 360}, {854, 480}, {960, 540}, {1024, 576},
  {1280, 720}, {1366, 768}, {1600, 900}, {1920, 1080},
  {2560, 1440}, {2880, 1620}, {3200, 1800}, {3840, 2160},
  // 16:10
  {1024, 640}, {1280, 800}, {1440, 900}, {1680, 1050},
  {1920, 1200}, {2560, 1600}, {2880, 1800},
};

// Private CGVirtualDisplay API interface declarations (macOS 14+)
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// SkyLight private C functions for display configuration (linked directly)
extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef, CGDirectDisplayID, int32_t, int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef, CGConfigureOption, uint32_t);

// Static storage to keep objects alive (ARC retains static references)
static CGVirtualDisplay *keepAlive = nil;
static CGVirtualDisplayDescriptor *keepDesc = nil;

static volatile sig_atomic_t shouldExit = 0;
static volatile sig_atomic_t shouldMirror = 0;
static CGDirectDisplayID g_virtualDisplayID = 0;
static int g_clientWidth = 0;
static int g_clientHeight = 0;
static int g_clientFps = 0;
static double g_hidpiScale = 0.0;  // 0 = disabled, >0 = scale factor

static void handle_signal(int sig) {
  if (sig == SIGUSR1) {
    shouldMirror = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
      CFRunLoopStop(CFRunLoopGetMain());
    });
    return;
  }
  shouldExit = 1;
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
}

static void setDisplayResolution(CGDirectDisplayID displayID, int width, int height, int fps) {
  NSDictionary *opts = @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
  CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (CFDictionaryRef)opts);
  if (!allModes) {
    fprintf(stderr, "[vd_helper] Failed to get display modes for %u\n", displayID);
    return;
  }

  BOOL wantHiDPI = (g_hidpiScale > 0);
  double targetLW = wantHiDPI ? (double)width / g_hidpiScale : (double)width;
  double targetLH = wantHiDPI ? (double)height / g_hidpiScale : (double)height;

  fprintf(stderr, "[vd_helper] Looking for mode on %u: pixel %dx%d, target logical %.0fx%.0f (scale=%.2f)\n",
          displayID, width, height, targetLW, targetLH, g_hidpiScale);

  // SCStream output is sized independently (sc_capture.m:181-184), so display
  // pixel may exceed client width — SCStream downscales. We pick the HiDPI
  // mode (pw > lw) whose logical resolution is closest to target; fall back
  // to the exact native 1x mode (pw == lw == width) if HiDPI not wanted/found.
  CGDisplayModeRef bestHidpiFps = NULL;
  CGDisplayModeRef bestHidpi = NULL;
  CGDisplayModeRef bestNativeFps = NULL;
  CGDisplayModeRef bestNative = NULL;
  double bestHidpiFpsDist = DBL_MAX;
  double bestHidpiDist = DBL_MAX;

  CFIndex modeCount = CFArrayGetCount(allModes);
  for (CFIndex i = 0; i < modeCount; i++) {
    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
    size_t lw = CGDisplayModeGetWidth(m);
    size_t lh = CGDisplayModeGetHeight(m);
    size_t pw = CGDisplayModeGetPixelWidth(m);
    size_t ph = CGDisplayModeGetPixelHeight(m);
    double rate = CGDisplayModeGetRefreshRate(m);
    BOOL fpsMatch = (fps > 0 && rate > 0 && (int)rate == fps);

    if (wantHiDPI && pw > lw) {
      double dist = fabs((double)lw - targetLW) / targetLW + fabs((double)lh - targetLH) / targetLH;
      if (fpsMatch && dist < bestHidpiFpsDist) { bestHidpiFps = m; bestHidpiFpsDist = dist; }
      if (dist < bestHidpiDist) { bestHidpi = m; bestHidpiDist = dist; }
    } else if ((int)lw == width && (int)lh == height && pw == lw) {
      if (fpsMatch && !bestNativeFps) bestNativeFps = m;
      if (!bestNative) bestNative = m;
    }
  }

  CGDisplayModeRef bestMode = bestHidpiFps ?: bestHidpi ?: bestNativeFps ?: bestNative;

  if (bestMode) {
    size_t lw = CGDisplayModeGetWidth(bestMode);
    size_t lh = CGDisplayModeGetHeight(bestMode);
    size_t pw = CGDisplayModeGetPixelWidth(bestMode);
    size_t ph = CGDisplayModeGetPixelHeight(bestMode);
    double rate = CGDisplayModeGetRefreshRate(bestMode);
    BOOL isHiDPI = (pw > lw);
    CGError err = CGDisplaySetDisplayMode(displayID, bestMode, NULL);
    fprintf(stderr, "[vd_helper] Set display %u to logical %zux%zu pixel %zux%zu @%.0fHz HiDPI=%d: %d\n",
            displayID, lw, lh, pw, ph, rate, isHiDPI, err);
  } else {
    fprintf(stderr, "[vd_helper] No matching mode for display %u (target logical %.0fx%.0f, native %dx%d@%dHz)\n",
            displayID, targetLW, targetLH, width, height, fps);
  }
  CFRelease(allModes);
}

static void switchToMirrorMode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID mainDisplay = CGMainDisplayID();

  // Step 1: if there's a real physical main display, mirror onto the virtual one
  // so the client sees what the user sees. With no physical main, skip this —
  // the virtual display is its own canvas.
  if (mainDisplay != virtualID) {
    fprintf(stderr, "[vd_helper] Switching display %u to mirror main display %u\n", virtualID, mainDisplay);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, mainDisplay);
      CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
      fprintf(stderr, "[vd_helper] Mirror configuration result: %d\n", err);
    }
    usleep(500000);
  } else {
    fprintf(stderr, "[vd_helper] Virtual display is main; no mirror needed\n");
  }

  // Step 2: apply logical resolution to the mirror set virtualID lives in.
  // A mirror set shares one logical canvas; CGDisplaySetDisplayMode requires
  // operating on the set's master, never on a slave (the slave call returns
  // kCGErrorIllegalArgument = 1001). CGDisplayMirrorsDisplay returns the
  // master when virtualID is a slave, or 0 when virtualID is standalone /
  // is itself the master. Resolving to the master keeps a single call site
  // that works for both mirror and no-mirror states.
  if (g_clientWidth > 0 && g_clientHeight > 0) {
    CGDirectDisplayID master = CGDisplayMirrorsDisplay(virtualID);
    if (master == kCGNullDirectDisplay) master = virtualID;
    fprintf(stderr, "[vd_helper] Applying logical resolution to display %u (mirror master of virtual %u)\n",
            master, virtualID);
    setDisplayResolution(master, g_clientWidth, g_clientHeight, g_clientFps);
  }
}

static BOOL checkDisplayInList(uint32_t targetID, uint32_t *outCount) {
  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    if (outCount) *outCount = displayCount;
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == targetID) return YES;
    }
  }
  return NO;
}

/**
 * Force the virtual display into "extend" mode (not mirrored).
 * macOS may auto-mirror new displays, which hides them from CGGetActiveDisplayList.
 * This un-mirrors the display and positions it to the right of the main display.
 */
static void forceExtendMode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID mainDisplay = CGMainDisplayID();

  // Check if main display is now mirroring our virtual display
  CGDirectDisplayID mainMirrorTarget = CGDisplayMirrorsDisplay(mainDisplay);
  if (mainMirrorTarget == virtualID) {
    fprintf(stderr, "[vd_helper] Main display is mirroring us (%u), un-mirroring main\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, mainMirrorTarget, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Check if our display is in a mirror set
  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd_helper] Display %u is in mirror set, un-mirroring\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Also check if virtual display is mirroring main
  CGDirectDisplayID virtualMirrorTarget = CGDisplayMirrorsDisplay(virtualID);
  if (virtualMirrorTarget != 0) {
    fprintf(stderr, "[vd_helper] Display %u mirrors %u, un-mirroring\n", virtualID, virtualMirrorTarget);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Position it to the right of main display
  {
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      size_t mainWidth = CGDisplayPixelsWide(mainDisplay);
      CGConfigureDisplayOrigin(config, virtualID, (int32_t)mainWidth, 0);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // If the virtual display became the main display, restore the original
  CGDirectDisplayID newMain = CGMainDisplayID();
  if (newMain == virtualID && newMain != mainDisplay) {
    fprintf(stderr, "[vd_helper] Virtual display became main, restoring original main %u\n", mainDisplay);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayOrigin(config, mainDisplay, 0, 0);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 4 || argc > 5) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int fps = atoi(argv[3]);
    double hidpiScale = (argc == 5) ? atof(argv[4]) : 0.0;

    if (width <= 0 || height <= 0 || fps <= 0) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    g_clientWidth = width;
    g_clientHeight = height;
    g_clientFps = fps;
    g_hidpiScale = hidpiScale;
    fprintf(stderr, "[vd_helper] HiDPI scale: %.2f (%s)\n", g_hidpiScale, g_hidpiScale > 0 ? "enabled" : "disabled");

    // Runtime availability check
    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay API not available\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Initialize NSApplication
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    // Set up signal handlers
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGHUP, handle_signal);
    signal(SIGUSR1, handle_signal);

    // Create display directly on main thread
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"Sunshine Virtual Display";
    desc.vendorID = 0xF0F0;
    desc.productID = 0x5678;
    desc.serialNum = arc4random();
    // maxPixels caps the largest backing buffer macOS will allocate for this vd.
    // It must be ≥ 2 × any declared logical for that logical to get a HiDPI
    // (pixel = 2 × logical) derived variant. Setting it to 2 × client native
    // lets every declared rung at or below native get its HiDPI backing.
    desc.maxPixelsWide = (unsigned int)(width * 2);
    desc.maxPixelsHigh = (unsigned int)(height * 2);
    // Fixed 27" monitor physical size — do NOT scale linearly with resolution.
    // WindowServer rejects displays with unreasonably large physical dimensions.
    desc.sizeInMillimeters = CGSizeMake(597, 336);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    desc.redPrimary = CGPointMake(0.64, 0.33);
    desc.greenPrimary = CGPointMake(0.30, 0.60);
    desc.bluePrimary = CGPointMake(0.15, 0.06);
    [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    desc.terminationHandler = ^(id s, id d) {
      fprintf(stderr, "[vd_helper] Virtual display terminated by system\n");
    };

    CGVirtualDisplayMode *nativeMode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width
                                                                          height:(unsigned int)height
                                                                     refreshRate:(double)fps];
    if (!nativeMode) {
      fprintf(stderr, "[vd_helper] Failed to create CGVirtualDisplayMode\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Declare a ladder of standard 16:9 + 16:10 logical resolutions (≤ native).
    // With hiDPI=1, macOS pairs each declared logical with a retina backing variant
    // (pixel = native). setDisplayResolution() later picks whichever rung is closest
    // to (width/scale, height/scale), so user-facing scale settings (1.5x / 2x / 3x …)
    // snap to a real rung rather than requiring an exact integer divisor.
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    NSMutableArray *modeList = [NSMutableArray arrayWithObject:nativeMode];
    size_t kModeCount = sizeof(kStandardLogicalModes) / sizeof(kStandardLogicalModes[0]);
    for (size_t i = 0; i < kModeCount; ++i) {
      unsigned int lw = kStandardLogicalModes[i].w;
      unsigned int lh = kStandardLogicalModes[i].h;
      if (lw >= (unsigned int)width || lh >= (unsigned int)height) continue;
      CGVirtualDisplayMode *m = [[CGVirtualDisplayMode alloc] initWithWidth:lw
                                                                    height:lh
                                                               refreshRate:(double)fps];
      if (m) [modeList addObject:m];
    }
    settings.modes = modeList;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) {
      fprintf(stderr, "[vd_helper] initWithDescriptor returned nil (trying background thread)\n");

      // Fallback: try on background thread
      __block CGVirtualDisplay *bgDisplay = nil;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bgDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (bgDisplay) [bgDisplay applySettings:settings];
        dispatch_semaphore_signal(sem);
      });
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
      display = bgDisplay;
    } else {
      [display applySettings:settings];
    }

    if (!display || display.displayID == 0) {
      fprintf(stderr, "[vd_helper] Failed to create virtual display\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    keepAlive = display;
    keepDesc = desc;
    uint32_t resultID = display.displayID;

    fprintf(stderr, "[vd_helper] Display %u created, activating...\n", resultID);

    // Step 1: Activate display via SkyLight SLSConfigureDisplayEnabled
    {
      CGDisplayConfigRef cgConfig = NULL;
      CGError err = SLSBeginDisplayConfiguration(&cgConfig);
      fprintf(stderr, "[vd_helper] SLSBeginDisplayConfiguration: %d\n", err);
      if (err == kCGErrorSuccess && cgConfig) {
        err = SLSConfigureDisplayEnabled(cgConfig, resultID, true);
        fprintf(stderr, "[vd_helper] SLSConfigureDisplayEnabled(%u, true): %d\n", resultID, err);
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        size_t mainWidth = CGDisplayPixelsWide(mainDisplay);
        SLSConfigureDisplayOrigin(cgConfig, resultID, (int32_t)mainWidth, 0);
        CGError completeErr = SLSCompleteDisplayConfiguration(cgConfig, kCGConfigureForSession, 0);
        fprintf(stderr, "[vd_helper] SLSCompleteDisplayConfiguration: %d\n", completeErr);
      }
    }

    // Wait for WindowServer to process the display
    usleep(500000); // 500ms

    // Diagnostic: dump every mode WindowServer ended up exposing for this vd.
    // Tells us which of the declared logical rungs actually got a HiDPI backing
    // variant (pw > lw) vs. plain 1x (pw == lw). Used to tune the rung ladder.
    {
      NSDictionary *dopts = @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CFArrayRef dumpModes = CGDisplayCopyAllDisplayModes(resultID, (CFDictionaryRef)dopts);
      if (dumpModes) {
        CFIndex n = CFArrayGetCount(dumpModes);
        fprintf(stderr, "[vd_helper] Display %u exposes %ld modes:\n", resultID, (long)n);
        for (CFIndex i = 0; i < n; i++) {
          CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(dumpModes, i);
          size_t lw = CGDisplayModeGetWidth(m), lh = CGDisplayModeGetHeight(m);
          size_t pw = CGDisplayModeGetPixelWidth(m), ph = CGDisplayModeGetPixelHeight(m);
          fprintf(stderr, "[vd_helper]   logical %zux%zu pixel %zux%zu @%.0fHz%s\n",
                  lw, lh, pw, ph, CGDisplayModeGetRefreshRate(m),
                  (pw > lw) ? " (HiDPI)" : "");
        }
        CFRelease(dumpModes);
      }
    }

    // Step 2: Force extend mode (un-mirror) if needed
    if (CGDisplayIsInMirrorSet(resultID) || CGDisplayMirrorsDisplay(resultID) != 0) {
      fprintf(stderr, "[vd_helper] Mirror detected, forcing extend mode\n");
      forceExtendMode(resultID);
    }

    // Step 3: Switch to native resolution (1x scale) mode.
    // The display starts as retina 2x (logical=half, pixel=full).
    // For streaming, we want native 1x (logical=full, pixel=full) to avoid
    // compositor overhead that causes latency and FPS drops.
    {
      NSDictionary *opts = @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CFArrayRef allModes = CGDisplayCopyAllDisplayModes(resultID, (CFDictionaryRef)opts);
      if (allModes) {
        CGDisplayModeRef nativeMode = NULL;
        CFIndex modeCount = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < modeCount; i++) {
          CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
          size_t lw = CGDisplayModeGetWidth(m);
          size_t lh = CGDisplayModeGetHeight(m);
          size_t pw = CGDisplayModeGetPixelWidth(m);
          size_t ph = CGDisplayModeGetPixelHeight(m);
          // Find the 1x native mode matching our requested resolution
          if ((int)lw == width && (int)lh == height && pw == lw && ph == lh) {
            nativeMode = m;
            break;
          }
        }
        if (nativeMode) {
          CGError modeErr = CGDisplaySetDisplayMode(resultID, nativeMode, NULL);
          fprintf(stderr, "[vd_helper] Switched to native %dx%d (1x scale): %d\n", width, height, modeErr);
        } else {
          fprintf(stderr, "[vd_helper] Native %dx%d mode not found, staying at retina 2x\n", width, height);
        }
        CFRelease(allModes);
      }
    }

    // Wait for mode switch to take effect
    usleep(500000); // 500ms

    // Step 3: If still not visible, try again after a longer wait
    uint32_t count = 0;
    BOOL found = checkDisplayInList(resultID, &count);
    if (!found) {
      fprintf(stderr, "[vd_helper] Display %u not found after first attempt, retrying...\n", resultID);
      sleep(1);
      // Check mirror state again
      fprintf(stderr, "[vd_helper] Mirror state (retry): inMirrorSet=%d, mirrorsDisplay=%u\n",
              CGDisplayIsInMirrorSet(resultID), CGDisplayMirrorsDisplay(resultID));
      forceExtendMode(resultID);
      usleep(500000);
      found = checkDisplayInList(resultID, &count);
    }

    fprintf(stderr, "[vd_helper] Display %u (%dx%d@%dHz) - %s in active list (%u total)\n",
            resultID, width, height, fps, found ? "FOUND" : "NOT found", count);

    // Log all active displays for debugging
    {
      CGDirectDisplayID activeDisplays[32];
      uint32_t dCount = 0;
      CGGetActiveDisplayList(32, activeDisplays, &dCount);
      for (uint32_t i = 0; i < dCount; i++) {
        fprintf(stderr, "[vd_helper]   active[%u] = %u (online=%d, active=%d, mirror=%u)\n",
                i, activeDisplays[i],
                CGDisplayIsOnline(activeDisplays[i]),
                CGDisplayIsActive(activeDisplays[i]),
                CGDisplayMirrorsDisplay(activeDisplays[i]));
      }
      // Also check our display specifically
      fprintf(stderr, "[vd_helper]   ours[%u]: online=%d, active=%d, inMirror=%d, mirrors=%u\n",
              resultID,
              CGDisplayIsOnline(resultID),
              CGDisplayIsActive(resultID),
              CGDisplayIsInMirrorSet(resultID),
              CGDisplayMirrorsDisplay(resultID));
    }

    g_virtualDisplayID = resultID;

    fprintf(stdout, "%u\n", resultID);
    fflush(stdout);

    // Keep alive via CFRunLoop; handle SIGUSR1 for mirror mode switch
    while (!shouldExit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
      if (shouldMirror && !shouldExit) {
        shouldMirror = 0;
        switchToMirrorMode(g_virtualDisplayID);
      }
    }

    fprintf(stderr, "[vd_helper] Shutting down, releasing display %u\n", resultID);
    keepAlive = nil;
    keepDesc = nil;
  }
  return 0;
}
