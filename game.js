/* ============================================================
   ¡HOYO! — Puerto Rico downhill pothole racer
   Three.js r128 · desktop + mobile · runs from file://
   ============================================================ */
(function () {
'use strict';

window.onerror = function (msg, src, line) {
  var box = document.getElementById('errbox');
  box.style.display = 'block';
  box.textContent += 'ERROR: ' + msg + '\n  at ' + src + ':' + line + '\n';
};

if (typeof THREE === 'undefined') { throw new Error('three.min.js failed to load'); }

// ---------------- helpers ----------------
var clamp = function (v, a, b) { return v < a ? a : v > b ? b : v; };
var seed = 20260727;
function rnd() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }

var IS_TOUCH = ('ontouchstart' in window) || navigator.maxTouchPoints > 0 ||
               location.search.indexOf('touch') >= 0;
if (IS_TOUCH) document.body.classList.add('touch');

// ---------------- the road path ----------------
var STEP = 2;
var COUNT = 1801;                    // 3600 m run
var TOTAL = (COUNT - 1) * STEP;
var ROAD_HALF = 4.5;

var pts = [], tans = [], rights = [], grades = [], curvs = [];

(function buildPath() {
  var x = 0, z = 0, y = 0, i, s;
  for (i = 0; i < COUNT; i++) {
    s = i * STEP;
    var h = 0.55 * Math.sin(s / 173) + 0.45 * Math.sin(s / 59 + 1.7) +
            0.5 * Math.sin(s / 311 + 4.0) + 0.3 * Math.sin(s / 47 + 2.5);
    var endFade = clamp((TOTAL - 100 - s) / 260, 0, 1);
    var grade = (0.055 + 0.04 * Math.sin(s / 210 + 0.5) + 0.024 * Math.sin(s / 83)) * endFade;
    pts.push(new THREE.Vector3(x, y, z));
    grades.push(-grade);
    x += Math.sin(h) * STEP;
    z -= Math.cos(h) * STEP;
    y -= grade * STEP;
  }
  var lift = 5.5 - pts[COUNT - 1].y;
  for (i = 0; i < COUNT; i++) pts[i].y += lift;

  var headings = [];
  for (i = 0; i < COUNT; i++) {
    var a = pts[Math.max(0, i - 1)], b = pts[Math.min(COUNT - 1, i + 1)];
    var t = b.clone().sub(a).normalize();
    tans.push(t);
    rights.push(new THREE.Vector3(-t.z, 0, t.x).normalize());
    headings.push(Math.atan2(t.x, -t.z));
  }
  for (i = 0; i < COUNT; i++) {
    var h0 = headings[Math.max(0, i - 1)], h1 = headings[Math.min(COUNT - 1, i + 1)];
    var dh = h1 - h0;
    if (dh > Math.PI) dh -= Math.PI * 2;
    if (dh < -Math.PI) dh += Math.PI * 2;
    curvs.push(dh / (2 * STEP));
  }
})();

var _pos = new THREE.Vector3(), _tan = new THREE.Vector3(), _rgt = new THREE.Vector3();
function sampleAt(s) {
  var f = clamp(s / STEP, 0, COUNT - 1.001);
  var i = Math.floor(f); f -= i;
  _pos.copy(pts[i]).lerp(pts[i + 1], f);
  _tan.copy(tans[i]).lerp(tans[i + 1], f).normalize();
  _rgt.copy(rights[i]).lerp(rights[i + 1], f).normalize();
  return i;
}

function groundY(i, lat) {
  i = clamp(Math.round(i), 0, COUNT - 1);
  var p = pts[i], s = i * STEP;
  var d = Math.abs(lat) - ROAD_HALF;
  if (d <= 0) return p.y;
  var yy;
  if (lat < 0) {
    var k = 0.42 + 0.18 * Math.sin(s / 140 + 1) + 0.10 * Math.sin(s / 47);
    yy = p.y + d * k + Math.sin(d * 0.22 + s * 0.013) * Math.min(d * 0.15, 4);
  } else {
    var k2 = 0.34 + 0.12 * Math.sin(s / 120 + 2);
    yy = p.y - d * k2 + Math.sin(d * 0.19 + s * 0.017) * Math.min(d * 0.12, 3);
  }
  return Math.max(yy, -3.6);
}

// ---------------- renderer & scene ----------------
var scene = new THREE.Scene();
var FOG_COLOR = 0xffab78;
scene.fog = new THREE.Fog(FOG_COLOR, 260, 2400);

var camera = new THREE.PerspectiveCamera(74, innerWidth / innerHeight, 0.1, 9000);
var renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(devicePixelRatio, IS_TOUCH ? 1.5 : 2));
renderer.setSize(innerWidth, innerHeight);
renderer.outputEncoding = THREE.sRGBEncoding;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.15;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
document.body.appendChild(renderer.domElement);

addEventListener('resize', function () {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

// golden-hour lighting
scene.add(new THREE.HemisphereLight(0xd88fc8, 0x2e6b4f, 0.75));
var sun = new THREE.DirectionalLight(0xffd2a0, 1.5);
sun.castShadow = true;
sun.shadow.mapSize.width = sun.shadow.mapSize.height = IS_TOUCH ? 1024 : 2048;
sun.shadow.camera.left = -38; sun.shadow.camera.right = 38;
sun.shadow.camera.top = 38; sun.shadow.camera.bottom = -38;
sun.shadow.camera.near = 5; sun.shadow.camera.far = 320;
sun.shadow.bias = -0.0006;
scene.add(sun);
scene.add(sun.target);

// ---------------- sky, sun, stars, clouds ----------------
(function makeSky() {
  var cv = document.createElement('canvas'); cv.width = 16; cv.height = 512;
  var g = cv.getContext('2d');
  var gr = g.createLinearGradient(0, 0, 0, 512);
  gr.addColorStop(0.00, '#241155');
  gr.addColorStop(0.36, '#792a92');
  gr.addColorStop(0.57, '#ea4a80');
  gr.addColorStop(0.72, '#ff8a54');
  gr.addColorStop(0.83, '#ffd48f');
  gr.addColorStop(1.00, '#ffab78');
  g.fillStyle = gr; g.fillRect(0, 0, 16, 512);
  var tex = new THREE.CanvasTexture(cv);
  var dome = new THREE.Mesh(
    new THREE.SphereGeometry(4200, 24, 16),
    new THREE.MeshBasicMaterial({ map: tex, side: THREE.BackSide, fog: false })
  );
  dome.position.set(0, -300, -1400);
  scene.add(dome);

  var sunDisc = new THREE.Mesh(
    new THREE.CircleGeometry(150, 40),
    new THREE.MeshBasicMaterial({ color: 0xffc76b, fog: false })
  );
  sunDisc.position.set(300, 170, -3600); sunDisc.lookAt(0, 120, 0);
  scene.add(sunDisc);
  var glow = new THREE.Mesh(
    new THREE.CircleGeometry(360, 40),
    new THREE.MeshBasicMaterial({ color: 0xff9a5c, transparent: true, opacity: 0.35,
      blending: THREE.AdditiveBlending, fog: false, depthWrite: false })
  );
  glow.position.copy(sunDisc.position); glow.position.z -= 5; glow.lookAt(0, 120, 0);
  scene.add(glow);

  // faint early stars in the violet band
  var sp = new Float32Array(250 * 3);
  for (var i = 0; i < 250; i++) {
    var a = rnd() * Math.PI * 2, r = 2400 + rnd() * 1200;
    sp[i * 3] = Math.cos(a) * r;
    sp[i * 3 + 1] = 900 + rnd() * 1700;
    sp[i * 3 + 2] = -1400 + Math.sin(a) * r;
  }
  var sg = new THREE.BufferGeometry();
  sg.setAttribute('position', new THREE.BufferAttribute(sp, 3));
  scene.add(new THREE.Points(sg, new THREE.PointsMaterial({
    color: 0xfff4ff, size: 3, transparent: true, opacity: 0.5,
    fog: false, sizeAttenuation: false })));
})();

(function clouds() {
  var N = 42;
  var mesh = new THREE.InstancedMesh(
    new THREE.SphereGeometry(1, 10, 7),
    new THREE.MeshBasicMaterial({ color: 0xffcdb8 }), N);
  var m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), v = new THREE.Vector3(), sc = new THREE.Vector3();
  var n = 0;
  for (var c = 0; c < 14; c++) {
    var cx = (rnd() - 0.5) * 2400, cy = 430 + rnd() * 260, cz = -300 - rnd() * 2700;
    for (var k = 0; k < 3 && n < N; k++) {
      v.set(cx + (rnd() - 0.5) * 90, cy + (rnd() - 0.5) * 14, cz + (rnd() - 0.5) * 50);
      sc.set(45 + rnd() * 70, 10 + rnd() * 9, 26 + rnd() * 34);
      m4.compose(v, q, sc);
      mesh.setMatrixAt(n++, m4);
    }
  }
  mesh.instanceMatrix.needsUpdate = true;
  scene.add(mesh);
})();

// ---------------- animated ocean (custom shader) ----------------
var waterUniforms = {
  time: { value: 0 },
  sunDir: { value: new THREE.Vector3(0.28, 0.2, -0.94).normalize() },
  fogColor: { value: new THREE.Color(FOG_COLOR) }
};
(function makeOcean() {
  var geo = new THREE.PlaneGeometry(9000, 9000, 140, 140);
  geo.rotateX(-Math.PI / 2);
  var mat = new THREE.ShaderMaterial({
    uniforms: waterUniforms,
    vertexShader: [
      'uniform float time;',
      'varying vec3 vPos;',
      'float wave(vec2 p, float t){',
      '  return sin(p.x*0.02 + t*0.8)*sin(p.y*0.016 - t*0.6)*1.1',
      '       + sin(p.x*0.045 + t*1.4)*0.45 + sin(p.y*0.05 + t*1.1)*0.4;',
      '}',
      'void main(){',
      '  vec3 p = position;',
      '  p.y += wave(p.xz, time);',
      '  vec4 wp = modelMatrix * vec4(p, 1.0);',
      '  vPos = wp.xyz;',
      '  gl_Position = projectionMatrix * viewMatrix * wp;',
      '}'
    ].join('\n'),
    fragmentShader: [
      'uniform float time;',
      'uniform vec3 sunDir;',
      'uniform vec3 fogColor;',
      'varying vec3 vPos;',
      'void main(){',
      '  vec2 p = vPos.xz;',
      // analytic normal from wave derivatives (adds per-pixel ripple detail)
      '  float e = 0.0;',
      '  float dx = cos(p.x*0.02 + time*0.8)*sin(p.y*0.016 - time*0.6)*0.022',
      '           + cos(p.x*0.045 + time*1.4)*0.020',
      '           + cos(p.x*0.32 + time*2.6)*0.05;',
      '  float dz = sin(p.x*0.02 + time*0.8)*cos(p.y*0.016 - time*0.6)*0.018',
      '           + cos(p.y*0.05 + time*1.1)*0.020',
      '           + cos(p.y*0.27 - time*2.2)*0.05;',
      '  vec3 n = normalize(vec3(-dx, 1.0, -dz));',
      '  vec3 viewDir = normalize(cameraPosition - vPos);',
      '  float diff = max(dot(n, sunDir), 0.0);',
      '  vec3 base = mix(vec3(0.05,0.22,0.38), vec3(0.10,0.42,0.55), diff);',
      '  vec3 refl = reflect(-sunDir, n);',
      '  float spec = pow(max(dot(refl, viewDir), 0.0), 120.0);',
      '  vec3 col = base + vec3(1.0,0.72,0.4) * spec * 2.2;',
      '  float fres = pow(1.0 - max(dot(viewDir, n), 0.0), 3.0);',
      '  col = mix(col, vec3(1.0,0.62,0.45), fres*0.55);',
      '  float fogF = smoothstep(300.0, 2400.0, length(cameraPosition - vPos));',
      '  col = mix(col, fogColor, fogF);',
      '  gl_FragColor = vec4(col, 1.0);',
      '}'
    ].join('\n')
  });
  var ocean = new THREE.Mesh(geo, mat);
  ocean.position.set(0, -3.0, -1600);
  scene.add(ocean);
})();

// ---------------- road (textured asphalt) ----------------
function asphaltTexture() {
  var cv = document.createElement('canvas'); cv.width = cv.height = 256;
  var g = cv.getContext('2d');
  g.fillStyle = '#34383e'; g.fillRect(0, 0, 256, 256);
  for (var i = 0; i < 5200; i++) {
    var v = 40 + Math.random() * 40;
    g.fillStyle = 'rgba(' + (v | 0) + ',' + (v + 4 | 0) + ',' + (v + 9 | 0) + ',' +
      (0.25 + Math.random() * 0.5).toFixed(2) + ')';
    g.fillRect(Math.random() * 256, Math.random() * 256, 1.6, 1.6);
  }
  g.strokeStyle = 'rgba(18,18,22,0.5)'; g.lineWidth = 1;
  for (var c = 0; c < 7; c++) {
    g.beginPath();
    var cx = Math.random() * 256, cy = Math.random() * 256;
    g.moveTo(cx, cy);
    for (var st = 0; st < 5; st++) { cx += (Math.random() - 0.5) * 46; cy += Math.random() * 30; g.lineTo(cx, cy); }
    g.stroke();
  }
  var tex = new THREE.CanvasTexture(cv);
  tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
  tex.anisotropy = renderer.capabilities.getMaxAnisotropy();
  return tex;
}

(function buildRoad() {
  var verts = [], uvs = [], idx = [], i;
  for (i = 0; i < COUNT; i++) {
    var p = pts[i], r = rights[i];
    verts.push(p.x - r.x * ROAD_HALF, p.y, p.z - r.z * ROAD_HALF,
               p.x + r.x * ROAD_HALF, p.y, p.z + r.z * ROAD_HALF);
    uvs.push(0, i * STEP / 9, 1, i * STEP / 9);
    if (i < COUNT - 1) {
      var a = i * 2;
      idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    }
  }
  var g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  g.setIndex(idx);
  g.computeVertexNormals();
  var road = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ map: asphaltTexture() }));
  road.receiveShadow = true;
  scene.add(road);

  function ribbon(l0, l1, color, dashed) {
    var v = [], id = [], n = 0, j;
    for (j = 0; j < COUNT - 1; j++) {
      if (dashed && (j % 8) > 3) continue;
      var p0 = pts[j], r0 = rights[j], p1 = pts[j + 1], r1 = rights[j + 1];
      v.push(p0.x + r0.x * l0, p0.y + 0.03, p0.z + r0.z * l0,
             p0.x + r0.x * l1, p0.y + 0.03, p0.z + r0.z * l1,
             p1.x + r1.x * l0, p1.y + 0.03, p1.z + r1.z * l0,
             p1.x + r1.x * l1, p1.y + 0.03, p1.z + r1.z * l1);
      id.push(n, n + 1, n + 2, n + 1, n + 3, n + 2); n += 4;
    }
    var gg = new THREE.BufferGeometry();
    gg.setAttribute('position', new THREE.Float32BufferAttribute(v, 3));
    gg.setIndex(id);
    scene.add(new THREE.Mesh(gg, new THREE.MeshBasicMaterial({ color: color })));
  }
  ribbon(-0.14, 0.14, 0xc9ad36, true);
  ribbon(-4.32, -4.1, 0xcfd4d8, false);
  ribbon(4.1, 4.32, 0xcfd4d8, false);
})();

