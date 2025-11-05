# ScreenSaverKit

`ScreenSaverKit` is a lightweight helper layer for building macOS ScreenSaver modules without having to re-implement the plumbing that every saver needs. Treat it as a starting point that you can copy into any new screensaver project. It gives you access to both CPU and Metal-accelerated rendering paths, built-in preference management, configuration sheet scaffolding, and a particle system.

There's plenty of demo savers included to illustrate how to use the various features, plus a complete tutorial in [tutorial.md](tutorial.md) that walks you through building your first saver from scratch.

Currently this is in alpha development, so expect possible breaking changes in future releases. Feedback and contributions are welcome!

![Hello World Demo](documentation-src/hello-world.gif)

## What you get

- ✅ Automatic default registration and preference persistence
- ✅ Cross-process preference change monitoring (System Settings ↔ saver engine)
- ✅ Convenience accessors for reading/writing `ScreenSaverDefaults`
- ✅ Proper animation start/stop handling across preview, WallpaperAgent and ScreenSaverEngine hosts
- ✅ Asset loading helpers, animation timing utilities, entity pooling, and diagnostics hooks
- ✅ Pre-built configuration sheet scaffolding with preference binding helpers
- ✅ Hardware-accelerated particle system with Metal rendering support
- ✅ Color palette management and interpolation utilities
- ✅ Vector math helpers for smooth animations

Keeping these concerns in one place lets each screensaver focus on drawing and behavior instead of boilerplate.

![Starfield Preferences](documentation-src/starfield.gif)

## Getting Started

**New to ScreenSaverKit?** Check out the **[complete tutorial](tutorial.md)** for a step-by-step walkthrough that covers building your first screen saver, understanding the code, debugging, and creating your own custom savers.

## How to use it

1. **Copy the kit**  
   Grab the `ScreenSaverKit/` directory and drop it into your saver project.

2. **Subclass `SSKScreenSaverView`**

   ```objective-c
   #import "ScreenSaverKit/SSKScreenSaverView.h"

   @interface SimpleLinesView : SSKScreenSaverView
   @end
   ```

3. **Provide defaults**

   ```objective-c
   - (NSDictionary<NSString *, id> *)defaultPreferences {
       return @{
           @"lineCount": @200,
           @"colorRate": @0.2
       };
   }
   ```

4. **React to preference changes**

   Whenever the user changes a setting (even from the System Settings pane) the kit calls back into your saver:

   ```objective-c
   - (void)preferencesDidChange:(NSDictionary<NSString *, id> *)prefs
                    changedKeys:(NSSet<NSString *> *)changed {
       self.lineCount = [prefs[@"lineCount"] integerValue];
       self.colorRate = [prefs[@"colorRate"] doubleValue];

       if ([changed containsObject:@"lineCount"]) {
           [self rebuildLines];
       }
   }
   ```

5. **Draw as normal**

   Implement `drawRect:`, `animateOneFrame`, etc. just as you would in a plain `ScreenSaverView` subclass. For smooth timing call `NSTimeInterval dt = [self advanceAnimationClock];` in `-animateOneFrame` and use the returned delta.

## Helper modules

- `SSKAssetManager` – cached bundle resource lookup with extension fallbacks for images/data. Available via `self.assetManager` on the saver view.
- `SSKAnimationClock` – smooth delta-time tracking and FPS reporting. Call `NSTimeInterval dt = [self advanceAnimationClock];` inside `-animateOneFrame` and inspect `self.animationClock.framesPerSecond`.
- `SSKEntityPool` – simple object pooling for sprites/particles. Create pools with `makeEntityPoolWithCapacity:factory:`.
- `SSKScreenUtilities` – helpers for scaling information, wallpaper-host detection, and screen dimensions.
- `SSKDiagnostics` – opt-in logging and overlay drawing. Toggle with
  `[SSKDiagnostics setEnabled:YES]` and draw overlays inside `-drawRect:`.
