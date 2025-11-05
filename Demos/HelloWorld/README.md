# HelloWorld Screen Saver Demo

A simple, beginner-friendly screen saver that displays bouncing "Hello, World!" text with color cycling effects. This demo is the perfect starting point for learning how to create macOS screen savers with ScreenSaverKit.

![HelloWorld Demo](../../documentation-src/hello-world.gif)

---

## What This Demo Does

**HelloWorld** shows animated "Hello, World!" text that:
- ✨ Bounces smoothly around your screen
- 🎨 Changes colors continuously (when color cycling is enabled)
- ⚙️ Responds to user preferences in real-time
- 📊 Shows FPS (frames per second) diagnostics overlay

**User Controls:**
- **Speed Multiplier** - How fast the text moves (0.2x to 3x)
- **Color Cycling** - Enable/disable rainbow color transitions
- **Color Cycle Speed** - How fast colors change (0.1 to 2.0)

---

## Quick Start

### Build and Run

From the repository root:

```bash
# Build the screen saver
make -f Demos/HelloWorld/Makefile clean all

# Install to your Screen Savers folder
make -f Demos/HelloWorld/Makefile install

# Or do both in one step with auto-refresh
./scripts/install-and-refresh.sh Demos/HelloWorld
```

### Test It

1. **Open System Settings** (macOS 13+) or **System Preferences** (macOS 12 and earlier)
2. Go to **Screen Saver** (or **Desktop & Screen Saver → Screen Saver**)
3. Find **"HelloWorldDemo"** in the list
4. Click it to see a live preview
5. Click **"Screen Saver Options..."** to adjust settings

---

## What You'll Learn

This demo teaches you the **fundamentals** of ScreenSaverKit:

### 1. **Basic Screen Saver Structure**
- How to subclass `SSKScreenSaverView`
- The animation loop (`animateOneFrame`)
- Drawing with Core Graphics (`drawRect:`)

### 2. **Preference Management**
- Defining default preferences
- Reading and applying user settings
- Real-time preference updates

### 3. **Configuration UI**
- Creating a settings window
- Binding sliders and checkboxes to preferences
- Using `SSKPreferenceBinder` for automatic synchronization

### 4. **Animation Timing**
- Frame-independent animation with delta time
- Smooth movement at any frame rate
- Using the animation clock

### 5. **Physics & Collision**
- Velocity-based movement
- Bouncing off screen edges
- Simple collision detection

---

## Code Walkthrough

### File Structure

```
Demos/HelloWorld/
├── HelloWorldView.h        # View class interface
├── HelloWorldView.m        # Main implementation (214 lines)
├── Info.plist             # Bundle metadata
├── Makefile               # Build configuration
└── README.md              # This file
```

### Key Code Sections

#### **1. Default Preferences** (Lines 26-32)

```objc
- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        @"helloSpeed": @(1.0),           // Normal speed
        @"helloColorCycling": @(YES),    // Colors enabled
        @"helloColorCycleSpeed": @(0.35) // Medium color change speed
    };
}
```

**What it does:** Defines the initial values for user settings. These are saved in `~/Library/Preferences/ByHost/com.apple.screensaver.*.plist`.

#### **2. Animation Loop** (Lines 47-80)

```objc
- (void)animateOneFrame {
    // 1. Get time since last frame
    NSTimeInterval dt = [self advanceAnimationClock];

    // 2. Update position based on velocity and time
    pos.x += vel.x * self.speedMultiplier * dt;
    pos.y += vel.y * self.speedMultiplier * dt;

    // 3. Bounce off edges
    if (pos.x - halfWidth < NSMinX(bounds) || ...) {
        vel.x = -vel.x;  // Reverse horizontal direction
    }

    // 4. Update color
    if (self.colorCycling) {
        self.hue += self.hueSpeed * dt;
    }

    // 5. Trigger redraw
    [self setNeedsDisplay:YES];
}
```

**What it does:** Called 60 times per second. Updates the text position, handles bouncing, and updates colors.

**Key concept:** Using `dt` (delta time) ensures smooth animation regardless of frame rate.

#### **3. Drawing** (Lines 82-112)

```objc
- (void)drawRect:(NSRect)dirtyRect {
    // 1. Clear screen (black background)
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    // 2. Draw colored bubble behind text
    NSColor *bubbleColor = [NSColor colorWithHue:self.hue
                                      saturation:0.8
                                      brightness:1.0
                                           alpha:0.35];
    [bubbleColor setFill];
    [roundedBubble fill];

    // 3. Draw white "Hello, World!" text
    [hello drawInRect:textRect withAttributes:attrs];

    // 4. Draw FPS overlay
    [SSKDiagnostics drawOverlayInView:self ...];
}
```

**What it does:** Renders the screen saver graphics using Core Graphics/AppKit drawing.

