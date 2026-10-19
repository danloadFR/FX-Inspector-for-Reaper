# FX Inspector (REAPER script)

**FX Inspector** is a script designed to allow fine adjustment of the parameters of an effect or instrument instance in any of the following FX chains:

- A track's FX chain (*Track FX*);
- A track's Input FX chain;
- The Master track's FX chain (*Master FX*);
- The Monitoring FX chain;
- An Item or Take FX chain.

Whether the plugin is inside or outside a container.

## Why FX Inspector?

In most effect and instrument plugin interfaces, parameters are represented by sliders (*faders*) or rotary controls (*knobs*). Adjusting their values precisely can sometimes be difficult, especially when the actual value is not displayed numerically and can only be estimated from the position of the slider or rotary control.

REAPER's native FX interface doesn't really solve this problem either, since it also relies on sliders.

Take a gain control, for example: changing its value by just 0.1 dB, or even 0.5 dB, can be difficult with some interfaces, even though such a small difference can make a significant audible difference. The same applies to many other types of parameters.

## How does it work?

FX Inspector displays the parameters of the currently focused plugin in a dedicated window, in table form, along with their current values and two buttons, **− and +**, for decreasing or increasing those values.

- Clicking either button changes the value by one step;
- Holding the mouse button down repeats the adjustment continuously;
- Holding the **Ctrl** key multiplies the adjustment speed by 10;
- Holding the **Alt** key multiplies it by 50.

**Only one FX Inspector window can be open at a time**: there is no separate window for each plugin. The window's contents are automatically updated whenever the focus moves from one plugin to another.

The most convenient approach is therefore to position the window in a corner of the REAPER interface, or in a *docker*, and simply let it update automatically as you work.

## Why does it *try* to solve the problem?

The word “try” is intentional: three essential pieces of information depend, in principle, on what the plugin makes available to REAPER:

1. **Parameter names.**
2. **How the current value is formatted and displayed.**
3. **The adjustment step**, i.e. the increment or decrement between successive values.

Unfortunately, some plugins, whether free or commercial, do not provide this information correctly. As a result:

1. Parameter names may be unclear or even completely cryptic;
2. The value's display format may be unavailable, in which case the value is shown simply as a number between 0 and 1;
3. The adjustment step may not be specified.

In short, some plugins leave a bit to be desired…

There isn't really much that can be done about the first two limitations when the necessary information is missing. However, FX Inspector attempts to estimate the adjustment step when it is not provided, so that values can still be adjusted as precisely as possible.

*By “focus”, I mean either a plugin whose interface window is in the foreground or a plugin selected in an FX chain window.*

## Compatibility

The script has only been tested on Windows. Although it should theoretically be compatible with macOS and Linux, testing by community members would be greatly appreciated to confirm compatibility on these platforms and identify any potential bugs.