- `SSKPreferenceBinder` + `SSKConfigurationWindowController` – drop-in UI scaffold for settings windows with automatic binding between controls and `ScreenSaverDefaults`.
- `SSKColorPalette` + `SSKPaletteManager` – shared palette definitions with interpolation helpers and registration per saver module.
- `SSKColorUtilities` – convenience serializers/deserializers for storing `NSColor` instances inside `ScreenSaverDefaults`.
- `SSKVectorMath` – small collection of inline NSPoint helpers (add, scale, reflect, clamp) for animation math.
- `SSKParticleSystem` – lightweight particle engine with CPU and Metal-accelerated rendering modes. Supports additive/alpha blending, automatic fade behaviors, and custom per-particle rendering callbacks. Ideal for sparks, trails, explosions, and flowing ribbon effects. See `ScreenSaverKit/SSKParticleSystem.md` for detailed documentation.
- `SSKMetalParticleRenderer` – hardware-accelerated particle renderer using Metal. Automatically handles GPU pipeline setup, drawable management, and instanced rendering for high-performance particle effects.
- `SSKMetalRenderer` + `SSKMetalEffectStage` – extensible Metal post-processing effect system. Register custom effect passes (blur, bloom, color grading, etc.) without modifying framework code. Supports dynamic effect chains with configurable parameters. Built-in blur and bloom effects included. See `ScreenSaverKit/EFFECT_IMPLEMENTATION_GUIDE.md` for detailed documentation on creating custom Metal shader effects.
- `SSKMetalRenderDiagnostics` – real-time Metal rendering diagnostics overlay. Tracks rendering success/failure rates, displays device/layer/renderer status, and shows FPS. Automatically renders a semi-transparent overlay on your CAMetalLayer for debugging Metal pipeline issues. Perfect for development and troubleshooting GPU initialization problems. See `Demos/MetalParticleTest/` for usage example.

## Using Metal-Accelerated Particles

The particle system supports both CPU (Core Graphics) and GPU (Metal) rendering modes:

**Quick Start:**
```objective-c
// Create particle system
self.particleSystem = [[SSKParticleSystem alloc] initWithCapacity:1024];
self.particleSystem.blendMode = SSKParticleBlendModeAdditive;  // or SSKParticleBlendModeAlpha

// For Metal rendering, set up a CAMetalLayer
self.wantsLayer = YES;
CAMetalLayer *metalLayer = [CAMetalLayer layer];
metalLayer.device = MTLCreateSystemDefaultDevice();
self.layer = metalLayer;
self.metalRenderer = [[SSKMetalParticleRenderer alloc] initWithLayer:metalLayer];

// Spawn particles
[self.particleSystem spawnParticles:100 initializer:^(SSKParticle *particle) {
    particle.position = center;
    particle.velocity = NSMakePoint(cos(angle) * speed, sin(angle) * speed);
    particle.color = [NSColor colorWithHue:hue saturation:0.8 brightness:1.0 alpha:1.0];
    particle.maxLife = 2.0;
    particle.size = 10.0;
    particle.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha | SSKParticleBehaviorOptionFadeSize;
}];

// In animateOneFrame, update and render
[self.particleSystem advanceBy:deltaTime];
[self.particleSystem renderWithMetalRenderer:self.metalRenderer
                                   blendMode:self.particleSystem.blendMode
                                viewportSize:self.bounds.size];
```

**Automatic CPU Fallback:** If Metal initialization fails or the renderer returns `NO`, the particle system automatically falls back to CPU rendering via `drawInContext:` in your `drawRect:` method.

See `Demos/RibbonFlow/` for a complete working example, and `ScreenSaverKit/SSKParticleSystem.md` for detailed API documentation.

### Debugging Metal Rendering

For troubleshooting Metal rendering issues, use `SSKMetalRenderDiagnostics`:

