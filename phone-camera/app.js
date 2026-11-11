import { CameraSession, cameraError } from './camera.mjs';

const $ = id => document.getElementById(id);
const preview = $('preview');
let preferences = {};
try { preferences = JSON.parse(localStorage.getItem('camorder-camera-preferences') || '{}') || {}; } catch {}
$('quality').value = preferences.quality === '720' ? '720' : '1080';
$('camera').value = preferences.camera === 'user' ? 'user' : 'environment';
document.body.dataset.mirror = String(preferences.mirror === true);
document.body.dataset.fit = preferences.fit === 'fill' ? 'fill' : 'fit';
$('mirror').setAttribute('aria-pressed', document.body.dataset.mirror);
$('fit').setAttribute('aria-pressed', String(document.body.dataset.fit === 'fill'));
$('fitLabel').textContent = document.body.dataset.fit === 'fill' ? 'Fill' : 'Fit';
let wakeLock = null;
let wakeRequest = 0;
let state = 'idle';
let backgrounded = false;

function savePreferences() {
  const camera = $('camera').value;
  try {
    localStorage.setItem('camorder-camera-preferences', JSON.stringify({
      camera: camera === 'user' ? 'user' : camera === 'environment' ? 'environment' : (session.stream?.getVideoTracks()[0]?.getSettings().facingMode || 'environment'),
      quality: $('quality').value, mirror: document.body.dataset.mirror === 'true', fit: document.body.dataset.fit
    }));
  } catch {}
}

async function releaseWakeLock() {
  ++wakeRequest;
  const lock = wakeLock;
  wakeLock = null;
  if (lock) { try { await lock.release(); } catch {} }
}
async function keepAwake() {
  if (wakeLock && !wakeLock.released) return;
  const request = ++wakeRequest;
  if (!navigator.wakeLock) {
    $('awakeInfo').textContent = 'Set Auto-Lock to Never while capturing.';
    return;
  }
  try {
    const lock = await navigator.wakeLock.request('screen');
    if (request !== wakeRequest || state !== 'live' || document.hidden) { await lock.release(); return; }
    wakeLock = lock;
    $('awakeInfo').textContent = 'Screen kept awake · Leave this app open.';
    lock.addEventListener('release', () => {
      if (wakeLock !== lock) return;
      wakeLock = null;
      $('awakeInfo').textContent = 'Keep-awake released. Check Auto-Lock before a take.';
    });
  } catch { $('awakeInfo').textContent = 'Keep-awake unavailable. Set Auto-Lock to Never.'; }
}

function cleanView(clean) {
  if (clean && state !== 'live') return;
  document.body.classList.toggle('clean', clean);
  $('restore').hidden = !clean;
  document.querySelectorAll('.hud').forEach(el => { el.inert = clean; });
  if (clean) $('restore').focus({ preventScroll: true });
}

function updateState(nextState, error) {
  state = nextState;
  document.body.dataset.state = state;
  if (state !== 'live') cleanView(false);
  $('welcome').hidden = state === 'live';
  $('cleanButton').disabled = state !== 'live';
  $('stopButton').disabled = !['starting', 'live', 'paused'].includes(state);
  $('camera').disabled = state === 'starting';
  $('quality').disabled = state === 'starting';
  $('statusText').textContent = ({ idle: 'Camera off', starting: 'Opening camera…', live: 'Preview live', paused: 'Camera paused', ended: 'Camera stopped', error: 'Camera unavailable' })[state];
  $('startLabel').textContent = state === 'starting' ? 'Cancel' : state === 'paused' ? 'Resume camera' : 'Start camera';
  $('welcomeTitle').innerHTML = state === 'paused' ? 'Camera paused' : 'Your camera.<br><span>In CamOrder.</span>';
  $('intro').textContent = state === 'paused' ? 'Keep this app open. Tap Resume camera if the picture does not return.' : state === 'starting' ? 'Allow camera access when your device asks.' : 'Open on your iPhone or iPad. Connect to your Mac. Get the shot.';
  $('error').hidden = state !== 'error' && state !== 'ended';
  $('error').textContent = state === 'ended' ? 'The camera connection ended. Keep the device unlocked and tap Start camera.' : error ? cameraError(error) : '';
  if (!['live', 'paused'].includes(state)) {
    preview.srcObject = null;
    $('streamInfo').textContent = 'Choose this device in CamOrder’s Live Inputs.';
  }
  if (state === 'live' && !document.hidden) keepAwake();
  else {
    releaseWakeLock();
    $('awakeInfo').textContent = 'Keep this page open while capturing.';
  }
}