// ---------------- terrain ----------------
(function buildTerrain() {
  var LATS_L = [-4.2, -7, -12, -20, -34, -60, -95, -145];
  var LATS_R = [4.2, 7, 12, 20, 34, 60, 95, 145];
  var col = new THREE.Color();

  function side(LATS) {
    var verts = [], cols = [], idx = [], rows = 0, i, j;
    for (i = 0; i < COUNT; i += 2) {
      var p = pts[i], r = rights[i];
      for (j = 0; j < LATS.length; j++) {
        var lat = LATS[j];
        var y = j === 0 ? p.y - 0.09 : groundY(i, lat);   // tuck under the road, no seams
        verts.push(p.x + r.x * lat, y, p.z + r.z * lat);
        if (y < 1.8) {
          col.setHSL(0.11, 0.45, 0.66 + 0.05 * Math.sin(i * 0.7 + j));
        } else {
          var n = 0.5 + 0.5 * Math.sin(i * 0.085 + j * 1.6) * Math.sin(i * 0.041 + 2.0);
          col.setHSL(0.33 - n * 0.05, 0.58, 0.26 + n * 0.12);
        }
        cols.push(col.r, col.g, col.b);
      }
      rows++;
    }
    var W = LATS.length;
    for (i = 0; i < rows - 1; i++) {
      for (j = 0; j < W - 1; j++) {
        var a = i * W + j;
        idx.push(a, a + W, a + 1, a + 1, a + W, a + W + 1);
      }
    }
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3));
    g.setAttribute('color', new THREE.Float32BufferAttribute(cols, 3));
    g.setIndex(idx);
    g.computeVertexNormals();
    var m = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ vertexColors: true }));
    m.receiveShadow = true;
    scene.add(m);
  }
  side(LATS_L);
  side(LATS_R);
})();

// ---------------- vegetation & props ----------------
var _m4 = new THREE.Matrix4(), _q = new THREE.Quaternion(), _e = new THREE.Euler(),
    _v3 = new THREE.Vector3(), _sc = new THREE.Vector3();

function setInst(mesh, idx2, x, y, z, rx, ry, rz, s) {
  _e.set(rx, ry, rz); _q.setFromEuler(_e);
  _sc.set(s, s, s); _v3.set(x, y, z);
  _m4.compose(_v3, _q, _sc);
  mesh.setMatrixAt(idx2, _m4);
}

function palmCanopyGeo() {
  var pos = [], FR = 7, i;
  for (i = 0; i < FR; i++) {
    var a = i / FR * Math.PI * 2 + 0.3;
    var dx = Math.cos(a), dz = Math.sin(a);
    var px = -dz * 0.45, pz = dx * 0.45;
    var mx = dx * 1.7, my = -0.2, mz = dz * 1.7;
    var tx = dx * 3.2, ty = -1.6, tz = dz * 3.2;
    pos.push(0, 0.15, 0, mx + px, my, mz + pz, tx, ty, tz);
    pos.push(0, 0.15, 0, tx, ty, tz, mx - px, my, mz - pz);
  }
  var g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.computeVertexNormals();
  return g;
}

(function vegetation() {
  var i;
  var NP = 170;
  var trunks = new THREE.InstancedMesh(
    new THREE.CylinderGeometry(0.13, 0.24, 7, 5).translate(0, 3.5, 0),
    new THREE.MeshLambertMaterial({ color: 0x8a6a45 }), NP);
  var canopies = new THREE.InstancedMesh(
    palmCanopyGeo(),
    new THREE.MeshLambertMaterial({ color: 0x2f9b52, side: THREE.DoubleSide }), NP);
  if (!IS_TOUCH) { trunks.castShadow = true; canopies.castShadow = true; }
  var placed = 0, guard = 0;
  while (placed < NP && guard++ < 3500) {
    var pi = 20 + Math.floor(rnd() * (COUNT - 60));
    var lat = (rnd() < 0.55 ? 1 : -1) * (7 + rnd() * 45);
    var gy = groundY(pi, lat);
    if (gy < -1) continue;
    var p = pts[pi], r = rights[pi];
    var wx = p.x + r.x * lat, wz = p.z + r.z * lat;
    var lean = (rnd() - 0.5) * 0.24, leanZ = (rnd() - 0.5) * 0.24;
    var sc = 0.8 + rnd() * 0.7;
    setInst(trunks, placed, wx, gy - 0.3, wz, lean, rnd() * 6.28, leanZ, sc);
    _e.set(lean, 0, leanZ); _q.setFromEuler(_e);
    _v3.set(0, 6.9 * sc, 0).applyQuaternion(_q);
    setInst(canopies, placed, wx + _v3.x, gy - 0.3 + _v3.y, wz + _v3.z, 0, rnd() * 6.28, 0, sc);
    placed++;
  }
  trunks.instanceMatrix.needsUpdate = true;
  canopies.instanceMatrix.needsUpdate = true;
  scene.add(trunks); scene.add(canopies);

  var NF = 45;
  var ftr = new THREE.InstancedMesh(
    new THREE.CylinderGeometry(0.2, 0.34, 2.6, 5).translate(0, 1.3, 0),
    new THREE.MeshLambertMaterial({ color: 0x6e5138 }), NF);
  var fcan = new THREE.InstancedMesh(
    new THREE.SphereGeometry(2.4, 8, 6).scale(1, 0.55, 1),
    new THREE.MeshLambertMaterial({ color: 0xffffff }), NF);
  var fcol = new THREE.Color();
  placed = 0; guard = 0;
  while (placed < NF && guard++ < 2000) {
    var fi = 30 + Math.floor(rnd() * (COUNT - 80));
    var flat = (rnd() < 0.5 ? 1 : -1) * (6.5 + rnd() * 26);
    var fgy = groundY(fi, flat);
    if (fgy < 0) continue;
    var fp = pts[fi], fr = rights[fi];
    var fsc = 0.8 + rnd() * 0.9;
    setInst(ftr, placed, fp.x + fr.x * flat, fgy - 0.2, fp.z + fr.z * flat, 0, rnd() * 6.28, (rnd() - 0.5) * 0.15, fsc);
    setInst(fcan, placed, fp.x + fr.x * flat, fgy - 0.2 + 2.9 * fsc, fp.z + fr.z * flat, 0, rnd() * 6.28, 0, fsc);
    fcol.setHSL(0.02 + rnd() * 0.04, 0.92, 0.5 + rnd() * 0.08);
    fcan.setColorAt(placed, fcol);
    placed++;
  }
  ftr.instanceMatrix.needsUpdate = true;
  fcan.instanceMatrix.needsUpdate = true;
  if (fcan.instanceColor) fcan.instanceColor.needsUpdate = true;
  scene.add(ftr); scene.add(fcan);

  var NH = 34;
  var homes = new THREE.InstancedMesh(
    new THREE.BoxGeometry(4.2, 3, 5).translate(0, 1.5, 0),
    new THREE.MeshLambertMaterial({ color: 0xffffff }), NH);
  var roofs = new THREE.InstancedMesh(
    new THREE.ConeGeometry(3.7, 1.7, 4).translate(0, 0.85, 0),
    new THREE.MeshLambertMaterial({ color: 0xffffff }), NH);
  var palette = [0xff6b9d, 0x4ecdc4, 0xffe66d, 0x95e1d3, 0xf38181, 0xa8d8ea, 0xffb347, 0xc3f584];
  var hc = new THREE.Color(), rc = new THREE.Color();
  placed = 0; guard = 0;
  while (placed < NH && guard++ < 2000) {
    var hi = 40 + Math.floor(rnd() * (COUNT - 120));
    var hlat = (rnd() < 0.5 ? 1 : -1) * (9.5 + rnd() * 9);
    var hgy = groundY(hi, hlat);
    if (hgy < 0.5) continue;
    var hp = pts[hi], hr = rights[hi];
    var yaw = Math.atan2(tans[hi].x, -tans[hi].z) + (rnd() - 0.5) * 0.5;
    var hx = hp.x + hr.x * hlat, hz = hp.z + hr.z * hlat;
    var hsc = 0.9 + rnd() * 0.5;
    setInst(homes, placed, hx, hgy - 0.3, hz, 0, yaw, 0, hsc);
    setInst(roofs, placed, hx, hgy - 0.3 + 3 * hsc, hz, 0, yaw + Math.PI / 4, 0, hsc);
    hc.setHex(palette[Math.floor(rnd() * palette.length)]);
    homes.setColorAt(placed, hc);
    rc.copy(hc).multiplyScalar(0.55);
    roofs.setColorAt(placed, rc);
    placed++;
  }
  homes.instanceMatrix.needsUpdate = true; roofs.instanceMatrix.needsUpdate = true;
  if (homes.instanceColor) homes.instanceColor.needsUpdate = true;
  if (roofs.instanceColor) roofs.instanceColor.needsUpdate = true;
  scene.add(homes); scene.add(roofs);

  var NR = 60;
  var rocks = new THREE.InstancedMesh(
    new THREE.DodecahedronGeometry(1, 0),
    new THREE.MeshLambertMaterial({ color: 0x77705f }), NR);
  for (i = 0; i < NR; i++) {
    var ri = 10 + Math.floor(rnd() * (COUNT - 30));
    var rlat = -(6 + rnd() * 40);
    var rp = pts[ri], rr = rights[ri];
    setInst(rocks, i, rp.x + rr.x * rlat, groundY(ri, rlat), rp.z + rr.z * rlat,
      rnd() * 3, rnd() * 3, rnd() * 3, 0.5 + rnd() * 1.6);
  }
  rocks.instanceMatrix.needsUpdate = true;
  scene.add(rocks);

  var NG = Math.floor(COUNT / 4);
  var posts = new THREE.InstancedMesh(
    new THREE.BoxGeometry(0.16, 0.85, 0.16).translate(0, 0.42, 0),
    new THREE.MeshLambertMaterial({ color: 0xe8e8e8 }), NG);
  for (i = 0; i < NG; i++) {
    var gi = i * 4;
    var gp = pts[gi], gr = rights[gi];
    setInst(posts, i, gp.x + gr.x * 5.1, gp.y, gp.z + gr.z * 5.1, 0, 0, 0, 1);
  }
  posts.instanceMatrix.needsUpdate = true;
  scene.add(posts);
})();