```objective-c
// Create diagnostics helper
self.renderDiagnostics = [[SSKMetalRenderDiagnostics alloc] init];

// Attach to your Metal layer
[self.renderDiagnostics attachToMetalLayer:self.metalLayer];

// Update status as you initialize components
self.renderDiagnostics.deviceStatus = [NSString stringWithFormat:@"Device: %@", device.name];
self.renderDiagnostics.layerStatus = @"Layer: configured";
self.renderDiagnostics.rendererStatus = @"Renderer: ready";

// In animateOneFrame, record rendering attempts
BOOL renderSuccess = [self.particleSystem renderWithMetalRenderer:self.metalRenderer
                                                         blendMode:self.particleSystem.blendMode
                                                      viewportSize:self.bounds.size];
[self.renderDiagnostics recordMetalAttemptWithSuccess:renderSuccess];

// Update overlay with custom info
NSArray *extraInfo = @[
    [NSString stringWithFormat:@"Particles: %lu", self.particleSystem.aliveParticleCount]
];
[self.renderDiagnostics updateOverlayWithTitle:@"My Saver"
                                    extraLines:extraInfo
                               framesPerSecond:self.animationClock.framesPerSecond];
```

The diagnostics overlay displays:
- **Device**: Metal device name and capabilities (e.g., "Apple M1", low power status)
- **Layer**: CAMetalLayer configuration status
- **Renderer**: SSKMetalRenderer initialization state
- **Drawable**: Drawable availability and acquisition success
- **Metal successes / fallbacks**: Running counter of rendering attempts
- **FPS**: Current frame rate

Toggle the overlay on/off with:
```objective-c
self.renderDiagnostics.overlayEnabled = NO;  // Hide overlay
self.renderDiagnostics.overlayEnabled = YES; // Show overlay (default)
```

See `Demos/MetalParticleTest/` for a complete diagnostic implementation example, or `Demos/MetalDiagnostic/` for a low-level Metal sanity checker that tests device, layer, and drawable initialization.

## Starter template

![DVD Logo Demo](documentation-src/dvd-logo.gif)


- `TemplateSaverView.h/.m` – a minimal saver that animates a few shapes and responds to preference changes. Copy and rename these files to kick off a new project.
- `TemplateInfo.plist` – barebones bundle metadata. Update the identifiers and version fields to match your saver.
- `Makefile.demo` – shows how to compile a `.saver` bundle using the template view plus `SSKScreenSaverView`. Run `make -f ScreenSaverKit/Makefile.demo` from your project root (or copy it beside your sources) and tweak the variables at the top for your module name and bundle ID.
- The template demonstrates the configuration sheet helpers (sliders + checkbox), diagnostics overlay toggling, and the animation clock workflow.
- `Demos/HelloWorld/` – a ready-to-build "Hello, World" saver that bounces text around the screen with optional colour cycling. Build it via
  `make -f Demos/HelloWorld/Makefile`. See [tutorial.md](tutorial.md) for a complete walkthrough using this demo.
- `Demos/Starfield/` – a classic faux-3D starfield with optional motion blur and drifting trajectory changes. Build it via `make -f Demos/Starfield/Makefile`.
- `Demos/SimpleLines/` – layered drifting lines with palette selection and adjustable colour cycling speed. Build it via
  `make -f Demos/SimpleLines/Makefile`.
- `Demos/DVDlogo/` – retro floating DVD logo with solid or rotating palette colour modes, adjustable size, speed, colour cycling, and optional random start behaviour. It also uses a multi-file project structure to demo a more advanced project structure. Build it via  `make -f Demos/DVDlogo/Makefile`.
- `Demos/RibbonFlow/` – flowing additive ribbons inspired by the classic Apple Flurry screensaver. Demonstrates Metal-accelerated particle rendering with the `SSKParticleSystem` and `SSKMetalParticleRenderer` working together for smooth, GPU-powered effects. Build it via `make -f Demos/RibbonFlow/Makefile`.
- `Demos/MetalParticleTest/` – diagnostic particle fountain with automatic Metal/CPU fallback. Shows real-time rendering statistics, particle counts, and detailed Metal pipeline status. Perfect for testing GPU availability and debugging Metal particle renderer issues. Build it via `make -f Demos/MetalParticleTest/Makefile`.
- `Demos/MetalDiagnostic/` – low-level Metal sanity checker that displays device capabilities, layer configuration, drawable status, and command buffer lifecycle on-screen. Useful for diagnosing Metal initialization issues or verifying hardware support. Build it via `make -f Demos/MetalDiagnostic/Makefile`.
- `scripts/install-and-refresh.sh` – convenience script that builds, installs, and restarts the relevant macOS services (`legacyScreenSaver`, `WallpaperAgent`, `ScreenSaverEngine`) so macOS immediately sees your latest bundle. Usage:

  ```bash
  ./scripts/install-and-refresh.sh Demos/Starfield
  ./scripts/install-and-refresh.sh ScreenSaverKit -f Makefile.demo
  ```

  The first argument is the directory containing the saver Makefile; any additional arguments are passed straight through to each `make` invocation.
