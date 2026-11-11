import test from 'node:test';
import assert from 'node:assert/strict';
import { CameraSession, cameraError } from '../../phone-camera/camera.mjs';

function fakeStream() {
  const track = new EventTarget();
  track.readyState = 'live';
  track.muted = false;
  track.stopCount = 0;
  track.stop = () => { track.stopCount++; track.readyState = 'ended'; };
  return { track, getTracks: () => [track], getVideoTracks: () => [track] };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}

test('requests camera only, at a bounded frame rate, with the requested lens', async () => {
  let constraints;
  const stream = fakeStream();
  const camera = new CameraSession({ getUserMedia: async c => { constraints = c; return stream; } });
  assert.equal(await camera.start({ camera: 'user', quality: '720' }), stream);
  assert.equal(constraints.audio, false);
  assert.deepEqual(constraints.video.facingMode, { ideal: 'user' });
  assert.equal(constraints.video.width.ideal, 1280);
  assert.equal(constraints.video.frameRate.max, 30);
  camera.stop();
  assert.equal(stream.track.stopCount, 1);
  assert.equal(camera.state, 'idle');
});

test('stop while permission is pending discards and stops the late stream', async () => {
  const pending = deferred(), stream = fakeStream();
  const camera = new CameraSession({ getUserMedia: () => pending.promise });
  const opening = camera.start();
  camera.stop();
  pending.resolve(stream);
  assert.equal(await opening, null);
  assert.equal(stream.track.stopCount, 1);
  assert.equal(camera.stream, null);
  assert.equal(camera.state, 'idle');
});

test('a delayed older request cannot replace the newly selected camera', async () => {
  const first = deferred(), second = deferred();
  let calls = 0;
  const camera = new CameraSession({ getUserMedia: () => ++calls === 1 ? first.promise : second.promise });
  const opening1 = camera.start({ camera: 'environment' });
  const opening2 = camera.start({ camera: 'user' });
  const oldStream = fakeStream(), newStream = fakeStream();
  second.resolve(newStream); await opening2;
  first.resolve(oldStream); await opening1;
  assert.equal(camera.stream, newStream);
  assert.equal(oldStream.track.stopCount, 1);
  assert.equal(newStream.track.stopCount, 0);
  camera.stop();
});

test('switching releases the old camera before asking iOS for the new one', async () => {
  const oldStream = fakeStream(), newStream = fakeStream();
  let calls = 0;
  const camera = new CameraSession({ getUserMedia: async c => {
    if (++calls === 1) return oldStream;
    assert.equal(oldStream.track.stopCount, 1);
    assert.deepEqual(c.video.deviceId, { exact: 'rear-wide' });
    return newStream;
  } });
  await camera.start();
  await camera.start({ camera: 'rear-wide' });
  oldStream.track.dispatchEvent(new Event('ended'));
  assert.equal(camera.state, 'live');
  assert.equal(camera.stream, newStream);
  camera.stop();
});

test('permission denial leaves no active stream and can be retried', async () => {
  let calls = 0;
  const stream = fakeStream();
  const states = [];
  const denied = Object.assign(new Error('denied'), { name: 'NotAllowedError' });
  const camera = new CameraSession({ getUserMedia: async () => { if (++calls === 1) throw denied; return stream; } }, (s,e) => states.push([s,e]));
  await camera.start();
  assert.equal(camera.state, 'error');
  assert.equal(camera.stream, null);
  assert.match(cameraError(states.at(-1)[1]), /Allow Camera/);
  await camera.start();
  assert.equal(camera.state, 'live');
  camera.stop();
});

test('a rejected stale request does not overwrite a newer live state', async () => {
  const pending = deferred(); let calls = 0;
  const stream = fakeStream();
  const camera = new CameraSession({ getUserMedia: () => ++calls === 1 ? pending.promise : Promise.resolve(stream) });
  const old = camera.start();
  await camera.start();
  pending.reject(new Error('old request failed')); await old;
  assert.equal(camera.state, 'live');
  assert.equal(camera.stream, stream);
  camera.stop();
});

test('mute, resume and disconnected tracks report real preview state', async () => {
  const stream = fakeStream();
  const camera = new CameraSession({ getUserMedia: async () => stream });
  await camera.start();
  stream.track.dispatchEvent(new Event('mute'));
  assert.equal(camera.state, 'paused');
  stream.track.dispatchEvent(new Event('unmute'));
  assert.equal(camera.state, 'live');
  stream.track.dispatchEvent(new Event('ended'));
  assert.equal(camera.state, 'ended');
  assert.equal(camera.stream, null);
});

test('invalid streams are released without reporting a live preview', async () => {
  const stream = fakeStream(); stream.getVideoTracks = () => [];
  const camera = new CameraSession({ getUserMedia: async () => stream });
  assert.equal(await camera.start(), null);
  assert.equal(stream.track.stopCount, 1);
  assert.equal(camera.state, 'error');
});
