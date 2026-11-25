// The Window panel, drawn with plain DOM. Numbers come from the app's own
// example evening (TarasPanelFixtures): leave 17:10 to 17:40, home by 18:15,
// 10 minutes to wrap up, now 16:58. The ruler matches TarasRulerModel:
// 6 points per minute, cursor at x = 180, ticks every minute, major every 15.
(function () {
  var E = 1030, NOW = 1018, HB = 1095, PACK = 10, BUF = 10, SUG = 4;
  var S = [[1030, 41], [1035, 40], [1040, 37], [1045, 33], [1050, 31], [1055, 30], [1060, 30]];
  var L = S[S.length - 1][0], PX = 6, LO = 41, HI = 30;

  function fmt(m) { m = ((m % 1440) + 1440) % 1440; return pad(Math.floor(m / 60)) + ':' + pad(m % 60); }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function sgn(n) { return (n > 0 ? '+' : n < 0 ? '-' : '') + Math.abs(n) + 'M'; }
  function el(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }

  var ICON = {
    hour: '<svg width="9" height="11" viewBox="0 0 9 11" fill="none" stroke="#8E8E93" stroke-width="1.2" stroke-linejoin="round"><path d="M1 .8h7M1 10.2h7M2 .8c0 3 5 3.2 5 4.7S2 7.2 2 10.2M7 .8c0 3-5 3.2-5 4.7s5 1.7 5 4.7"/></svg>',
    ring: '<svg width="8" height="8" viewBox="0 0 8 8"><circle cx="4" cy="4" r="3.2" fill="none" stroke="#F5692B" stroke-width="1.3"/></svg>',
    down: '<svg width="9" height="10" viewBox="0 0 9 10"><path d="M4.5 1v8M1.3 5.8l3.2 3.2 3.2-3.2" fill="none" stroke="#30D158" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    flat: '<svg width="9" height="9" viewBox="0 0 9 9"><path d="M1 4.5h7" stroke="#8E8E93" stroke-width="1.4" stroke-linecap="round"/></svg>',
    check: '<svg width="10" height="9" viewBox="0 0 10 9"><path d="M1 4.8l2.8 2.8L9 1.4" fill="none" stroke="#8E8E93" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    warn: '<svg width="10" height="9" viewBox="0 0 10 9"><path d="M5 .9L9.3 8.3H.7z" fill="none" stroke="#FFD60A" stroke-width="1.2" stroke-linejoin="round"/><path d="M5 3.6v2" stroke="#FFD60A" stroke-width="1.2" stroke-linecap="round"/></svg>',
    gear: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor"><circle cx="9" cy="9" r="2.4" stroke-width="1.4"/><circle cx="9" cy="9" r="5.6" stroke-width="1.4"/>' +
      [0, 45, 90, 135, 180, 225, 270, 315].map(function (a) { return '<path d="M9 1.6v2" stroke-width="2.4" transform="rotate(' + a + ' 9 9)"/>'; }).join('') + '</svg>',
    scope: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="9" cy="9" r="5.6"/><circle cx="9" cy="9" r="1.2" fill="currentColor" stroke="none"/><path d="M9 .9v3M9 14.1v3M.9 9h3M14.1 9h3"/></svg>'
  };

  function rowsFor(i) {
    var d = S[i][0], drive = S[i][1], first = S[0];
    var arrive = d + drive, firstArrive = first[0] + first[1];
    var spare = HB - arrive, less = first[1] - drive, atFirst = d === E;
    return [
      { label: atFirst ? 'EARLIEST' : sgn(d - E) + ' VS ' + fmt(E), status: 'WAIT ' + (d - NOW) + 'M', icon: 'hour', name: 'Leave', value: fmt(d) },
      { label: '-' + PACK + 'M · WRAP-UP TIME', status: 'IN ' + (d - PACK - NOW) + 'M', icon: 'ring', name: 'Wrap up', value: fmt(d - PACK) },
      { label: (atFirst ? '' : sgn(drive - first[1]) + ' VS ' + fmt(E) + ' · ') + 'APPLE MAPS', status: less >= 8 ? 'LESS DRIVING' : less > 0 ? less + 'M LESS' : 'MOST DRIVING', icon: less >= 8 ? 'down' : 'flat', name: 'Drive', value: drive + ' min' },
      { label: (atFirst ? '' : sgn(arrive - firstArrive) + ' VS ' + fmt(E) + ' · ') + 'BY ' + fmt(HB), status: spare + 'M SPARE', icon: spare >= BUF ? 'check' : 'warn', name: 'Home around', value: fmt(arrive) }
    ];
  }

  function summary(i) {
    var d = S[i][0], drive = S[i][1];
    return 'Leave at ' + fmt(d) + ', ' + drive + ' minute drive, home around ' + fmt(d + drive) +
      (i === SUG ? '. This is the suggested time.' : '.');
  }

  window.mountWindowPanel = function (root, opts) {
    opts = opts || {};
    var index = typeof opts.index === 'number' ? opts.index : SUG;
    var interactive = opts.interactive !== false;
    root.classList.add('wp');
    root.setAttribute('role', 'group');
    root.setAttribute('aria-label', 'Window panel, example evening');

    var top = el('div', 'wp-top');
    var track = el('div', 'wp-track');
    track.setAttribute('aria-hidden', 'true');
    var band = el('div', 'wp-band');
    track.appendChild(band);
    for (var t = E - 40; t <= L + 40; t++) {
      var major = t % 15 === 0;
      var tick = el('div', 'wp-tick' + (major ? ' wp-major' : '') + (t < E || t > L ? ' wp-out' : ''));
      tick.style.left = ((t - E) * PX) + 'px';
      track.appendChild(tick);
    }
    var barEls = S.map(function (s) {
      var b = el('span', 'wp-bar');
      b.style.left = ((s[0] - E) * PX) + 'px';
      b.style.height = Math.round(20 + 30 * (s[1] - HI) / (LO - HI)) + 'px';
      if (s[0] + s[1] + BUF > HB) b.classList.add('wp-dim');
      track.appendChild(b);
      return b;
    });
    top.appendChild(track);

    // Hit targets sit outside the moving track so focus order stays stable.
    var hits = el('div', 'wp-hits');
    var hitEls = S.map(function (s, k) {
      var h = el(interactive ? 'button' : 'span', 'wp-hit');
      if (interactive) {
        h.type = 'button';
        h.setAttribute('aria-label', 'Leave at ' + fmt(s[0]) + ', ' + s[1] + ' minute drive');
        h.addEventListener('click', function () { set(k); });
      }
      hits.appendChild(h);
      return h;
    });
    top.appendChild(hits);
    top.appendChild(el('div', 'wp-cursor'));
    top.appendChild(el('div', 'wp-cap wp-left', 'OFFICE → HOME'));
    var state = el('div', 'wp-cap wp-right');
    top.appendChild(state);
    root.appendChild(top);

    var rowEls = [0, 1, 2, 3].map(function (k) {
      var r = el('div', 'wp-row' + (k === 0 ? ' wp-first' : ''));
      r.innerHTML = '<div class="wp-meta"><span class="wp-label"></span><span class="wp-status"><span></span><span class="wp-icon"></span></span></div>' +
        '<div class="wp-main"><span class="wp-name"></span><span class="wp-value"></span></div>';
      root.appendChild(r);
      return {
        label: r.querySelector('.wp-label'), status: r.querySelector('.wp-status > span'),
        icon: r.querySelector('.wp-icon'), name: r.querySelector('.wp-name'), value: r.querySelector('.wp-value')
      };
    });

    var foot = el('div', 'wp-foot');
    foot.innerHTML = '<span class="wp-circle" aria-hidden="true">' + ICON.gear + '</span>' +
      '<span class="wp-footr"><span class="wp-circle wp-faint" aria-hidden="true">' + ICON.scope + '</span><span class="wp-capsule"></span></span>';
    root.appendChild(foot);
    var capsule = foot.querySelector('.wp-capsule');

    var live = el('p', 'wp-sr');
    live.setAttribute('aria-live', 'polite');
    root.appendChild(live);

    function set(i, quiet) {
      index = Math.max(0, Math.min(S.length - 1, i));
      var d = S[index][0], sd = S[SUG][0];
      track.style.transform = 'translateX(' + (180 - (d - E) * PX) + 'px)';
      band.style.left = ((Math.min(d, sd) - E) * PX) + 'px';
      band.style.width = (Math.abs(d - sd) * PX) + 'px';
      band.style.opacity = index === SUG ? '0' : '1';
      hitEls.forEach(function (h, k) {
        h.style.left = (180 + (S[k][0] - d) * PX - 7) + 'px';
        if (interactive) h.setAttribute('aria-pressed', k === index ? 'true' : 'false');
      });
      state.textContent = index === SUG ? 'SUGGESTED' : (d < sd ? 'EARLIER' : 'LATER');
      rowsFor(index).forEach(function (r, k) {
        var o = rowEls[k];
        o.label.textContent = r.label; o.status.textContent = r.status; o.icon.innerHTML = ICON[r.icon];
        o.name.textContent = r.name; o.value.textContent = r.value;
      });
      capsule.textContent = 'USE ' + fmt(d);
      if (!quiet) live.textContent = summary(index);
      if (!quiet && opts.onChange) opts.onChange(index);
    }

    if (interactive) {
      root.addEventListener('keydown', function (e) {
        if (e.key === 'ArrowLeft') { set(index - 1); e.preventDefault(); }
        else if (e.key === 'ArrowRight') { set(index + 1); e.preventDefault(); }
      });
    }

    root.classList.add('wp-still');
    set(index, true);
    requestAnimationFrame(function () { requestAnimationFrame(function () { root.classList.remove('wp-still'); }); });
    return {
      earlier: function () { set(index - 1); }, later: function () { set(index + 1); },
      get index() { return index; }, count: S.length
    };
  };
})();