// ---------------- PR flags, arches, umbrellas ----------------
function flagTexture() {
  var cv = document.createElement('canvas'); cv.width = 150; cv.height = 100;
  var g = cv.getContext('2d');
  for (var i = 0; i < 5; i++) { g.fillStyle = i % 2 ? '#ffffff' : '#e02237'; g.fillRect(0, i * 20, 150, 20); }
  g.fillStyle = '#0050a0';
  g.beginPath(); g.moveTo(0, 0); g.lineTo(87, 50); g.lineTo(0, 100); g.closePath(); g.fill();
  g.fillStyle = '#ffffff';
  g.beginPath();
  for (var k = 0; k < 5; k++) {
    var an = -Math.PI / 2 + k * 2 * Math.PI / 5;
    var xx = 30 + Math.cos(an) * 14, yy = 50 + Math.sin(an) * 14;
    if (k === 0) g.moveTo(xx, yy); else g.lineTo(xx, yy);
    an += Math.PI / 5;
    g.lineTo(30 + Math.cos(an) * 6, 50 + Math.sin(an) * 6);
  }
  g.closePath(); g.fill();
  return new THREE.CanvasTexture(cv);
}

(function props() {
  var flagTex = flagTexture();
  var poleGeo = new THREE.CylinderGeometry(0.05, 0.07, 4.4, 5).translate(0, 2.2, 0);
  var poleMat = new THREE.MeshLambertMaterial({ color: 0xbfc6cc });
  var flagGeo = new THREE.PlaneGeometry(1.6, 1.05);
  var flagMat = new THREE.MeshLambertMaterial({ map: flagTex, side: THREE.DoubleSide });
  for (var i = 0; i < 10; i++) {
    var fi = 60 + Math.floor(i * (COUNT - 120) / 10);
    var lat = (i % 2 ? 6.1 : -6.1);
    var p = pts[fi], r = rights[fi];
    var gy = groundY(fi, lat);
    var pole = new THREE.Mesh(poleGeo, poleMat);
    pole.position.set(p.x + r.x * lat, Math.max(gy, p.y), p.z + r.z * lat);
    var flag = new THREE.Mesh(flagGeo, flagMat);
    flag.position.set(0.82, 3.75, 0);
    flag.rotation.y = rnd() * 6.28;
    pole.add(flag);
    scene.add(pole);
  }

  function arch(i2, text, colorHex) {
    var p = pts[i2], t = tans[i2];
    var grp = new THREE.Group();
    var postGeo = new THREE.CylinderGeometry(0.14, 0.14, 6, 6).translate(0, 3, 0);
    var postMat = new THREE.MeshLambertMaterial({ color: 0xf2f2f2 });
    var pa = new THREE.Mesh(postGeo, postMat); pa.position.set(-5.1, 0, 0);
    var pb = new THREE.Mesh(postGeo, postMat); pb.position.set(5.1, 0, 0);
    grp.add(pa); grp.add(pb);
    var cv = document.createElement('canvas'); cv.width = 512; cv.height = 84;
    var g = cv.getContext('2d');
    g.fillStyle = colorHex; g.fillRect(0, 0, 512, 84);
    g.fillStyle = '#fff'; g.font = 'italic 900 58px Arial'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(text, 256, 44);
    var ban = new THREE.Mesh(new THREE.PlaneGeometry(10.6, 1.6),
      new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(cv), side: THREE.DoubleSide }));
    ban.position.y = 5.6;
    grp.add(ban);
    grp.position.copy(p);
    grp.lookAt(p.clone().add(t));
    scene.add(grp);
  }
  arch(6, '¡SALIDA!', '#e02237');
  arch(COUNT - 8, '¡META!', '#0050a0');

  var umbGeo = new THREE.ConeGeometry(1.5, 0.7, 8).translate(0, 1.9, 0);
  var umbPole = new THREE.CylinderGeometry(0.04, 0.04, 2, 4).translate(0, 1, 0);
  var umbCols = [0xff2d78, 0xffd23f, 0x12d7c3, 0xff8a5c];
  for (var u = 0; u < 6; u++) {
    var ui = COUNT - 30 - Math.floor(rnd() * 40);
    var ulat = (rnd() < 0.5 ? 1 : -1) * (6 + rnd() * 12);
    var ugy = groundY(ui, ulat);
    if (ugy < -0.5) continue;
    var up = pts[ui], ur = rights[ui];
    var umb = new THREE.Group();
    umb.add(new THREE.Mesh(umbPole, new THREE.MeshLambertMaterial({ color: 0xdddddd })));
    umb.add(new THREE.Mesh(umbGeo, new THREE.MeshLambertMaterial({ color: umbCols[u % 4] })));
    umb.position.set(up.x + ur.x * ulat, ugy, up.z + ur.z * ulat);
    umb.rotation.z = (rnd() - 0.5) * 0.3;
    scene.add(umb);
  }
})();

// ---------------- POTHOLES (merged into 2 draw calls) ----------------
var holes = [];
(function makePotholes() {
  var hv = [], hi_ = [], rv = [], ri_ = [];
  var hn = 0, rn2 = 0;
  var SEG = 12;

  function addHole(s, x, r) {
    var idx2 = sampleAt(s);
    var cx = _pos.x + _rgt.x * x, cy = _pos.y, cz = _pos.z + _rgt.z * x;
    var rot = rnd() * 6.28, sq = 0.75 + rnd() * 0.5;   // squashed ellipse
    var k, a, ca, sa2;
    // dark hole (slightly above road)
    hv.push(cx, cy + 0.045, cz);
    for (k = 0; k <= SEG; k++) {
      a = rot + k / SEG * Math.PI * 2;
      ca = Math.cos(a) * r; sa2 = Math.sin(a) * r * sq;
      var wob = 1 + 0.18 * Math.sin(a * 3 + rot * 7);
      hv.push(cx + (_rgt.x * ca + _tan.x * sa2) * wob, cy + 0.045,
              cz + (_rgt.z * ca + _tan.z * sa2) * wob);
    }
    for (k = 0; k < SEG; k++) hi_.push(hn, hn + 1 + k, hn + 2 + k);
    hn += SEG + 2;
    // cracked pale rim (just below the hole)
    for (k = 0; k <= SEG; k++) {
      a = rot + k / SEG * Math.PI * 2;
      ca = Math.cos(a); sa2 = Math.sin(a) * sq;
      var wob2 = 1 + 0.18 * Math.sin(a * 3 + rot * 7);
      rv.push(cx + (_rgt.x * ca * r + _tan.x * sa2 * r) * wob2, cy + 0.038,
              cz + (_rgt.z * ca * r + _tan.z * sa2 * r) * wob2);
      var r2 = r * 1.45;
      rv.push(cx + (_rgt.x * ca * r2 + _tan.x * sa2 * r2) * wob2, cy + 0.038,
              cz + (_rgt.z * ca * r2 + _tan.z * sa2 * r2) * wob2);
    }
    for (k = 0; k < SEG; k++) {
      var b = rn2 + k * 2;
      ri_.push(b, b + 1, b + 2, b + 1, b + 3, b + 2);
    }
    rn2 += (SEG + 1) * 2;
    holes.push({ s: s, x: x, r: r * sq + 0.15, passed: false, hit: false });
  }

  // clusters with a guaranteed (tight) gap
  var s = 230;
  while (s < TOTAL - 260) {
    var n = 1 + Math.floor(rnd() * 4);
    var gapC = (rnd() - 0.5) * 5.4;
    for (var k2 = 0; k2 < n; k2++) {
      var tries = 0, hx;
      do { hx = (rnd() - 0.5) * 7.4; tries++; }
      while (Math.abs(hx - gapC) < 2.2 && tries < 12);
      if (tries >= 12) continue;
      addHole(s + (rnd() - 0.5) * 12, hx, 0.55 + rnd() * 1.0);
    }
    s += 46 + rnd() * 72;
  }

  var hg = new THREE.BufferGeometry();
  hg.setAttribute('position', new THREE.Float32BufferAttribute(hv, 3));
  hg.setIndex(hi_);
  scene.add(new THREE.Mesh(hg, new THREE.MeshBasicMaterial({ color: 0x0b0b10 })));
  var rg = new THREE.BufferGeometry();
  rg.setAttribute('position', new THREE.Float32BufferAttribute(rv, 3));
  rg.setIndex(ri_);
  scene.add(new THREE.Mesh(rg, new THREE.MeshBasicMaterial({ color: 0x565b63 })));
})();

