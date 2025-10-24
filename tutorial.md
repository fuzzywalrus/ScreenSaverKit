# ScreenSaverKit Tutorial – "Hello, World!" Screen Saver

Welcome to ScreenSaverKit! This tutorial will guide you through creating your first macOS screen saver from scratch. By the end, you'll have a working bouncing "Hello, World!" screen saver with customizable preferences like movement speed and color cycling.

## What You'll Learn

- How to build and install a macOS screen saver bundle
- How to use ScreenSaverKit's base class and helper features
- How to add preferences that users can configure in real-time
- How to debug and iterate on your screen saver
- How to create your own custom screen saver from scratch

## What is ScreenSaverKit?

ScreenSaverKit is a modern Objective-C framework that simplifies macOS screen saver development. It handles the boilerplate code for preferences, animation timing, asset loading, and configuration UI, letting you focus on the creative aspects of your screen saver.

---

## Prerequisites

Before you begin, make sure you have:

### 1. **macOS 11 (Big Sur) or later**
   - Check your version: Apple menu → About This Mac

### 2. **Xcode Command Line Tools**
   - Verify installation: `xcode-select -p`
   - If not installed, run: `xcode-select --install`

### 3. **ScreenSaverKit Repository**
   - Clone the repo: `git clone https://github.com/YOUR_USERNAME/ScreenSaverKit.git`
   - Note the absolute path to the cloned directory (we'll call this `${REPO_ROOT}`)

### 4. **Basic Objective-C Knowledge**
   - Familiarity with classes, methods, and the `@interface`/`@implementation` syntax
   - Understanding of basic C programming concepts

**Quick Check:** Open Terminal and run:
```bash
cd /path/to/ScreenSaverKit
ls -la Demos/HelloWorld/
```
You should see files like `HelloWorldView.h`, `HelloWorldView.m`, and `Makefile`.

---

## Step 1: Explore the Demo Screen Saver

ScreenSaverKit includes a complete working example under `Demos/HelloWorld/` that demonstrates all the core features. This demo displays bouncing "Hello, World!" text with smooth color transitions and exposes three user-configurable preferences.

### Understanding the File Structure

Navigate to the demo folder and examine these key files:

| File | Purpose |
| --- | --- |
| **`HelloWorldView.h/.m`** | The main screen saver implementation. Subclasses `SSKScreenSaverView` and implements animation logic. |
| **`Makefile`** | Build script that compiles the `.m` file and packages it into a `.saver` bundle. |
| **`Info.plist`** | Bundle metadata (bundle ID, version, principal class name) that macOS uses to identify and load your screen saver. |

### What the Demo Demonstrates

This example shows you how to:
- **Subclass SSKScreenSaverView** to get automatic preference management and animation timing
- **Define preferences** with default values (speed, color cycling, hue speed)
- **React to preference changes** in real-time without restarting the screen saver
- **Use frame-independent animation** with delta time for smooth motion
- **Build a configuration sheet** so users can adjust settings

**Action:** Take a moment to browse `HelloWorldView.m` and notice the methods like `defaultPreferences`, `preferencesDidChange:`, and `animateOneFrame`. Don't worry if you don't understand everything yet—we'll cover these in detail.

---

## Step 2: Build Your First Screen Saver

Now let's compile the demo into a working screen saver bundle. A `.saver` bundle is just a specially-structured directory that macOS recognizes as a screen saver plugin.

### Building the Bundle

1. **Navigate to the repository root** in Terminal:
   ```bash
   cd /path/to/ScreenSaverKit
   ```

2. **Run the build command:**
   ```bash
   make -f Demos/HelloWorld/Makefile clean all
   ```

   **What's happening?**
   - `clean` removes any previous build artifacts
   - `all` compiles `HelloWorldView.m` with the ScreenSaverKit framework
   - The Makefile creates a universal binary (supports both Intel and Apple Silicon Macs)
   - Output is packaged into `Demos/HelloWorld/Build/HelloWorldDemo.saver`

3. **Verify the build succeeded:**
   ```bash
   ls -lh Demos/HelloWorld/Build/
   ```

   You should see a `HelloWorldDemo.saver` directory. If you see compilation errors, check that Xcode Command Line Tools are installed properly.

### Installing the Screen Saver

1. **Install and open in one step:**
   ```bash
   make -f Demos/HelloWorld/Makefile install
   ```

   This command:
   - Copies `HelloWorldDemo.saver` to `~/Library/Screen Savers/`
   - Opens Finder to show the installed bundle
   - You can now test it in System Settings

2. **Open System Settings:**
   - **macOS 13 (Ventura) or later:** System Settings → Screen Saver
   - **macOS 12 (Monterey) or earlier:** System Preferences → Desktop & Screen Saver → Screen Saver

3. **Find "HelloWorldDemo" in the list** and click it to preview

**Expected Result:** You should see animated "Hello, World!" text bouncing around with color cycling effects. If the preview is blank or shows an error, skip to the Troubleshooting section below.

### Fast rebuilds with the helper script

When you start iterating quickly it's handy to rebuild, install, and refresh the
System Settings cache in one step. Use the helper script from the repository
root and point it at the saver you are working on:

```bash
./scripts/install-and-refresh.sh Demos/HelloWorld
```

If your saver uses a custom Makefile name, pass it through to `make`:

```bash
./scripts/install-and-refresh.sh ScreenSaverKit -f Makefile.demo
```

The script runs `make clean`, `make all`, and `make install`, then restarts `legacyScreenSaver`, `WallpaperAgent`, and `ScreenSaverEngine` so macOS picks up the freshly-built bundle immediately.

When you already have a bundle installed and just need macOS to drop its caches,
use the lighter companion script:

```bash
./scripts/refresh-screensaver-services.sh
# Add --launch to reopen ScreenSaverEngine automatically
./scripts/refresh-screensaver-services.sh --launch
```

---

## Step 3: Understand How the Code Works

Now that you've seen it running, let's dive into the code to understand the key concepts. Open `Demos/HelloWorld/HelloWorldView.m` in your favorite text editor.

### 1. Subclassing SSKScreenSaverView

```objc
@interface HelloWorldView : SSKScreenSaverView
```

**What it does:** By inheriting from `SSKScreenSaverView` (instead of the standard `ScreenSaverView`), you automatically get:
- Built-in preference registration and change detection
- A high-resolution animation clock for smooth, frame-independent animation
- Helper methods for loading assets and managing resources
- Optional diagnostics overlay showing FPS and other stats

**Why it matters:** You don't need to write boilerplate code for managing preferences or timing. ScreenSaverKit handles the tedious parts so you can focus on animation logic.

### 2. Defining Default Preferences

```objc
- (NSDictionary *)defaultPreferences {
    return @{
        @"helloSpeed": @(1.0),           // Movement speed multiplier
        @"helloColorCycling": @(YES),     // Enable/disable color changes
        @"helloColorCycleSpeed": @(0.35)  // How fast colors shift
    };
}
```

**What it does:** This method defines the default values for user-configurable settings. ScreenSaverKit automatically registers these with `NSUserDefaults` when your screen saver first runs.

**Naming tip:** Prefix your preference keys (like `hello*`) to avoid conflicts with other screen savers.

### 3. Responding to Preference Changes

```objc
- (void)preferencesDidChange:(NSDictionary *)prefs changedKeys:(NSSet *)keys {
    [self applyPreferencesDictionary:prefs];
}
```

**What it does:** This method is called:
- Once during initialization (with all default keys)
- Whenever the user changes a preference (with only the changed keys)

**Behind the scenes:** ScreenSaverKit polls `NSUserDefaults` every 0.5 seconds. The demo also calls `refreshPreferencesIfNeeded` in `animateOneFrame` for instant updates during testing.

**How to use:** Extract values from the `prefs` dictionary and update your animation state. The demo delegates to `applyPreferencesDictionary:` which updates instance variables like `_speed` and `_colorCycling`.

### 4. Frame-Independent Animation

```objc
- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];

    // Update position using delta time
    _x += _velocityX * _speed * dt;
    _y += _velocityY * _speed * dt;

    // Draw the frame
    [self setNeedsDisplay:YES];
}
```

**What it does:**
- `advanceAnimationClock` returns the time elapsed since the last frame (`dt`)
- Multiplying movement by `dt` ensures consistent speed regardless of frame rate
- A 60 FPS screen and a 30 FPS screen will show the same motion speed

**Why it matters:** If you just incremented `_x` by a fixed amount each frame, your animation would run twice as fast on a 120 Hz display compared to a 60 Hz display.

### 5. Configuration Window

The demo uses two ScreenSaverKit helpers to build the preferences UI:

- **`SSKConfigurationWindowController`**: Manages the configuration sheet window
- **`SSKPreferenceBinder`**: Automatically syncs UI controls (sliders, checkboxes) with `NSUserDefaults`

**Try it:** Click the "Screen Saver Options..." button in System Settings to see the configuration sheet. Move the sliders and watch the preview update in real-time.

**How it works:** The configuration sheet XIB/NIB file contains standard Cocoa controls that are bound to preference keys using `SSKPreferenceBinder`. No manual event handling code needed!

---

## Step 4: Debugging and Iteration

macOS caches screen saver bundles aggressively, which can make development frustrating. Here's how to work around it.

### The Cache Problem

After making code changes and rebuilding, you might still see the old version running in System Settings. This happens because macOS loads screen savers into memory and doesn't check for updates.

### Solution: Use the Refresh Script

ScreenSaverKit includes a helper script that forces macOS to reload your screen saver:

```bash
./scripts/install-and-refresh.sh
```

**What it does:**
1. Rebuilds your screen saver using `make`
2. Copies the new bundle to `~/Library/Screen Savers/`
3. Kills the background processes (`legacyScreenSaver`, `WallpaperAgent`, `ScreenSaverEngine`)
4. The next time you open System Settings, it loads the fresh version

**Tip:** You can customize this script by editing the `make` target and install path at the top of the file.

### Manual Cache Clearing

If you can't use the script, manually restart these processes:

```bash
killall legacyScreenSaver WallpaperAgent ScreenSaverEngine
```

Then reopen System Settings → Screen Saver.

### Development Workflow

A typical development cycle looks like:

1. Edit code in `HelloWorldView.m`
2. Run `make -f Demos/HelloWorld/Makefile clean all`
3. Run `./scripts/install-and-refresh.sh`
4. Open System Settings and preview your changes
5. Repeat

---

## Step 5: Create Your Own Screen Saver

Now that you understand how the demo works, let's create your own custom screen saver!

### Option A: Start from the HelloWorld Demo

1. **Duplicate the demo folder:**
   ```bash
   cp -r Demos/HelloWorld/ Demos/MyAwesomeSaver/
   cd Demos/MyAwesomeSaver/
   ```

2. **Rename the files:**
   ```bash
   mv HelloWorldView.h MyAwesomeSaverView.h
   mv HelloWorldView.m MyAwesomeSaverView.m
   ```

3. **Update `Info.plist`:**
   - Change `CFBundleIdentifier` to something unique (e.g., `com.yourname.MyAwesomeSaver`)
   - Change `CFBundleName` to "MyAwesomeSaver"
   - Change `NSPrincipalClass` to "MyAwesomeSaverView"

4. **Update the `Makefile`:**
   - Change `TARGET` to `MyAwesomeSaver`
   - Update `SOURCES` to reference `MyAwesomeSaverView.m`

5. **Update the class name in your `.h` and `.m` files:**
   ```objc
   @interface MyAwesomeSaverView : SSKScreenSaverView
   ```

6. **Customize the animation logic** in `animateOneFrame` and add your own creative touches!

### Option B: Start from the Minimal Template

For a barebones starting point, copy `ScreenSaverKit/TemplateSaverView.h/.m` instead. This gives you the minimal structure without the Hello World-specific code.

### What to Customize

Here are some ideas for making your screen saver unique:

1. **Change the drawing code** in `drawRect:` to render different shapes, images, or effects
2. **Add new preferences** by extending `defaultPreferences` and `applyPreferencesDictionary:`
3. **Load custom assets** using SSKScreenSaverView's asset loading helpers
4. **Create particle systems** or other visual effects
5. **Build a custom configuration sheet** with more sophisticated UI controls

### Building and Testing

Once you've made changes:

```bash
cd /path/to/ScreenSaverKit
make -f Demos/MyAwesomeSaver/Makefile clean all install
./scripts/install-and-refresh.sh
```

Your new screen saver should appear in System Settings!

---

## Step 6: Advanced Features

ScreenSaverKit provides additional features beyond what the HelloWorld demo shows:

### Asset Loading

Load images and other resources from your bundle:

```objc
NSImage *myImage = [self loadImageResourceNamed:@"logo.png"];
```

Place assets in your `.saver` bundle's `Resources` folder and reference them by name.

### Diagnostics Overlay

Enable the built-in FPS and performance overlay:

```objc
[self setDiagnosticsEnabled:YES];
```

This displays frame rate, frame time, and other useful stats in the corner of the screen during development.

### Entity Pools

For particle systems or object pooling, use the built-in entity management:

```objc
SSKEntityPool *pool = [[SSKEntityPool alloc] initWithCapacity:100];
```

This helps manage large numbers of animated objects efficiently.

### Multiple Monitor Support

`SSKScreenSaverView` automatically handles multi-monitor setups. Each monitor gets its own instance of your view, allowing you to create coordinated animations across displays.

### Full Documentation

For a complete API reference, check the inline documentation in:
- `ScreenSaverKit/SSKScreenSaverView.h` - Main base class
- `ScreenSaverKit/SSKPreferenceBinder.h` - Preference UI binding
- `ScreenSaverKit/SSKConfigurationWindowController.h` - Configuration window management

---

## Troubleshooting

### Common Issues and Solutions

| Problem | Solution |
| --- | --- |
| **Saver compiles but old behavior shows up** | Run `./scripts/install-and-refresh.sh` or manually quit `legacyScreenSaver`, `WallpaperAgent`, and `ScreenSaverEngine`, then reopen System Settings. |
| **"Cannot find ScreenSaver framework" error** | Make sure Xcode Command Line Tools are installed: `xcode-select --install` |
| **Preferences not updating in real-time** | Verify you're calling `refreshPreferencesIfNeeded` in `animateOneFrame` and that `preferencesDidChange:changedKeys:` is implemented. |
| **Configuration sheet doesn't appear** | Check that your `hasConfigureSheet` method returns `YES` and that you've implemented `configureSheet:`. |
| **Blank/black screen in preview** | Add debug logging to `drawRect:` to verify it's being called. Make sure you're calling `[self setNeedsDisplay:YES]` in `animateOneFrame`. |
| **Missing headers in custom project** | Add `-I/path/to/ScreenSaverKit` to your `CFLAGS` (see the demo Makefile for reference). |
| **Screen saver doesn't appear in System Settings** | Verify your `Info.plist` has the correct `NSPrincipalClass` and that the bundle is properly installed in `~/Library/Screen Savers/`. |

### Debugging Tips

1. **Add logging:** Use `NSLog(@"...")` liberally during development to understand execution flow
2. **Check Console.app:** Open Console.app and filter for your bundle ID to see crash logs and errors
3. **Test in preview mode:** Always test in System Settings preview before testing the full-screen activation
4. **Simplify your code:** If something breaks, comment out sections until you find the problematic code
5. **Check memory usage:** Screen savers should be lightweight. Use Instruments.app to profile if needed

### Getting Help

- Check the inline documentation in the `.h` header files
- Look at the HelloWorld demo for reference implementations
- Review the README.md for architecture overview
- File issues on the ScreenSaverKit GitHub repository

---

## Next Steps

Congratulations! You now have a solid understanding of ScreenSaverKit and can create your own custom macOS screen savers.

### Ideas for Your Next Screen Saver

- **Animated clock or calendar** with beautiful typography
- **Photo slideshow** with smooth transitions and effects
- **Particle simulation** (rain, snow, fireworks, etc.)
- **Generative art** with procedural patterns
- **System monitor** displaying CPU, memory, network stats
- **Quote or word-of-the-day** display with elegant animations
- **3D visualizations** using Core Animation or OpenGL
- **Conway's Game of Life** or other cellular automata

### Resources

- **ScreenSaverKit GitHub:** [github.com/YOUR_USERNAME/ScreenSaverKit](https://github.com/YOUR_USERNAME/ScreenSaverKit)
- **Apple's ScreenSaver Framework Docs:** [developer.apple.com](https://developer.apple.com/documentation/screensaver)
- **Objective-C Programming Guide:** [developer.apple.com](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/)

### Share Your Work

If you create something cool with ScreenSaverKit, consider:
- Sharing it with the community
- Contributing improvements back to ScreenSaverKit
- Writing about your development experience

Happy screen saver building!