const session = new CameraSession(navigator.mediaDevices, updateState);

async function listCameras() {
  if (!navigator.mediaDevices?.enumerateDevices) return;
  try {
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput' && d.deviceId);
    const selected = $('camera').value;
    const activeID = session.stream?.getVideoTracks()[0]?.getSettings().deviceId;
    const choices = [new Option('Back camera', 'environment'), new Option('Front camera', 'user')];
    for (const [i, device] of devices.entries()) choices.push(new Option(device.label || `Camera ${i + 1}`, device.deviceId));
    $('camera').replaceChildren(...choices);
    $('camera').value = choices.some(o => o.value === selected) ? selected : activeID && choices.some(o => o.value === activeID) ? activeID : 'environment';
  } catch { /* Front/back choices still work without a device list. */ }
}

async function startCamera() {
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    updateState('error', new Error('Open the HTTPS version of this page in Safari to use the camera. Local file previews cannot access it.'));
    return;
  }
  const stream = await session.start({ camera: $('camera').value, quality: $('quality').value });
  if (!stream || session.stream !== stream) return;
  preview.srcObject = stream;
  try {
    await preview.play();
    if (session.stream !== stream) return;
    const settings = stream.getVideoTracks()[0].getSettings();
    $('streamInfo').textContent = `${settings.width || '?'} × ${settings.height || '?'} · ${settings.frameRate ? Math.round(settings.frameRate) : '?'} fps camera`;
    await listCameras();
    savePreferences();
  } catch (error) {
    if (session.stream !== stream) return;
    session.stop();
    updateState('error', error);
  }
}

$('startButton').addEventListener('click', () => state === 'starting' ? session.stop() : startCamera());
$('stopButton').addEventListener('click', () => session.stop());
for (const id of ['camera', 'quality']) $(id).addEventListener('change', () => { savePreferences(); if (session.stream) startCamera(); });
$('mirror').addEventListener('click', () => {
  document.body.dataset.mirror = String(document.body.dataset.mirror !== 'true');
  $('mirror').setAttribute('aria-pressed', document.body.dataset.mirror);
  savePreferences();
});
$('fit').addEventListener('click', () => {
  const fill = document.body.dataset.fit !== 'fill';
  document.body.dataset.fit = fill ? 'fill' : 'fit';
  $('fit').setAttribute('aria-pressed', String(fill));
  $('fitLabel').textContent = fill ? 'Fill' : 'Fit';
  savePreferences();
});
$('cleanButton').addEventListener('click', async () => {
  cleanView(true);
  // Standalone Home Screen mode is the primary fullscreen path on iPhone.
  if (!document.fullscreenElement && document.documentElement.requestFullscreen) {
    try { await document.documentElement.requestFullscreen(); } catch {}
  }
});
$('restore').addEventListener('click', () => { cleanView(false); $('cleanButton').focus(); });
$('helpButton').addEventListener('click', () => $('help').showModal());
$('closeHelp').addEventListener('click', () => $('help').close());
document.addEventListener('keydown', event => { if (event.key === 'Escape') cleanView(false); });
document.addEventListener('fullscreenchange', () => { if (!document.fullscreenElement) cleanView(false); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    backgrounded = !!session.stream;
    if (backgrounded) updateState('paused');
  } else if (backgrounded) {
    backgrounded = false;
    const track = session.stream?.getVideoTracks()[0];
    if (track?.readyState === 'live' && !track.muted) { updateState('live'); preview.play().catch(() => updateState('paused')); }
  }
});
window.addEventListener('pagehide', () => session.stop());
navigator.mediaDevices?.addEventListener?.('devicechange', listCameras);

if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('./sw.js', { scope: './' }).then(async registration => {
    await navigator.serviceWorker.ready;
    $('offlineStatus').textContent = 'Offline ready';
    if (registration.waiting) $('offlineStatus').textContent = 'Update ready. Close and reopen after your take.';
    registration.addEventListener('updatefound', () => {
      registration.installing?.addEventListener('statechange', () => {
        if (registration.waiting) $('offlineStatus').textContent = 'Update ready. Close and reopen after your take.';
      });
    });
  }).catch(() => { $('offlineStatus').textContent = 'Offline setup unavailable. Reopen online in Safari.'; });
} else $('offlineStatus').textContent = 'Offline access requires HTTPS and a supported browser.';