// ---------------- piraguas (nitro pickups) ----------------
var piraguas = [];
(function makePiraguas() {
  var cupGeo = new THREE.ConeGeometry(0.26, 0.4, 8);
  var cupMat = new THREE.MeshLambertMaterial({ color: 0xf5f0e6 });
  var iceGeo = new THREE.SphereGeometry(0.27, 10, 8, 0, Math.PI * 2, 0, Math.PI * 0.55);
  var flavors = [0xff2d4e, 0xff8a1a, 0x2d6bff, 0xffd23f, 0xc23bff];
  for (var i = 0; i < 24; i++) {
    var s = 150 + (i + rnd() * 0.6) * (TOTAL - 380) / 24;
    var x = (rnd() - 0.5) * 6.4;
    sampleAt(s);
    var grp = new THREE.Group();
    var cup = new THREE.Mesh(cupGeo, cupMat);
    cup.rotation.x = Math.PI;                          // cone tip down
    grp.add(cup);
    var ice = new THREE.Mesh(iceGeo,
      new THREE.MeshLambertMaterial({ color: flavors[i % flavors.length],
        emissive: flavors[i % flavors.length], emissiveIntensity: 0.35 }));
    ice.position.y = 0.16;
    grp.add(ice);
    grp.position.copy(_pos).add(_rgt.clone().multiplyScalar(x));
    grp.position.y += 1.0;
    scene.add(grp);
    piraguas.push({ s: s, x: x, mesh: grp, baseY: grp.position.y, taken: false });
  }
})();

// ---------------- toolboxes (el mecánico ambulante) ----------------
var toolboxes = [];
(function makeToolboxes() {
  var boxGeo = new THREE.BoxGeometry(0.52, 0.34, 0.38);
  var boxMat = new THREE.MeshLambertMaterial({ color: 0xd8352f, emissive: 0x481210 });
  var bandGeo = new THREE.BoxGeometry(0.54, 0.1, 0.4);
  var bandMat = new THREE.MeshLambertMaterial({ color: 0xf2f2f2 });
  for (var i = 0; i < 10; i++) {
    var s = 380 + (i + rnd() * 0.5) * (TOTAL - 700) / 10;
    var x = (rnd() - 0.5) * 6;
    sampleAt(s);
    var grp = new THREE.Group();
    grp.add(new THREE.Mesh(boxGeo, boxMat));
    grp.add(new THREE.Mesh(bandGeo, bandMat));
    grp.position.copy(_pos).add(_rgt.clone().multiplyScalar(x));
    grp.position.y += 0.9;
    scene.add(grp);
    toolboxes.push({ s: s, x: x, mesh: grp, baseY: grp.position.y, taken: false });
  }
})();

// ---------------- iguanas ----------------
var iguanas = [];
(function makeIguanas() {
  for (var i = 0; i < 12; i++) {
    var grp = new THREE.Group();
    var mat = new THREE.MeshLambertMaterial({ color: 0x5a8f3c });
    var body = new THREE.Mesh(new THREE.BoxGeometry(0.34, 0.22, 0.9), mat);
    body.position.y = 0.16; body.castShadow = true;
    grp.add(body);
    var head = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.16, 0.3), mat);
    head.position.set(0, 0.2, 0.55);
    grp.add(head);
    var tail = new THREE.Mesh(new THREE.ConeGeometry(0.1, 1.0, 5), mat);
    tail.rotation.x = Math.PI / 2; tail.position.set(0, 0.14, -0.9);
    grp.add(tail);
    var crest = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.1, 0.7),
      new THREE.MeshLambertMaterial({ color: 0x3f6b2a }));
    crest.position.y = 0.3;
    grp.add(crest);
    scene.add(grp);
    var s = 400 + i * (TOTAL - 700) / 12 + rnd() * 80;
    iguanas.push({ s: s, mesh: grp, state: 'wait', x: 0, dir: rnd() < 0.5 ? 1 : -1, hit: false });
  }
  iguanas.forEach(function (ig) {
    ig.x = -ig.dir * (ROAD_HALF + 1.5);
    sampleAt(ig.s);
    ig.mesh.position.copy(_pos).add(_rgt.clone().multiplyScalar(ig.x));
    ig.mesh.lookAt(ig.mesh.position.clone().add(
      new THREE.Vector3(_rgt.x * ig.dir, 0, _rgt.z * ig.dir)));
  });
})();

// ---------------- traffic (el tapón) ----------------
var traffic = [];
function makeTrafficCar(color) {
  var grp = new THREE.Group();
  var body = new THREE.Mesh(new THREE.BoxGeometry(1.7, 0.5, 3.6),
    new THREE.MeshPhongMaterial({ color: color, shininess: 60 }));
  body.position.y = 0.5; body.castShadow = true;
  grp.add(body);
  var cabin = new THREE.Mesh(new THREE.BoxGeometry(1.5, 0.45, 1.7),
    new THREE.MeshPhongMaterial({ color: 0x20242c, shininess: 90 }));
  cabin.position.set(0, 0.95, -0.2);
  grp.add(cabin);
  var wg = new THREE.CylinderGeometry(0.3, 0.3, 0.22, 10).rotateZ(Math.PI / 2);
  var wm = new THREE.MeshLambertMaterial({ color: 0x14161a });
  [[-0.8, 1.15], [0.8, 1.15], [-0.8, -1.15], [0.8, -1.15]].forEach(function (o) {
    var w = new THREE.Mesh(wg, wm);
    w.position.set(o[0], 0.3, o[1]);
    grp.add(w);
  });
  var tl = new THREE.Mesh(new THREE.BoxGeometry(1.5, 0.12, 0.06),
    new THREE.MeshBasicMaterial({ color: 0xff2222 }));
  tl.position.set(0, 0.62, -1.84);
  grp.add(tl);
  return grp;
}
(function makeTraffic() {
  var colors = [0xd8d8d8, 0x3f6bd8, 0xd8b23f, 0x8f8f98, 0x67c46a, 0xc44444, 0xefefef];
  for (var i = 0; i < 7; i++) {
    var mesh = makeTrafficCar(colors[i % colors.length]);
    scene.add(mesh);
    traffic.push({ s: 300 + i * 420 + rnd() * 150, x: (i % 2 ? 1.9 : -1.9),
      v: 11 + rnd() * 7, mesh: mesh, cool: 0, missed: false });
  }
})();

// ---------------- THE CAR ----------------
var player = new THREE.Group();
var chassis = new THREE.Group();       // roll / pitch / drift yaw
player.add(chassis);
var frontWheels = [], allWheels = [];
var carParts = {};

(function buildCar() {
  var paint = new THREE.MeshPhongMaterial({ color: 0xe02237, shininess: 90, specular: 0xffffff });
  var body = new THREE.Mesh(new THREE.BoxGeometry(1.8, 0.42, 4.0), paint);
  body.position.y = 0.5; body.castShadow = true;
  chassis.add(body);

  var hood = new THREE.Mesh(new THREE.BoxGeometry(1.7, 0.2, 1.2), paint);
  hood.position.set(0, 0.62, 1.35); hood.rotation.x = 0.1;
  chassis.add(hood);

  // white racing stripe
  var stripe = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.03, 4.02),
    new THREE.MeshLambertMaterial({ color: 0xf5f5f5 }));
  stripe.position.y = 0.72;
  chassis.add(stripe);

  var cabin = new THREE.Mesh(new THREE.BoxGeometry(1.55, 0.5, 1.8),
    new THREE.MeshPhongMaterial({ color: 0x181c26, shininess: 120, specular: 0xaaccff }));
  cabin.position.set(0, 0.96, -0.25); cabin.castShadow = true;
  chassis.add(cabin);

  // blue skirt — PR flag accent
  var skirt = new THREE.Mesh(new THREE.BoxGeometry(1.84, 0.12, 4.02),
    new THREE.MeshLambertMaterial({ color: 0x0050a0 }));
  skirt.position.y = 0.3;
  chassis.add(skirt);

  var spoiler = new THREE.Mesh(new THREE.BoxGeometry(1.6, 0.06, 0.4),
    new THREE.MeshLambertMaterial({ color: 0x181c26 }));
  spoiler.position.set(0, 0.95, -1.95);
  chassis.add(spoiler);
  [[-0.6, 0], [0.6, 0]].forEach(function (o) {
    var strut = new THREE.Mesh(new THREE.BoxGeometry(0.07, 0.28, 0.1),
      new THREE.MeshLambertMaterial({ color: 0x181c26 }));
    strut.position.set(o[0], 0.81, -1.92);
    chassis.add(strut);
  });

  var wg = new THREE.CylinderGeometry(0.34, 0.34, 0.26, 12).rotateZ(Math.PI / 2);
  var wm = new THREE.MeshPhongMaterial({ color: 0x14161a, shininess: 30 });
  var hubG = new THREE.CylinderGeometry(0.18, 0.18, 0.27, 8).rotateZ(Math.PI / 2);
  var hubM = new THREE.MeshPhongMaterial({ color: 0xd7b64a, shininess: 140 });
  [[-0.85, 1.28, true], [0.85, 1.28, true], [-0.85, -1.28, false], [0.85, -1.28, false]]
  .forEach(function (o) {
    var wgrp = new THREE.Group();
    var w = new THREE.Mesh(wg, wm);
    var hub = new THREE.Mesh(hubG, hubM);
    wgrp.add(w); wgrp.add(hub);
    wgrp.position.set(o[0], 0.34, o[1]);
    chassis.add(wgrp);
    allWheels.push({ grp: wgrp, tire: w, hub: hub });
    if (o[2]) frontWheels.push(wgrp);
  });

  // headlights + light cones (always on at golden hour)
  var hlM = new THREE.MeshBasicMaterial({ color: 0xfff3c4 });
  [[-0.6], [0.6]].forEach(function (o) {
    var hl = new THREE.Mesh(new THREE.BoxGeometry(0.32, 0.14, 0.06), hlM);
    hl.position.set(o[0], 0.58, 2.01);
    chassis.add(hl);
    var cone = new THREE.Mesh(
      new THREE.ConeGeometry(1.5, 11, 12, 1, true).rotateX(-Math.PI / 2).translate(0, 0, 5.5),
      new THREE.MeshBasicMaterial({ color: 0xffedb0, transparent: true, opacity: 0.09,
        blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }));
    cone.position.set(o[0], 0.55, 2.0);
    chassis.add(cone);
  });

  // brake lights
  var blM = new THREE.MeshBasicMaterial({ color: 0x550a0a });
  [[-0.62], [0.62]].forEach(function (o) {
    var bl = new THREE.Mesh(new THREE.BoxGeometry(0.4, 0.13, 0.06), blM);
    bl.position.set(o[0], 0.6, -2.01);
    chassis.add(bl);
  });
  carParts.brakeMat = blM;

  // nitro flames at the exhausts
  var flameG = new THREE.ConeGeometry(0.12, 1.0, 8).rotateX(Math.PI / 2);
  var flames = [];
  [[-0.45], [0.45]].forEach(function (o) {
    var fl = new THREE.Mesh(flameG,
      new THREE.MeshBasicMaterial({ color: 0x5ad7ff, transparent: true, opacity: 0.9,
        blending: THREE.AdditiveBlending, depthWrite: false }));
    fl.position.set(o[0], 0.36, -2.5);
    fl.visible = false;
    chassis.add(fl);
    flames.push(fl);
  });
  carParts.flames = flames;

  // neon underglow
  var glow = new THREE.Mesh(
    new THREE.PlaneGeometry(2.6, 4.6),
    new THREE.MeshBasicMaterial({ color: 0x12d7c3, transparent: true, opacity: 0.4,
      blending: THREE.AdditiveBlending, depthWrite: false }));
  glow.rotation.x = -Math.PI / 2;
  glow.position.y = 0.08;
  chassis.add(glow);
  carParts.glow = glow;
})();
scene.add(player);