- `scripts/refresh-screensaver-services.sh` – lightweight helper that clears all macOS screen saver caches and optionally relaunches `ScreenSaverEngine`. Clears: System Settings, `legacyScreenSaver`, `WallpaperAgent`, `ScreenSaverEngine`, `cfprefsd` (preferences daemon), `iconservicesd` (icon cache), and `lsd` (Launch Services). Use when you've already installed a bundle:

  ```bash
  ./scripts/refresh-screensaver-services.sh         # clear caches
  ./scripts/refresh-screensaver-services.sh --launch # clear caches + relaunch preview
  ```

⚠️ **macOS caching note:** System Settings aggressively caches screen saver bundles at multiple levels (preferences, icons, bundle metadata, and Launch Services database). If you rebuild but don't see changes, run the install-and-refresh script which automatically clears all caches, or use the refresh script after manually installing your bundle.

## Updating the demo savers after kit changes

If you tweak code inside `ScreenSaverKit/`, rebuild any demos you want to test so they pick up the new implementation:

```bash
cd Demos/Starfield && make clean all
cd Demos/SimpleLines && make clean all
```

After installing the refreshed bundle, restart the caching daemons to force macOS to load the new bits:

```bash
./scripts/refresh-screensaver-services.sh
./scripts/refresh-screensaver-services.sh --launch   # optionally relaunches the preview
```

This mirrors the workflow shown earlier (`make …`, then refresh) and avoids the “preview updated, full screen is stale” confusion that can happen otherwise.

## Building the demo saver

```bash
# From the project root (or wherever you copied the kit)
make -f ScreenSaverKit/Makefile.demo clean all
```

- Outputs a bundle at `ScreenSaverKit/DemoBuild/TemplateSaver.saver`.
- Compiles a **universal binary** that supports both `arm64` (Apple Silicon) and `x86_64` (Intel) via the `-arch` flags already in `Makefile.demo`.
- Verify the architectures with:

  ```bash
  file ScreenSaverKit/DemoBuild/TemplateSaver.saver/Contents/MacOS/TemplateSaver
  ```

- Install locally for testing:

  ```bash
  make -f ScreenSaverKit/Makefile.demo run
  ```

Update `SCREENSAVER_NAME`, `BUNDLE_ID`, and `PRINCIPAL_CLASS` at the top of the Makefile when you adapt the template for your own saver.

## Signing and notarizing

macOS Ventura and newer require downloaded screen savers to be signed with a Developer ID certificate (and ideally notarized) before they will load without warnings. Replace the placeholder values below with your own Team ID and bundle details.

```bash
# Sign the bundle
codesign --force --timestamp --options runtime \
  --identifier com.example.templatesaver \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  ScreenSaverKit/DemoBuild/TemplateSaver.saver

# Optional: verify signature
codesign --verify --strict --verbose=2 ScreenSaverKit/DemoBuild/TemplateSaver.saver

# Optional: zip bundle then submit for notarization (requires a notarytool profile)
ditto -c -k --keepParent ScreenSaverKit/DemoBuild/TemplateSaver.saver \
  ScreenSaverKit/DemoBuild/TemplateSaver.saver.zip
xcrun notarytool submit ScreenSaverKit/DemoBuild/TemplateSaver.saver.zip \
  --keychain-profile your-notary-profile --wait
```