#### **4. Configuration Sheet** (Lines 127-158)

```objc
- (NSWindow *)configureSheet {
    // Create configuration window
    self.configController = [[SSKConfigurationWindowController alloc]
        initWithSaverView:self
                    title:@"Hello World"
                 subtitle:@"Tweak movement and colour cycling."];

    // Add speed slider
    [binder bindSlider:speedSlider
                   key:@"helloSpeed"
            valueLabel:valueLabel
                format:@"%.2fx"];

    // Add color cycling checkbox
    [binder bindCheckbox:colorToggle key:@"helloColorCycling"];

    return self.configController.window;
}
```

**What it does:** Creates the settings window with sliders and checkboxes. `SSKPreferenceBinder` automatically syncs UI controls with saved preferences.

---

## How It Works: Animation Flow

```
┌──────────────────────────────────────────────────────────┐
│ 1. macOS calls animateOneFrame (60 times/second)         │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 2. Calculate time since last frame (dt)                  │
│    dt = [self advanceAnimationClock]  // ~0.016s @ 60fps │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 3. Update position                                        │
│    position.x += velocity.x * speed * dt                 │
│    position.y += velocity.y * speed * dt                 │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 4. Check for collisions with screen edges                │
│    If hit left/right: velocity.x = -velocity.x           │
│    If hit top/bottom: velocity.y = -velocity.y           │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 5. Update color (if cycling enabled)                     │
│    hue += hueSpeed * dt                                  │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 6. Trigger redraw                                         │
│    [self setNeedsDisplay:YES]                            │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│ 7. macOS calls drawRect:                                  │
│    - Clear screen (black)                                │
│    - Draw colored bubble                                 │
│    - Draw "Hello, World!" text                           │
│    - Draw FPS overlay                                    │
└──────────────────────────────────────────────────────────┘
```

---

## Understanding the Physics

### Position Update Formula

```objc
position.x += velocity.x * speedMultiplier * deltaTime
```

**Breaking it down:**
- `velocity.x` = 140 pixels/second (defined at initialization)
- `speedMultiplier` = 1.0 by default (user can change with slider)
- `deltaTime` = ~0.0167 seconds (at 60 FPS)
- **Result:** Text moves ~2.33 pixels per frame horizontally

**Why multiply by deltaTime?**
- Without it: Movement depends on frame rate
  - 60 FPS: moves 140 pixels/frame = 8400 pixels/second ❌
  - 30 FPS: moves 140 pixels/frame = 4200 pixels/second ❌
- With it: Movement is consistent
  - 60 FPS: 140 × 1.0 × 0.0167 × 60 = 140 pixels/second ✅
  - 30 FPS: 140 × 1.0 × 0.033 × 30 = 140 pixels/second ✅

### Bounce Physics

```objc
if (pos.x - halfWidth < leftEdge || pos.x + halfWidth > rightEdge) {
    vel.x = -vel.x;  // Reverse direction
    pos.x = clamp(pos.x, leftEdge, rightEdge);  // Keep in bounds
}
```

**What happens:**
1. Check if text center ± half width hits screen edge
2. If collision detected, flip velocity direction
3. Clamp position to prevent getting stuck outside bounds

---

## Customization Ideas

Want to experiment? Try modifying:

### **Easy Changes**

1. **Change the text:**
   ```objc
   NSString *hello = @"Your Text Here!";
   ```

2. **Change colors:**
   ```objc
   // Rainbow: saturation:0.8
   // Pastel: saturation:0.3
   // Grayscale: saturation:0.0
   NSColor *color = [NSColor colorWithHue:self.hue
                                saturation:0.8  // ← Change this
                                brightness:1.0
                                     alpha:1.0];
   ```

3. **Change speed:**
   ```objc
   self.velocity = NSMakePoint(200.0, 180.0);  // Faster
   self.velocity = NSMakePoint(50.0, 40.0);    // Slower
   ```

### **Intermediate Changes**

4. **Add rotation:**
   ```objc
   // In animateOneFrame:
   self.rotation += 90.0 * dt;  // Degrees per second

   // In drawRect:
   CGContextRotateCTM(ctx, self.rotation * M_PI / 180.0);
   ```

5. **Add multiple bouncing texts:**
   ```objc
   @property (nonatomic, strong) NSMutableArray<NSDictionary *> *textObjects;
   // Each dictionary stores position, velocity, hue, text
   ```

6. **Add gravity:**
   ```objc
   // In animateOneFrame:
   vel.y += -200.0 * dt;  // Gravity pulls down
   ```

### **Advanced Changes**

7. **Add trails/blur effect** (see RibbonFlow demo)
8. **Switch to particle system** (see MetalParticleTest demo)
9. **Add sound reactivity** (analyze audio input)

---

## Preference Keys Explained