var blob = new THREE.Mesh(
  new THREE.CircleGeometry(1.6, 18),
  new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.3, depthWrite: false }));
blob.rotation.x = -Math.PI / 2;
blob.scale.set(0.72, 1.25, 1);
scene.add(blob);

// ---------------- smoke / dust pool ----------------
var puffs = [];
(function makePuffs() {
  var geo = new THREE.CircleGeometry(0.5, 8);
  for (var i = 0; i < 22; i++) {
    var m = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({
      color: 0xcccccc, transparent: true, opacity: 0, depthWrite: false }));
    m.visible = false;
    scene.add(m);
    puffs.push({ mesh: m, life: 0, vel: new THREE.Vector3() });
  }
})();
var puffIdx = 0;
function spawnPuff(pos, vel, size, color) {
  var p = puffs[puffIdx++ % puffs.length];
  p.mesh.visible = true;
  p.mesh.position.copy(pos);
  p.mesh.scale.set(size, size, size);
  p.mesh.material.color.setHex(color);
  p.mesh.material.opacity = 0.55;
  p.vel.copy(vel);
  p.life = 0.7;
}
function updatePuffs(dt) {
  for (var i = 0; i < puffs.length; i++) {
    var p = puffs[i];
    if (p.life <= 0) continue;
    p.life -= dt;
    if (p.life <= 0) { p.mesh.visible = false; continue; }
    p.mesh.position.addScaledVector(p.vel, dt);
    p.mesh.scale.multiplyScalar(1 + dt * 2.4);
    p.mesh.material.opacity = p.life * 0.7;
    p.mesh.lookAt(camera.position);
  }
}

// ---------------- skid marks ----------------
var SKID_N = 160, skidIdx = 0;
var skidGeom, skidBirth = new Float32Array(SKID_N);
(function makeSkids() {
  var pos = new Float32Array(SKID_N * 4 * 3);
  var col = new Float32Array(SKID_N * 4 * 3);
  var idx = [];
  for (var i = 0; i < SKID_N; i++) {
    var a = i * 4;
    idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    skidBirth[i] = -1;
  }
  skidGeom = new THREE.BufferGeometry();
  skidGeom.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  skidGeom.setAttribute('color', new THREE.BufferAttribute(col, 3));
  skidGeom.setIndex(idx);
  var mesh = new THREE.Mesh(skidGeom, new THREE.MeshBasicMaterial({ vertexColors: true }));
  mesh.frustumCulled = false;
  scene.add(mesh);
})();

function dropSkid(cx, y, cz, dirX, dirZ) {
  var i = skidIdx++ % SKID_N;
  skidBirth[i] = performance.now() / 1000;
  var px = -dirZ * 0.09, pz = dirX * 0.09;      // half width, perpendicular
  var lx = dirX * 0.5, lz = dirZ * 0.5;         // half length, along travel
  var p = skidGeom.attributes.position.array, o = i * 12;
  p[o] = cx - lx + px; p[o + 1] = y; p[o + 2] = cz - lz + pz;
  p[o + 3] = cx - lx - px; p[o + 4] = y; p[o + 5] = cz - lz - pz;
  p[o + 6] = cx + lx + px; p[o + 7] = y; p[o + 8] = cz + lz + pz;
  p[o + 9] = cx + lx - px; p[o + 10] = y; p[o + 11] = cz + lz - pz;
  skidGeom.attributes.position.needsUpdate = true;
}

function updateSkids(t) {
  var col = skidGeom.attributes.color.array;
  var pos = skidGeom.attributes.position.array;
  var dirty = false;
  for (var i = 0; i < SKID_N; i++) {
    if (skidBirth[i] < 0) continue;
    dirty = true;
    var u = (t - skidBirth[i]) / 6;
    if (u >= 1) {
      skidBirth[i] = -1;
      var o = i * 12;
      for (var k = 0; k < 12; k++) pos[o + k] = 0;
      skidGeom.attributes.position.needsUpdate = true;
      continue;
    }
    // fade from near-black rubber back toward the asphalt tone
    var r = 0.07 + 0.13 * u, g = 0.08 + 0.14 * u, b = 0.09 + 0.15 * u;
    var o2 = i * 12;
    for (var k2 = 0; k2 < 4; k2++) {
      col[o2 + k2 * 3] = r; col[o2 + k2 * 3 + 1] = g; col[o2 + k2 * 3 + 2] = b;
    }
  }
  if (dirty) skidGeom.attributes.color.needsUpdate = true;
}

function clearSkids() {
  var pos = skidGeom.attributes.position.array;
  for (var i = 0; i < pos.length; i++) pos[i] = 0;
  for (var k = 0; k < SKID_N; k++) skidBirth[k] = -1;
  skidGeom.attributes.position.needsUpdate = true;
}

// speed streaks
var streaks;
(function makeStreaks() {
  var N = 260;
  var arr = new Float32Array(N * 3);
  for (var i = 0; i < N; i++) {
    arr[i * 3] = (rnd() - 0.5) * 30; arr[i * 3 + 1] = rnd() * 8; arr[i * 3 + 2] = -rnd() * 60;
  }
  var g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(arr, 3));
  streaks = new THREE.Points(g, new THREE.PointsMaterial({
    color: 0xfff2dd, size: 0.16, transparent: true, opacity: 0,
    blending: THREE.AdditiveBlending, depthWrite: false }));
  scene.add(streaks);
})();

// ---------------- audio ----------------
var AC = null, master = null, windGain = null, windFilter = null, slideGain = null, musicGain = null;
var engOsc1 = null, engOsc2 = null, engGain = null, engFilter = null, nitroGain = null;
var musicOn = true, musicNext = 0, musicBar = 0;

function noiseBuffer(ctx, secs) {
  var b = ctx.createBuffer(1, ctx.sampleRate * secs, ctx.sampleRate);
  var d = b.getChannelData(0);
  for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  return b;
}

function initAudio() {
  if (AC) return;
  try {
    AC = new (window.AudioContext || window.webkitAudioContext)();
    master = AC.createGain(); master.gain.value = 0.9; master.connect(AC.destination);

    var wsrc = AC.createBufferSource();
    wsrc.buffer = noiseBuffer(AC, 2); wsrc.loop = true;
    windFilter = AC.createBiquadFilter(); windFilter.type = 'lowpass'; windFilter.frequency.value = 220;
    windGain = AC.createGain(); windGain.gain.value = 0;
    wsrc.connect(windFilter); windFilter.connect(windGain); windGain.connect(master);
    wsrc.start();

    var ssrc = AC.createBufferSource();
    ssrc.buffer = noiseBuffer(AC, 1.4); ssrc.loop = true;
    var sfil = AC.createBiquadFilter(); sfil.type = 'bandpass'; sfil.frequency.value = 1100; sfil.Q.value = 1.4;
    slideGain = AC.createGain(); slideGain.gain.value = 0;
    ssrc.connect(sfil); sfil.connect(slideGain); slideGain.connect(master);
    ssrc.start();

    // engine: two detuned saws through a lowpass
    engOsc1 = AC.createOscillator(); engOsc1.type = 'sawtooth'; engOsc1.frequency.value = 55;
    engOsc2 = AC.createOscillator(); engOsc2.type = 'sawtooth'; engOsc2.frequency.value = 58;
    engFilter = AC.createBiquadFilter(); engFilter.type = 'lowpass'; engFilter.frequency.value = 700;
    engGain = AC.createGain(); engGain.gain.value = 0;
    engOsc1.connect(engFilter); engOsc2.connect(engFilter);
    engFilter.connect(engGain); engGain.connect(master);
    engOsc1.start(); engOsc2.start();

    // nitro whoosh
    var nsrc = AC.createBufferSource();
    nsrc.buffer = noiseBuffer(AC, 1.1); nsrc.loop = true;
    var nfil = AC.createBiquadFilter(); nfil.type = 'highpass'; nfil.frequency.value = 2600;
    nitroGain = AC.createGain(); nitroGain.gain.value = 0;
    nsrc.connect(nfil); nfil.connect(nitroGain); nitroGain.connect(master);
    nsrc.start();

    musicGain = AC.createGain(); musicGain.gain.value = 0.26; musicGain.connect(master);
    musicNext = AC.currentTime + 0.1;
    setInterval(scheduleMusic, 180);
    setTimeout(ambientCoqui, 2500);
  } catch (e) { AC = null; }
}

function playCoqui(vol) {
  if (!AC) return;
  var t = AC.currentTime + 0.02;
  var o1 = AC.createOscillator(), g1 = AC.createGain();
  o1.frequency.setValueAtTime(880, t); o1.frequency.exponentialRampToValueAtTime(1350, t + 0.1);
  g1.gain.setValueAtTime(0, t); g1.gain.linearRampToValueAtTime(vol, t + 0.02);
  g1.gain.exponentialRampToValueAtTime(0.001, t + 0.13);
  o1.connect(g1); g1.connect(master); o1.start(t); o1.stop(t + 0.15);
  var o2 = AC.createOscillator(), g2 = AC.createGain();
  var t2 = t + 0.17;
  o2.frequency.setValueAtTime(1400, t2); o2.frequency.exponentialRampToValueAtTime(2350, t2 + 0.16);
  g2.gain.setValueAtTime(0, t2); g2.gain.linearRampToValueAtTime(vol, t2 + 0.02);
  g2.gain.exponentialRampToValueAtTime(0.001, t2 + 0.2);
  o2.connect(g2); g2.connect(master); o2.start(t2); o2.stop(t2 + 0.24);
}

function ambientCoqui() {
  if (AC && state === 'playing') playCoqui(0.04 + Math.random() * 0.04);
  setTimeout(ambientCoqui, 2500 + Math.random() * 5000);
}

function thunkSound(hard) {
  if (!AC) return;
  var t = AC.currentTime;
  var src = AC.createBufferSource(); src.buffer = noiseBuffer(AC, 0.3);
  var f = AC.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = hard ? 420 : 300;
  var g = AC.createGain();
  g.gain.setValueAtTime(hard ? 0.65 : 0.4, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.26);
  src.connect(f); f.connect(g); g.connect(master); src.start(t);
  var o = AC.createOscillator(); o.frequency.setValueAtTime(hard ? 100 : 75, t);
  o.frequency.exponentialRampToValueAtTime(30, t + 0.18);
  var og = AC.createGain(); og.gain.setValueAtTime(hard ? 0.6 : 0.4, t);
  og.gain.exponentialRampToValueAtTime(0.001, t + 0.2);
  o.connect(og); og.connect(master); o.start(t); o.stop(t + 0.22);
}

