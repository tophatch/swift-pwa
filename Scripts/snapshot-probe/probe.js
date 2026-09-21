(async () => {
  const out = { variants: {} };
  const dump = __DUMP__;
  let shotBase64Length = 0;
  let shotPngBase64 = '';
  const can = await __SWIFT_PWA__.invoke('window.canSnapshot');
  out.canSnapshot = can.value;
  if (!can.value) return JSON.stringify(out);

  const measure = async () => {
    const t0 = performance.now();
    const shot = await __SWIFT_PWA__.invoke('window.snapshot');
    const bridgeMs = performance.now() - t0;
    shotBase64Length = shot.pngBase64.length;
    shotPngBase64 = shot.pngBase64;
    const blob = await (await fetch('data:image/png;base64,' + shot.pngBase64)).blob();
    const bitmap = await createImageBitmap(blob);
    return { shot, bitmap, ms: Math.round(performance.now() - t0), bridgeMs: Math.round(bridgeMs) };
  };

  // One snapshot thrown away first. The first call of the run pays a one-off
  // cost — on iOS it measured 134 ms against 53 ms for the *larger* frame right
  // after it — and reporting that as the cost of a page curl would be wrong in
  // the direction that matters.
  await window.__showVariant('flat');
  (await measure()).bitmap.close();

  // How many distinct colours a 32x32 patch holds. True noise fills it;
  // anything that resampled, blurred or averaged on the way through collapses
  // it — which a single sampled pixel and a plausible byte count both miss.
  const patchDetail = (source, w, h) => {
    const canvas = document.createElement('canvas');
    canvas.width = 32;
    canvas.height = 32;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(source, Math.floor(w * 0.5), Math.floor(h * 0.6), 32, 32, 0, 0, 32, 32);
    const px = ctx.getImageData(0, 0, 32, 32).data;
    const seen = new Set();
    for (let i = 0; i < px.length; i += 4) seen.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
    return seen.size;
  };

  const sample = (bitmap, fx, fy) => {
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(bitmap, 0, 0);
    const px = ctx.getImageData(
      Math.floor(bitmap.width * fx), Math.floor(bitmap.height * fy), 1, 1
    ).data;
    return '#' + [px[0], px[1], px[2]].map(v => v.toString(16).padStart(2, '0')).join('');
  };

  for (const name of ['flat', 'text', 'noise']) {
    await window.__showVariant(name);
    const m = await measure();
    out.variants[name] = {
      ms: m.ms, bridgeMs: m.bridgeMs, kib: Math.round(m.shot.bytes / 1024),
      // Every variant gets a pixel read out of it, not just the first: a
      // backend whose snapshot silently misses `<canvas>` content would
      // otherwise sail through, reported only as a suspiciously small PNG.
      sample: sample(m.bitmap, 0.75, 0.75),
      detail: patchDetail(m.bitmap, m.shot.width, m.shot.height),
      // `bytes` is what the backend said; this is what actually arrived.
      // GTK3 reported a `noise` frame of 59 KiB whose pixels were full-detail
      // noise, which is not something a lossless encoder can do — so the
      // reported size and the delivered bytes are worth separating.
      b64Bytes: Math.round(shotBase64Length * 3 / 4)
    };
    if (dump) out.variants[name].png = shotPngBase64;
    // What the page itself holds, for the same patch — the control that says
    // whether a thin `noise` frame is the backend's doing or the page's.
    if (name === 'noise') {
      const c = document.getElementById('noise');
      out.canvasDetail = patchDetail(c, c.width, c.height);
    }
    if (name !== 'flat') { m.bitmap.close(); continue; }

    // The flat frame is the one the size and colour checks read.
    out.width = m.shot.width;
    out.height = m.shot.height;
    out.decodedWidth = m.bitmap.width;
    out.decodedHeight = m.bitmap.height;
    out.expectedWidth = Math.round(window.innerWidth * window.devicePixelRatio);
    out.expectedHeight = Math.round(window.innerHeight * window.devicePixelRatio);

    out.inside = sample(m.bitmap, 0.25, 0.25);   // the red mark
    out.outside = sample(m.bitmap, 0.75, 0.75);  // the blue page behind it
    m.bitmap.close();
  }
  return JSON.stringify(out);
})()