HelloWorld uses three preference keys (defined as constants at lines 9-11):

```objc
static NSString * const kPrefSpeedMultiplier   = @"helloSpeed";
static NSString * const kPrefColorCycling      = @"helloColorCycling";
static NSString * const kPrefColorCycleSpeed   = @"helloColorCycleSpeed";
```

**Why prefix with "hello"?**
- Prevents conflicts with other screen savers
- macOS stores all screen saver preferences in the same file
- Unique prefixes ensure your settings don't clash

**Where are they stored?**
```
~/Library/Preferences/ByHost/com.apple.screensaver.<UUID>.plist
```

**How to reset preferences:**
```bash
# Delete saved preferences (will use defaults on next launch)
defaults delete com.apple.screensaver
```

---

## Debugging Tips

### **1. View Console Logs**

```bash
# Open Console.app and filter for "HelloWorld"
# or watch logs in Terminal:
log stream --predicate 'subsystem == "com.apple.screensaver"' --level debug
```

### **2. Add Debug Logging**

```objc
// In animateOneFrame:
NSLog(@"Position: (%.1f, %.1f), Velocity: (%.1f, %.1f)",
      self.position.x, self.position.y,
      self.velocity.x, self.velocity.y);
```

### **3. Enable Diagnostics Overlay**

The FPS overlay is already enabled (line 109-111). It shows:
- Current frame rate
- Screen saver name
- Useful for performance monitoring

### **4. Test in Preview Mode First**

Always test in System Settings preview before testing full-screen:
- Easier to quit (click anywhere)
- Can see System Settings UI
- Faster iteration

### **5. Force Reload**

If changes don't appear after rebuilding:

```bash
# Clear macOS caches
./scripts/refresh-screensaver-services.sh

# Or manually
killall legacyScreenSaver WallpaperAgent ScreenSaverEngine
```

---

## Common Issues

### **Problem: Text disappears or gets stuck**

**Cause:** Position clamping might be too aggressive
**Fix:** Check bounds calculation in lines 62-69

### **Problem: Text moves too fast at different resolutions**

**Cause:** Not using delta time properly
**Fix:** Always multiply movement by `dt` (see line 59-60)

### **Problem: Preferences don't save**

**Cause:** Preference keys might conflict or not be registered
**Fix:** Check `defaultPreferences` returns correct dictionary (line 26-32)

### **Problem: Configuration sheet doesn't appear**

**Cause:** `hasConfigureSheet` might return NO
**Fix:** Ensure line 125 returns YES

---

## Performance Notes

**CPU Usage:** Very low (~2-5% on modern Macs)
- Simple Core Graphics drawing
- No expensive operations
- Runs at 60 FPS smoothly

**Memory Usage:** Minimal (~10-15 MB)
- No texture caching
- No object pooling needed
- Static text rendering

**Optimization Opportunities:**
- ✅ Already optimized for this use case
- Text could be pre-rendered to texture (overkill for one string)
- Could use Metal for effects (see RibbonFlow demo)

---

## Next Steps

### **Want to Learn More?**

1. **Complete Tutorial** - See [tutorial.md](../../tutorial.md) for step-by-step walkthrough
2. **More Advanced Demos:**
   - `SimpleLines/` - Particle-style line animation
   - `Starfield/` - 3D starfield with motion blur
   - `DVDLogo/` - Classic bouncing DVD logo
   - `RibbonFlow/` - Metal-accelerated particle ribbons

3. **Framework Documentation:**
   - `ScreenSaverKit/SSKScreenSaverView.h` - Base class API
   - `ScreenSaverKit/SSKConfigurationWindowController.h` - Settings UI
   - `ScreenSaverKit/SSKPreferenceBinder.h` - Preference binding

### **Create Your Own Screen Saver**

```bash
# Copy HelloWorld as a template
cp -r Demos/HelloWorld Demos/MyAwesomeSaver

# Rename files
cd Demos/MyAwesomeSaver
mv HelloWorldView.h MyAwesomeSaverView.h
mv HelloWorldView.m MyAwesomeSaverView.m

# Update Info.plist and Makefile
# Change bundle ID, class name, etc.

# Build and test!
make -f Demos/MyAwesomeSaver/Makefile clean all install
```

---

## Questions?

- **GitHub Issues:** [Report bugs or ask questions](https://github.com/fuzzywalrus/ScreenSaverKit/issues)
- **Main README:** See [../../README.md](../../README.md) for framework overview
- **Tutorial:** See [../../tutorial.md](../../tutorial.md) for detailed walkthrough

---

## License

Same as ScreenSaverKit - see repository root for details.

---

**Happy screen saver building!** 🎉

This demo proves you can create something fun and functional in ~200 lines of code. Now imagine what you can build with the full power of ScreenSaverKit!
