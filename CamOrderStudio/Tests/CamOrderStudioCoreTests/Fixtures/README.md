# Export control fixture

`red.mp4` is a synthetic solid red 64×64, one-second video. The automatic-motion export test uses this preencoded source so a capture encoder failure does not hide an export failure. It still renders through CamOrder and checks actual output pixels in MOV and MP4.

Recreate with:

```sh
ffmpeg -f lavfi -i 'color=c=red:s=64x64:r=30:d=1' -c:v libx264 -preset veryslow -crf 10 -pix_fmt yuv420p -movflags +faststart red.mp4
```