If you follow the same structure as the demo Makefile, you can reuse the root-level `sign`, `zip`, and `notarize` targets (update the variables to match your saver).

## Preference helpers

Use the provided convenience methods when you want to manipulate preferences manually:

- `- (ScreenSaverDefaults *)preferences;`
- `- (NSDictionary<NSString *, id> *)currentPreferences;`
- `- (void)setPreferenceValue:(id)value forKey:(NSString *)key;`
- `- (void)removePreferenceForKey:(NSString *)key;`
- `- (void)resetPreferencesToDefaults;`

## Adapting the Makefile

The root `Makefile` already includes `ScreenSaverKit/SSKScreenSaverView.m` in the build. When starting a new saver:

1. Update `SCREENSAVER_NAME`, `BUNDLE_ID`, and `Info.plist` to match your saver.
2. Add your own `.m` files to the `SOURCES` list.
3. Run `make` or `make test` to produce a `.saver` bundle.

## Updating existing savers

To migrate an older saver code base:

1. Replace `ScreenSaverView` superclass usages with `SSKScreenSaverView`.
2. Remove any custom preference polling timers – the kit handles it now.
3. Move default registration into `-defaultPreferences`.
4. Migrate preference reload code into `-preferencesDidChange:changedKeys:`.

Use these steps to retrofit the kit into existing code and keep the rendering logic focused on your unique saver behavior.

## Troubleshooting

### Metal rendering shows black screen or doesn't activate

**Symptoms:** Metal particle system renders black screen, or always falls back to CPU mode.

**Common causes:**
1. **Fragment shader not receiving instance data** - Ensure the instance buffer is bound to both vertex AND fragment shaders:
   ```objc
   [encoder setVertexBuffer:instanceBuffer offset:0 atIndex:1];
   [encoder setFragmentBuffer:instanceBuffer offset:0 atIndex:1];  // Don't forget this!
   ```

2. **Particles spawning "dead"** - Particles must start with `life = 0.0`, not `life = maxLife`:
   ```objc
   particle.life = 0.0;          // ✅ Correct - particle starts alive
   particle.maxLife = 2.0;
   // NOT: particle.life = particle.maxLife;  // ❌ Particle spawns already dead
   ```

3. **Layer not attached before renderer initialization** - Wait for view to be in window:
   ```objc
   - (void)viewDidMoveToWindow {
       [super viewDidMoveToWindow];
       if (self.window) {
           [self setupMetalRenderer];  // Only after window attachment
       }
   }
   ```

4. **Check Console.app** for Metal shader compilation errors - Filter for "SSKMetalParticleRenderer" to see detailed error messages.

### Changes not appearing after rebuild

**Symptoms:** Rebuilt screen saver but System Settings shows old version.

**Solution:** Run the cache refresh script:
```bash
./scripts/refresh-screensaver-services.sh
```

Or use the full install-and-refresh workflow:
```bash
./scripts/install-and-refresh.sh Demos/YourSaver
```

### Screen saver doesn't appear in System Settings

**Symptoms:** Bundle installed to `~/Library/Screen Savers/` but doesn't show up in list.

**Common causes:**
1. **Bundle not properly formed** - Verify with: `ls -la ~/Library/Screen\ Savers/YourSaver.saver/Contents/MacOS/`
2. **Info.plist issues** - Ensure `NSPrincipalClass` matches your view class name exactly
3. **Launch Services database stale** - The refresh script now clears this automatically

### Preferences not updating in real-time

**Symptoms:** Changes in System Settings don't appear until restarting preview.

**Solution:** The kit polls preferences every 0.5 seconds. Changes should appear automatically. If not:
1. Verify you implemented `preferencesDidChange:changedKeys:`
2. Check that `defaultPreferences` returns the correct keys
3. Ensure you're not caching values that should update
