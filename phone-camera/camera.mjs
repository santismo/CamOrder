// Camera lifecycle is independent of the UI so cancellation and switching can be tested.
export class CameraSession {
  constructor(mediaDevices, onState = () => {}) {
    this.mediaDevices = mediaDevices;
    this.onState = onState;
    this.stream = null;
    this.generation = 0;
    this.state = 'idle';
  }
  emit(state, error = null) {
    this.state = state;
    this.onState(state, error);
  }
  release() {
    const stream = this.stream;
    this.stream = null;
    stream?.getTracks().forEach(track => track.stop());
  }
  async start({ camera = 'environment', quality = '1080' } = {}) {
    const generation = ++this.generation;
    this.release(); // iOS often requires releasing one lens before opening another.
    this.emit('starting');
    let candidate;
    try {
      const video = {
        width: { ideal: quality === '720' ? 1280 : 1920 },
        height: { ideal: quality === '720' ? 720 : 1080 },
        frameRate: { ideal: 30, max: 30 }
      };
      if (camera === 'environment' || camera === 'user') video.facingMode = { ideal: camera };
      else video.deviceId = { exact: camera };
      candidate = await this.mediaDevices.getUserMedia({ audio: false, video });
      if (generation !== this.generation) {
        candidate.getTracks().forEach(track => track.stop());
        return null;
      }
      const track = candidate.getVideoTracks()[0];
      if (!track || track.readyState === 'ended') throw new Error('The camera did not provide a live video track.');
      this.stream = candidate;
      track.addEventListener('ended', () => {
        if (this.stream !== candidate) return;
        ++this.generation;
        this.release();
        this.emit('ended');
      });
      track.addEventListener('mute', () => { if (this.stream === candidate) this.emit('paused'); });
      track.addEventListener('unmute', () => { if (this.stream === candidate) this.emit('live'); });
      this.emit(track.muted ? 'paused' : 'live');
      return candidate;
    } catch (error) {
      candidate?.getTracks().forEach(track => track.stop());
      if (generation === this.generation) {
        this.stream = null;
        this.emit('error', error);
      }
      return null;
    }
  }
  stop() {
    ++this.generation; // A pending permission prompt must not restart a stopped camera.
    this.release();
    this.emit('idle');
  }
}

export function cameraError(error) {
  switch (error?.name) {
    case 'NotAllowedError': return 'Camera access is blocked. Allow Camera for this website in Safari’s website settings, then tap Start camera again.';
    case 'NotFoundError': return 'No camera was found. Try this page in Safari on your iPhone or iPad.';
    case 'NotReadableError': case 'AbortError': return 'The camera could not start. Close other apps using it, keep this device unlocked, and try again.';
    case 'OverconstrainedError': return 'That camera or quality is unavailable. Choose Front camera or Back camera, try 720p, then start again.';
    case 'SecurityError': return 'Camera access is restricted by this browser or device. Open the HTTPS page in Safari and check camera permissions.';
    default: return error?.message || 'The camera stopped unexpectedly. Tap Start camera to try again.';
  }
}
