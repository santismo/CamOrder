# Motion fixture

`motion.mp4` is a synthetic 320×180, one-second FFmpeg test pattern, with no user media. A checked-in fixture lets metadata and project transactions be tested without requiring an encoder first.

Recreate with:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=1' -c:v libx264 -preset veryslow -crf 28 -pix_fmt yuv420p -movflags +faststart motion.mp4
```
