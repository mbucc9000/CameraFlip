<img src="icon.png" width="80" align="right" alt="">

# CameraFlip

Snapchat-style camera flip for the iOS 6 Camera app: double-tap the preview to switch cameras, for photos and videos. Even mid-recording, without stopping: one continuous video.

## Features

- Double-tap the Camera preview to switch between the back and front cameras, for photos and videos.
- Even while recording: the video doesn't stop, it's one continuous clip, and the sound keeps going through the flip.
- Both cameras are saved at the same 1080p size. Front-camera footage follows MirrorFront if you have it.
- In photo mode, double-tap no longer switches the preview between fit and full screen.

## How to use

1. In Camera, double-tap the preview to switch between the back and front cameras.
2. It works while recording too. Stop as usual: it's one video.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **CameraFlip**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.