function beep(freq, dur) {
  if (!AC) return;
  var t = AC.currentTime;
  var o = AC.createOscillator(); o.type = 'square'; o.frequency.value = freq;
  var g = AC.createGain();
  g.gain.setValueAtTime(0.11, t);
  g.gain.exponentialRampToValueAtTime(0.001, t + dur);
  o.connect(g); g.connect(master); o.start(t); o.stop(t + dur + 0.02);
}

function hornSound() {
  if (!AC) return;
  var t = AC.currentTime;
  [392, 494].forEach(function (fr) {
    var o = AC.createOscillator(); o.type = 'square'; o.frequency.value = fr;
    var g = AC.createGain();
    g.gain.setValueAtTime(0.07, t); g.gain.setValueAtTime(0.07, t + 0.18);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.24);
    o.connect(g); g.connect(master); o.start(t); o.stop(t + 0.26);
  });
}

// dembow, a little faster now
var BPM = 108, STEP_DUR = 60 / BPM / 4, BAR_DUR = STEP_DUR * 16;
var KICKS = [0, 4, 8, 12], SNARES = [3, 6, 11, 14], HATS = [2, 6, 10, 14];
var BASSLINE = [55, 55, 65.41, 49];

function drumKick(t) {
  var o = AC.createOscillator(), g = AC.createGain();
  o.frequency.setValueAtTime(135, t); o.frequency.exponentialRampToValueAtTime(42, t + 0.13);
  g.gain.setValueAtTime(0.9, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.18);
  o.connect(g); g.connect(musicGain); o.start(t); o.stop(t + 0.2);
}
function drumSnare(t) {
  var src = AC.createBufferSource(); src.buffer = noiseBuffer(AC, 0.12);
  var f = AC.createBiquadFilter(); f.type = 'bandpass'; f.frequency.value = 1900; f.Q.value = 0.8;
  var g = AC.createGain();
  g.gain.setValueAtTime(0.34, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.11);
  src.connect(f); f.connect(g); g.connect(musicGain); src.start(t);
  var o = AC.createOscillator(); o.type = 'triangle'; o.frequency.value = 210;
  var og = AC.createGain(); og.gain.setValueAtTime(0.16, t);
  og.gain.exponentialRampToValueAtTime(0.001, t + 0.08);
  o.connect(og); og.connect(musicGain); o.start(t); o.stop(t + 0.1);
}
function drumHat(t) {
  var src = AC.createBufferSource(); src.buffer = noiseBuffer(AC, 0.05);
  var f = AC.createBiquadFilter(); f.type = 'highpass'; f.frequency.value = 7500;
  var g = AC.createGain();
  g.gain.setValueAtTime(0.11, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.04);
  src.connect(f); f.connect(g); g.connect(musicGain); src.start(t);
}
function bassNote(t, freq) {
  var o = AC.createOscillator(); o.type = 'sawtooth'; o.frequency.value = freq;
  var f = AC.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 420;
  var g = AC.createGain();
  g.gain.setValueAtTime(0.0, t); g.gain.linearRampToValueAtTime(0.28, t + 0.015);
  g.gain.exponentialRampToValueAtTime(0.001, t + 0.3);
  o.connect(f); f.connect(g); g.connect(musicGain); o.start(t); o.stop(t + 0.32);
}
function scheduleMusic() {
  if (!AC || !musicOn) return;
  var ct = AC.currentTime;
  if (musicNext < ct - BAR_DUR) musicNext = ct + 0.05;
  while (musicNext < ct + 0.55) {
    var t0 = musicNext, k;
    for (k = 0; k < KICKS.length; k++) {
      drumKick(t0 + KICKS[k] * STEP_DUR);
      bassNote(t0 + KICKS[k] * STEP_DUR, BASSLINE[(musicBar + k) % 4]);
    }
    for (k = 0; k < SNARES.length; k++) drumSnare(t0 + SNARES[k] * STEP_DUR);
    for (k = 0; k < HATS.length; k++) drumHat(t0 + HATS[k] * STEP_DUR);
    musicBar++;
    musicNext += BAR_DUR;
  }
}

// ---------------- input ----------------
var keys = {};
var touchInput = { left: false, right: false, brake: false, nitro: false };

addEventListener('keydown', function (e) {
  if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', ' '].indexOf(e.key) >= 0) e.preventDefault();
  keys[e.key.toLowerCase()] = true;
  if (e.key === 'Enter' && state === 'intro') startGame();
  if ((e.key === 'r' || e.key === 'R') && state !== 'intro') resetGame();
  if (e.key === 'm' || e.key === 'M') toggleMusic();
  if (e.key === 'p' || e.key === 'P' || e.key === 'Escape') togglePause();
});
addEventListener('keyup', function (e) { keys[e.key.toLowerCase()] = false; });
addEventListener('blur', function () { if (state === 'playing' && !paused) togglePause(true); });

function bindBtn(id, prop) {
  var b = document.getElementById(id);
  function on(e) { e.preventDefault(); touchInput[prop] = true; b.classList.add('active'); }
  function off(e) { e.preventDefault(); touchInput[prop] = false; b.classList.remove('active'); }
  b.addEventListener('touchstart', on, { passive: false });
  b.addEventListener('touchend', off, { passive: false });
  b.addEventListener('touchcancel', off, { passive: false });
  b.addEventListener('mousedown', on);
  b.addEventListener('mouseup', off);
  b.addEventListener('mouseleave', off);
}
bindBtn('btnL', 'left'); bindBtn('btnR', 'right');
bindBtn('btnBrake', 'brake'); bindBtn('btnNitro', 'nitro');

document.addEventListener('touchmove', function (e) { e.preventDefault(); }, { passive: false });

// tap anywhere starts / restarts
['click', 'touchstart'].forEach(function (evName) {
  document.getElementById('intro').addEventListener(evName, function (e) {
    e.preventDefault(); if (state === 'intro') startGame();
  }, { passive: false });
  document.getElementById('finish').addEventListener(evName, function (e) {
    e.preventDefault(); if (state === 'finished') resetGame();
  }, { passive: false });
  document.getElementById('dead').addEventListener(evName, function (e) {
    e.preventDefault(); if (state === 'dead') resetGame();
  }, { passive: false });
});

function steerInput() {
  var st = 0;
  if (keys['arrowleft'] || keys['a'] || touchInput.left) st -= 1;
  if (keys['arrowright'] || keys['d'] || touchInput.right) st += 1;
  return st;
}

// small tap buttons (pause / music) — tap or click
function tapBtn(elm, fn) {
  elm.addEventListener('click', fn);
  elm.addEventListener('touchstart', function (e) { e.preventDefault(); fn(); }, { passive: false });
}

var paused = false;
function togglePause(force) {
  if (state !== 'playing') return;
  paused = force !== undefined ? force : !paused;
  el.pauseov.style.display = paused ? 'flex' : 'none';
  if (AC && paused) {
    engGain.gain.setTargetAtTime(0, AC.currentTime, 0.05);
    windGain.gain.setTargetAtTime(0, AC.currentTime, 0.05);
    slideGain.gain.setTargetAtTime(0, AC.currentTime, 0.05);
    nitroGain.gain.setTargetAtTime(0, AC.currentTime, 0.05);
  }
}

function toggleMusic() {
  musicOn = !musicOn;
  el.btnMusic.textContent = musicOn ? '🎵' : '🔇';
  showPopup(musicOn ? '♪ MÚSICA ON' : 'MÚSICA OFF');
}

// ---------------- records (localStorage) ----------------
function loadRec() {
  try { return JSON.parse(localStorage.getItem('hoyo_rec') || '{}'); }
  catch (e) { return {}; }
}
function saveRec(r) {
  try { localStorage.setItem('hoyo_rec', JSON.stringify(r)); } catch (e) {}
}
function fmtTime(t) {
  var mm = Math.floor(t / 60), ss = (t % 60).toFixed(1);
  return mm + ':' + (ss < 10 ? '0' : '') + ss;
}
function updateRecordLine() {
  var r = loadRec();
  var parts = [];
  if (r.bestScore) parts.push('RÉCORD ' + r.bestScore + ' pts');
  if (r.bestTime) parts.push('MEJOR TIEMPO ' + fmtTime(r.bestTime));
  el.recordline.textContent = parts.length ? '🏆 ' + parts.join(' · ') : '';
}

// ---------------- HUD ----------------
var el = {
  hud: document.getElementById('hud'),
  intro: document.getElementById('intro'),
  finish: document.getElementById('finish'),
  dead: document.getElementById('dead'),
  finalstats: document.getElementById('finalstats'),
  deadstats: document.getElementById('deadstats'),
  speed: document.getElementById('speed'),
  score: document.getElementById('score'),
  timer: document.getElementById('timer'),
  progress: document.getElementById('progress'),
  hpbar: document.getElementById('hpbar'),
  nitrobar: document.getElementById('nitrobar'),
  vignette: document.getElementById('vignette'),
  flash: document.getElementById('flash'),
  popup: document.getElementById('popup'),
  hint: document.getElementById('hint'),
  combo: document.getElementById('combo'),
  count: document.getElementById('count'),
  pauseov: document.getElementById('pauseov'),
  recordline: document.getElementById('recordline'),
  btnPause: document.getElementById('btnPause'),
  btnMusic: document.getElementById('btnMusic')
};

tapBtn(el.btnPause, function () { togglePause(); });
tapBtn(el.btnMusic, toggleMusic);
tapBtn(el.pauseov, function () { togglePause(false); });
updateRecordLine();

var popupTimer = null;
function showPopup(text) {
  el.popup.textContent = text;
  el.popup.classList.remove('show');
  void el.popup.offsetWidth;
  el.popup.classList.add('show');
  if (popupTimer) clearTimeout(popupTimer);
  popupTimer = setTimeout(function () { el.popup.classList.remove('show'); }, 1200);
}

// ---------------- game state ----------------
var state = 'intro';
var S = {};

function resetGame(skipCountdown) {
  S.s = 4; S.v = 8; S.x = 0; S.xd = 0;
  S.hp = 100; S.nitro = 60;
  S.score = 0; S.styleRun = 0; S.combo = 0;
  S.topSpeed = 0; S.holesHit = 0; S.nearMisses = 0;
  S.shake = 0; S.flashT = 0; S.jolt = 0;
  S.driftYaw = 0; S.leanRoll = 0; S.pitch = 0;
  S.smokeT = 0; S.time = 0;
  S.cd = 3.4; S.cdShown = null;
  holes.forEach(function (h) { h.passed = false; h.hit = false; });
  piraguas.forEach(function (q) { q.taken = false; q.mesh.visible = true; });
  toolboxes.forEach(function (tb) { tb.taken = false; tb.mesh.visible = true; });
  iguanas.forEach(function (ig, i) {
    ig.state = 'wait'; ig.hit = false;
    ig.x = -ig.dir * (ROAD_HALF + 1.5);
    ig.mesh.rotation.z = 0;
  });
  traffic.forEach(function (t, i) {
    t.s = 300 + i * 420 + rnd() * 150; t.cool = 0; t.missed = false;
  });
  clearSkids();
  paused = false;
  el.pauseov.style.display = 'none';
  state = skipCountdown ? 'playing' : 'countdown';
  el.finish.style.display = 'none';
  el.dead.style.display = 'none';
  el.intro.style.display = 'none';
  el.hud.style.display = 'block';
  el.combo.style.visibility = 'hidden';
  snapCamera();
}

function startGame() {
  initAudio();
  if (AC && AC.state === 'suspended') AC.resume();
  if (IS_TOUCH) {
    try { document.documentElement.requestFullscreen(); } catch (e) {}
    try { screen.orientation.lock('landscape').catch(function () {}); } catch (e) {}
  }
  resetGame();
  setTimeout(function () { el.hint.style.opacity = 0; }, 9000);
}

function statsHTML(extra) {
  return (extra || '') +
    'TIEMPO &nbsp;<b>' + fmtTime(S.time) + '</b><br>' +
    'PUNTOS &nbsp;<b>' + Math.floor(S.score) + '</b><br>' +
    'VELOCIDAD MÁXIMA &nbsp;<b>' + Math.round(S.topSpeed * 3.6) + ' km/h</b><br>' +
    'HOYOS COMÍOS &nbsp;<b>' + S.holesHit + '</b> &nbsp;·&nbsp; ESQUIVES &nbsp;<b>' + S.nearMisses + '</b>';
}

function finishGame() {
  state = 'finished';
  var r = loadRec(), extra = '';
  if (!r.bestScore || Math.floor(S.score) > r.bestScore) {
    r.bestScore = Math.floor(S.score);
    extra = '<span class="newrec">★ ¡NUEVO RÉCORD DE PUNTOS! ★</span><br>';
  }
  if (!r.bestTime || S.time < r.bestTime) {
    r.bestTime = Math.round(S.time * 10) / 10;
    extra += '<span class="newrec">★ ¡MEJOR TIEMPO! ★</span><br>';
  }
  saveRec(r);
  updateRecordLine();
  el.finalstats.innerHTML = statsHTML(extra);
  el.finish.style.display = 'flex';
  el.hud.style.display = 'none';
  playCoqui(0.2);
}

function dieGame() {
  state = 'dead';
  var r = loadRec(), extra = '';
  if (!r.bestScore || Math.floor(S.score) > r.bestScore) {
    r.bestScore = Math.floor(S.score);
    extra = '<span class="newrec">★ ¡NUEVO RÉCORD DE PUNTOS! ★</span><br>';
    saveRec(r);
    updateRecordLine();
  }
  el.deadstats.innerHTML = statsHTML(extra);
  el.dead.style.display = 'flex';
  el.hud.style.display = 'none';
  thunkSound(true);
}

function damage(amount, msg) {
  S.hp -= amount;
  S.flashT = 1;
  S.combo = 0;
  el.combo.style.visibility = 'hidden';
  if (msg) showPopup(msg);
  if (S.hp <= 0) { S.hp = 0; dieGame(); }
}

// ---------------- camera ----------------
var camPos = new THREE.Vector3(), camLook = new THREE.Vector3();
function snapCamera() {
  sampleAt(S.s);
  camPos.copy(_pos).addScaledVector(_tan, -7).add(new THREE.Vector3(0, 2.6, 0));
  camLook.copy(_pos).addScaledVector(_tan, 8);
  camera.position.copy(camPos);
  camera.lookAt(camLook);
}

// ---------------- main loop ----------------
var lastT = performance.now();
var G = 9.81;
var tmp = new THREE.Vector3(), tmp2 = new THREE.Vector3(), tmp3 = new THREE.Vector3();

function tick() {
  requestAnimationFrame(tick);
  var now = performance.now();
  var dt = Math.min((now - lastT) / 1000, 0.033);
  lastT = now;
  var t = now / 1000;

  if (paused) { renderer.render(scene, camera); return; }

  waterUniforms.time.value = t;

  if (state === 'countdown') {
    S.cd -= dt;
    var lbl = S.cd > 2.4 ? '3' : S.cd > 1.4 ? '2' : S.cd > 0.4 ? '1' : '¡DALE!';
    if (lbl !== S.cdShown) {
      S.cdShown = lbl;
      el.count.textContent = lbl;
      el.count.style.display = 'block';
      el.count.classList.remove('zoom');
      void el.count.offsetWidth;
      el.count.classList.add('zoom');
      beep(lbl === '¡DALE!' ? 1420 : 850, lbl === '¡DALE!' ? 0.28 : 0.11);
    }
    if (S.cd <= -0.4) {
      state = 'playing';
      el.count.style.display = 'none';
    }
  }

  if (state === 'playing') {
    S.time += dt;

    // ----- driving physics -----
    var i = Math.floor(clamp(S.s / STEP, 0, COUNT - 2));
    var grade = grades[i];
    var curv = curvs[i];
    var braking = keys['arrowdown'] || keys['s'] || touchInput.brake;
    var wantNitro = (keys['arrowup'] || keys['w'] || touchInput.nitro) && S.nitro > 0;
    var steer = steerInput();
    var drifting = ((keys[' '] || keys['spacebar']) || (braking && steer !== 0)) && S.v > 12;
    var offroad = Math.abs(S.x) > ROAD_HALF + 0.3;

    var acc = 9.0 - grade * G * 4;          // engine + downhill
    acc -= 0.0042 * S.v * S.v;              // aero
    if (wantNitro) {
      acc += 14;
      S.nitro = Math.max(0, S.nitro - 26 * dt);
    } else {
      S.nitro = Math.min(100, S.nitro + 3.5 * dt);
    }
    if (braking && !drifting) acc -= 15;
    if (drifting) acc -= 5;
    if (offroad) acc -= 9;
    S.v = clamp(S.v + acc * dt, 0, wantNitro ? 64 : 50);
    S.topSpeed = Math.max(S.topSpeed, S.v);
    S.s += S.v * dt;

    carParts.brakeMat.color.setHex(braking ? 0xff2222 : 0x550a0a);
    carParts.flames.forEach(function (fl) {
      fl.visible = wantNitro;
      if (wantNitro) fl.scale.set(1, 1, 0.7 + Math.random() * 0.9);
    });

    // lateral: grip vs. centrifugal
    var targetXd = steer * clamp(4 + S.v * 0.30, 0, 16) * (drifting ? 1.35 : 1);
    var grip = drifting ? 3.2 : 6.5;
    S.xd += (targetXd - S.xd) * Math.min(1, grip * dt);
    S.xd += -curv * S.v * S.v * dt * (drifting ? 0.45 : 0.35);
    S.x += S.xd * dt;
    S.x = clamp(S.x, -10, 10);

    // drift style
    if (drifting) {
      S.styleRun += S.v * dt * 4;
      S.smokeT -= dt;
      if (S.smokeT <= 0) {
        S.smokeT = 0.05;
        sampleAt(S.s);
        tmp3.copy(_pos).addScaledVector(_rgt, S.x).addScaledVector(_tan, -1.6);
        tmp3.y += 0.3;
        spawnPuff(tmp3, tmp2.set(-_tan.x * 3 + (Math.random() - 0.5) * 2, 1.5,
          -_tan.z * 3 + (Math.random() - 0.5) * 2), 0.5, 0xd8d8d8);
        // rubber on the road, one mark per rear wheel
        var ca = Math.cos(S.driftYaw), sa = Math.sin(S.driftYaw);
        var dirX = _tan.x * ca + _tan.z * sa;
        var dirZ = -_tan.x * sa + _tan.z * ca;
        var rearX = _pos.x + _rgt.x * S.x - dirX * 1.28;
        var rearZ = _pos.z + _rgt.z * S.x - dirZ * 1.28;
        var wpx = -dirZ * 0.85, wpz = dirX * 0.85;
        dropSkid(rearX + wpx, _pos.y + 0.042, rearZ + wpz, dirX, dirZ);
        dropSkid(rearX - wpx, _pos.y + 0.042, rearZ - wpz, dirX, dirZ);
      }
    } else if (S.styleRun > 0) {
      if (S.styleRun > 50) showPopup('¡WEPA! +' + Math.floor(S.styleRun));
      S.score += S.styleRun;
      S.styleRun = 0;
    }
    S.score += S.v * dt * 1.2;

    // ----- hazards -----
    if (Math.abs(S.x) > 8.6 && S.v > 4) {
      thunkSound(true);
      S.shake = 1;
      S.v *= 0.3;
      S.x = clamp(S.x, -3, 3) * 0.3; S.xd = 0;
      damage(22, '¡AY BENDITO!');
    } else if (offroad && S.v > 8) {
      S.shake = Math.max(S.shake, 0.25);
      if (Math.random() < dt * 2.2) damage(3, null);
    }

    // potholes
    for (var hIdx = 0; hIdx < holes.length; hIdx++) {
      var h = holes[hIdx];
      var ds = h.s - S.s;
      if (ds < -6 || ds > 6) continue;
      if (!h.hit && Math.abs(ds) < 1.8 && Math.abs(h.x - S.x) < h.r + 0.75) {
        h.hit = true;
        S.holesHit++;
        S.v *= 0.62;
        S.shake = 1.1; S.jolt = 1;
        thunkSound(true);
        damage(9 + h.r * 9 + S.v * 0.18, '¡HOYO!');
        sampleAt(S.s);
        tmp3.copy(_pos).addScaledVector(_rgt, S.x); tmp3.y += 0.3;
        for (var d2 = 0; d2 < 5; d2++) {
          spawnPuff(tmp3, tmp2.set((Math.random() - 0.5) * 5, 2 + Math.random() * 3,
            (Math.random() - 0.5) * 5), 0.4, 0x8a7a5c);
        }
      } else if (!h.passed && !h.hit && ds < -2) {
        h.passed = true;
        if (Math.abs(h.x - S.x) < h.r + 2.2) {
          S.nearMisses++;
          S.combo = Math.min(S.combo + 1, 5);
          var bonus = 40 * S.combo;
          S.score += bonus;
          if (S.combo >= 2) {
            el.combo.textContent = 'COMBO x' + S.combo + ' 🔥';
            el.combo.style.visibility = 'visible';
            showPopup('¡CASI! x' + S.combo + ' +' + bonus);
          } else if (S.nearMisses % 3 === 0) {
            showPopup('¡CASI! +40');
          }
        }
      }
    }

    // toolboxes — el mecánico repairs on the fly
    for (var tbi = 0; tbi < toolboxes.length; tbi++) {
      var tb = toolboxes[tbi];
      if (!tb.taken && Math.abs(tb.s - S.s) < 2.4 && Math.abs(tb.x - S.x) < 1.6) {
        tb.taken = true; tb.mesh.visible = false;
        S.hp = Math.min(100, S.hp + 22);
        S.score += 50;
        playCoqui(0.16);
        showPopup('¡MECÁNICO! +VIDA');
      }
    }

    // piraguas
    for (var qi = 0; qi < piraguas.length; qi++) {
      var q = piraguas[qi];
      if (!q.taken && Math.abs(q.s - S.s) < 2.4 && Math.abs(q.x - S.x) < 1.6) {
        q.taken = true; q.mesh.visible = false;
        S.nitro = Math.min(100, S.nitro + 35);
        S.score += 100;
        playCoqui(0.2);
        showPopup('¡PIRAGUA! +NITRO');
      }
    }

    // iguanas
    for (var gi2 = 0; gi2 < iguanas.length; gi2++) {
      var ig = iguanas[gi2];
      var igDs = ig.s - S.s;
      if (ig.state === 'wait' && igDs > 0 && igDs < 40 + S.v * 2.2) ig.state = 'run';
      if (ig.state === 'run') {
        ig.x += ig.dir * 7.5 * dt;
        if (Math.abs(ig.x) > ROAD_HALF + 1.5 && ig.x * ig.dir > 0) ig.state = 'done';
        ig.mesh.position.y += Math.abs(Math.sin(t * 22)) * 0.05;
      }
      if (!ig.hit && ig.state === 'run' && Math.abs(igDs) < 2 && Math.abs(ig.x - S.x) < 1.2) {
        ig.hit = true; ig.state = 'done';
        ig.mesh.rotation.z = 2.6;                    // comic flip, lands fine
        S.shake = Math.max(S.shake, 0.6);
        thunkSound(false);
        damage(8, '¡LA IGUANA!');
      }
      if (ig.state !== 'wait') {
        sampleAt(ig.s);
        ig.mesh.position.x = _pos.x + _rgt.x * ig.x;
        ig.mesh.position.z = _pos.z + _rgt.z * ig.x;
        ig.mesh.position.y = _pos.y + 0.05;
        tmp2.set(_rgt.x * ig.dir, 0, _rgt.z * ig.dir);
        ig.mesh.lookAt(ig.mesh.position.clone().add(tmp2));
      }
    }

    // traffic
    for (var ti = 0; ti < traffic.length; ti++) {
      var tc = traffic[ti];
      tc.cool = Math.max(0, tc.cool - dt);
      tc.s += tc.v * dt;
      if (tc.s > S.s + 600 || tc.s < S.s - 120 || tc.s > TOTAL - 40) {
        tc.s = S.s + 260 + rnd() * 320;
        tc.x = (rnd() < 0.5 ? 1.9 : -1.9);
        tc.v = 11 + rnd() * 7;
        tc.missed = false; tc.cool = 0;
        if (tc.s > TOTAL - 60) tc.s = TOTAL * 2;      // past the finish, park it out of sight
      }
      var tDs = tc.s - S.s;
      if (tc.cool <= 0 && Math.abs(tDs) < 3.2 && Math.abs(tc.x - S.x) < 1.7) {
        tc.cool = 2;
        S.v = Math.min(S.v, tc.v * 0.8);
        S.shake = 1.2; S.jolt = 1;
        thunkSound(true);
        hornSound();
        damage(30, '¡EL TAPÓN!');
      } else if (!tc.missed && tDs < -1 && tDs > -8 && Math.abs(tc.x - S.x) < 3 &&
                 Math.abs(tc.x - S.x) > 1.7 && S.v - tc.v > 12) {
        tc.missed = true;
        S.combo = Math.min(S.combo + 1, 5);
        S.score += 80 * S.combo;
        if (S.combo >= 2) {
          el.combo.textContent = 'COMBO x' + S.combo + ' 🔥';
          el.combo.style.visibility = 'visible';
        }
        hornSound();
        showPopup('¡FUA! +' + 80 * S.combo);
      }
      if (tDs > -150 && tDs < 700) {
        sampleAt(tc.s);
        tc.mesh.visible = true;
        tc.mesh.position.copy(_pos).addScaledVector(_rgt, tc.x);
        tmp2.copy(tc.mesh.position).add(_tan);
        tc.mesh.lookAt(tmp2);
      } else tc.mesh.visible = false;
    }

    if (S.s >= TOTAL - 8) finishGame();

    // ----- place the car -----
    sampleAt(S.s);
    tmp.copy(_pos).addScaledVector(_rgt, S.x);
    player.position.copy(tmp);
    player.position.y += 0.02;
    tmp2.copy(tmp).add(_tan);
    player.lookAt(tmp2);

    // body attitude: roll into turns, pitch on gas/brake, drift yaw, pothole jolt
    var targetRoll = -steer * 0.09 - S.xd * 0.012;
    S.leanRoll += (targetRoll - S.leanRoll) * Math.min(1, 8 * dt);
    var targetYaw = -S.xd * 0.03 - (drifting ? steer * 0.5 : 0);
    S.driftYaw += (targetYaw - S.driftYaw) * Math.min(1, 6 * dt);
    var targetPitch = braking ? 0.05 : (wantNitro ? -0.035 : 0);
    S.pitch += (targetPitch - S.pitch) * Math.min(1, 6 * dt);
    if (S.jolt > 0) S.jolt = Math.max(0, S.jolt - dt * 4);
    chassis.rotation.set(S.pitch + S.jolt * 0.08 * Math.sin(t * 60),
      S.driftYaw, S.leanRoll);
    chassis.position.y = -S.jolt * 0.12 * Math.abs(Math.sin(t * 42));

    var spin = S.v * dt / 0.34;
    allWheels.forEach(function (w) { w.tire.rotation.x += spin; w.hub.rotation.x += spin; });
    frontWheels.forEach(function (w) { w.rotation.y = steer * 0.35; });
    carParts.glow.material.opacity = 0.3 + 0.18 * Math.sin(t * 9);

    blob.position.set(tmp.x, _pos.y + 0.03, tmp.z);
    blob.rotation.z = Math.atan2(_tan.x, -_tan.z);

    // shadow light follows the car
    sun.position.set(tmp.x + 45, tmp.y + 60, tmp.z - 75);
    sun.target.position.copy(tmp);

    // ----- camera -----
    var camDist = 6.4 + S.v * 0.055;
    tmp2.copy(tmp).addScaledVector(_tan, -camDist);
    tmp2.y += 2.2 + S.v * 0.012;
    tmp2.addScaledVector(_rgt, S.x * 0.1);
    var k = 1 - Math.exp(-dt * 5.5);
    camPos.lerp(tmp2, k);
    tmp2.copy(tmp).addScaledVector(_tan, 10);
    tmp2.y += 1.0;
    camLook.lerp(tmp2, k);
    var rumble = S.v > 40 ? (S.v - 40) * 0.004 : 0;
    if (S.shake > 0.01) {
      camPos.x += (Math.random() - 0.5) * S.shake * 0.55;
      camPos.y += (Math.random() - 0.5) * S.shake * 0.45;
      S.shake *= Math.exp(-dt * 4);
    }
    camera.position.copy(camPos);
    camera.position.x += (Math.random() - 0.5) * rumble;
    camera.position.y += (Math.random() - 0.5) * rumble;
    camera.lookAt(camLook);
    var targetFov = 72 + S.v * 0.6 + (keys['arrowup'] || keys['w'] || touchInput.nitro ? 4 : 0);
    camera.fov += (clamp(targetFov, 72, 116) - camera.fov) * Math.min(1, 4.5 * dt);
    camera.updateProjectionMatrix();

    // streaks
    var sp = streaks.geometry.attributes.position;
    for (var pi2 = 0; pi2 < sp.count; pi2++) {
      tmp2.set(sp.getX(pi2), sp.getY(pi2), sp.getZ(pi2));
      if (tmp2.distanceToSquared(tmp) > 3600 || tmp2.clone().sub(tmp).dot(_tan) < -8) {
        var ahead = 15 + Math.random() * 45;
        sp.setXYZ(pi2,
          tmp.x + _tan.x * ahead + _rgt.x * (Math.random() - 0.5) * 12,
          tmp.y + Math.random() * 3.5,
          tmp.z + _tan.z * ahead + _rgt.z * (Math.random() - 0.5) * 12);
      }
    }
    sp.needsUpdate = true;
    streaks.material.opacity = clamp((S.v - 22) / 32, 0, 0.6);

    // ----- audio follows the car -----
    if (AC) {
      var rpm = 55 + S.v * 3.2 + (wantNitro ? 30 : 0);
      engOsc1.frequency.setTargetAtTime(rpm, AC.currentTime, 0.05);
      engOsc2.frequency.setTargetAtTime(rpm * 1.007 + 3, AC.currentTime, 0.05);
      engFilter.frequency.setTargetAtTime(500 + S.v * 22, AC.currentTime, 0.1);
      engGain.gain.setTargetAtTime(0.05 + clamp(S.v / 64, 0, 1) * 0.075, AC.currentTime, 0.1);
      windGain.gain.setTargetAtTime(clamp(S.v / 90, 0, 0.35), AC.currentTime, 0.1);
      windFilter.frequency.setTargetAtTime(180 + S.v * 34, AC.currentTime, 0.1);
      slideGain.gain.setTargetAtTime(drifting ? clamp(S.v / 140, 0, 0.22) : 0, AC.currentTime, 0.05);
      nitroGain.gain.setTargetAtTime(wantNitro ? 0.12 : 0, AC.currentTime, 0.08);
    }

    // ----- HUD -----
    el.speed.textContent = Math.round(S.v * 3.6);
    el.speed.style.color = wantNitro ? '#6ef7ff' : (S.v > 42 ? '#ffd23f' : '#ffffff');
    el.score.textContent = Math.floor(S.score);
    var mm = Math.floor(S.time / 60), ss = (S.time % 60).toFixed(1);
    el.timer.textContent = mm + ':' + (ss < 10 ? '0' : '') + ss;
    el.progress.style.width = (S.s / TOTAL * 100).toFixed(1) + '%';
    el.hpbar.style.width = S.hp + '%';
    el.hpbar.style.background = S.hp > 50 ?
      'linear-gradient(90deg,#3dff8a,#b8ff3d)' :
      (S.hp > 25 ? 'linear-gradient(90deg,#ffd23f,#ff8a5c)' : 'linear-gradient(90deg,#ff3b3b,#ff2d78)');
    el.nitrobar.style.width = S.nitro + '%';
    el.vignette.style.opacity = clamp((S.v - 20) / 30, 0, 0.92);
    if (S.flashT > 0) {
      S.flashT -= dt * 2.2;
      el.flash.style.opacity = Math.max(0, S.flashT) * 0.8;
    } else el.flash.style.opacity = 0;
  }

  updatePuffs(dt);
  updateSkids(t);

  var tt = t * 3;
  for (var qa = 0; qa < piraguas.length; qa++) {
    var qq = piraguas[qa];
    if (!qq.taken) {
      qq.mesh.position.y = qq.baseY + Math.sin(tt + qa) * 0.16;
      qq.mesh.rotation.y += dt * 2.4;
    }
  }
  for (var tba = 0; tba < toolboxes.length; tba++) {
    var tbb = toolboxes[tba];
    if (!tbb.taken) {
      tbb.mesh.position.y = tbb.baseY + Math.sin(tt + tba * 2) * 0.14;
      tbb.mesh.rotation.y += dt * 1.8;
    }
  }

  if (state === 'intro') {
    var fs = (t * 22) % (TOTAL * 0.6);
    sampleAt(fs + 100);
    tmp.copy(_pos).addScaledVector(_rgt, -14).add(new THREE.Vector3(0, 11, 0));
    camera.position.lerp(tmp, 0.03);
    sampleAt(fs + 160);
    camera.lookAt(_pos);
    sun.position.set(camera.position.x + 45, camera.position.y + 60, camera.position.z - 75);
    sun.target.position.copy(_pos);
  }

  renderer.render(scene, camera);
}

// smoke-test mode: ?autoplay drops you mid-run at speed
if (location.search.indexOf('autoplay') >= 0) {
  resetGame(true);
  S.s = 460; S.v = 44;
  snapCamera();
}

tick();
})();
