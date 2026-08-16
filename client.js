window.__ModuleLoader__.load({
  id: 'dsh-remote',
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    // dsh-remote client half: renders the pairing/admin UI as a native DSH
    // settings section ("手机遥控") instead of a floating button + modal.
    // It talks directly to the loopback pairing surface of the bridge
    // (http://127.0.0.1:8787/pair/*). CORS + local-origin checks live on the
    // bridge side; this bundle uses no other DSH service beyond slots/react.

    var React = require('react');

    var BRIDGE = 'http://127.0.0.1:8787';

    var CSS = [
      '.dsh-remote-root{display:flex;flex-direction:column;gap:14px;max-width:760px;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;color:var(--dsw-alias-label-primary)}',
      '.dsh-remote-card{border:1px solid var(--dsw-alias-border-l2);border-radius:14px;padding:14px;background:var(--dsw-alias-bg-layer-1)}',
      '.dsh-remote-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
      '.dsh-remote-muted{color:var(--dsw-alias-label-tertiary)}',
      '.dsh-remote-qr{display:flex;flex-direction:column;align-items:center;gap:10px}',
      '.dsh-remote-qr img{width:220px;height:220px;border:1px solid var(--dsw-alias-border-l2);border-radius:12px;padding:6px;background:#fff}',
      '.dsh-remote select,.dsh-remote input[type=text]{padding:8px 10px;border:1px solid var(--dsw-alias-border-l2);border-radius:10px;background:var(--dsw-specific-input-major);color:var(--dsw-alias-label-primary);font:inherit;max-width:100%}',
      '.dsh-remote button{font:inherit;padding:7px 12px;border-radius:10px;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-button-elevated-fill);color:var(--dsw-alias-label-primary);cursor:pointer}',
      '.dsh-remote button:hover{background:var(--dsw-alias-button-floating-hover)}',
      '.dsh-remote button.primary{background:var(--dsw-alias-button-primary-fill);border-color:transparent;color:var(--dsw-alias-label-primary-foreground)}',
      '.dsh-remote button.primary:hover{background:var(--dsw-alias-button-primary-hover)}',
      '.dsh-remote button.danger{color:var(--dsw-alias-state-error-primary);border-color:var(--dsw-alias-state-error-secondary)}',
      '.dsh-remote button:disabled{opacity:.5;cursor:not-allowed}',
      '.dsh-remote table{width:100%;border-collapse:collapse}',
      '.dsh-remote th,.dsh-remote td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--dsw-alias-border-l2);vertical-align:middle;font-size:13px}',
      '.dsh-remote .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#16A34A;margin-right:6px}',
      '.dsh-remote .dot.off{background:#D1D5DB}',
      '.dsh-remote .url{font:11px/1.4 ui-monospace,Menlo,monospace;word-break:break-all;color:var(--dsw-alias-label-tertiary)}'
    ].join('\n');

    function esc(value) {
      return String(value ?? '').replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
      });
    }

    function fmtTime(ms) {
      if (!ms) return '-';
      try {
        return new Date(ms).toLocaleString();
      } catch (_) {
        return String(ms);
      }
    }

    function ensureStyle() {
      var style = document.getElementById('dsh-remote-style');
      if (style) return style;
      style = document.createElement('style');
      style.id = 'dsh-remote-style';
      style.textContent = CSS;
      document.head.appendChild(style);
      return style;
    }

    var state = {
      code: null,
      expiresAt: 0,
      base: '',
      bases: [],
      pending: [],
      devices: [],
      requireApproval: true
    };

    var els = {};

    function pairPayload(base, code) {
      return 'dshremote://pair?base=' + encodeURIComponent(base) + '&code=' + encodeURIComponent(code) + '&v=1';
    }

    function webPayload(base, code) {
      var u = new URL('/app/', base);
      u.searchParams.set('code', code);
      return u.toString();
    }

    async function api(path, options) {
      var res = await fetch(BRIDGE + path, Object.assign({}, options, {
        headers: Object.assign({ 'content-type': 'application/json' }, (options && options.headers) || {})
      }));
      if (!res.ok) throw new Error(path + ' HTTP ' + res.status);
      return res.json();
    }

    async function refresh() {
      if (!els.status) return;
      try {
        var data = await api('/pair/admin/state');
        state.bases = data.bases || [];
        state.pending = data.pending || [];
        state.devices = data.devices || [];
        state.requireApproval = data.requireApproval !== false;
        els.status.innerHTML = '<span class="dot"></span>bridge \u6B63\u5E38';
        els.mode.textContent = '\u684C\u9762\u786E\u8BA4: ' + (state.requireApproval ? '\u5F00\u542F' : '\u5173\u95ED');
        renderBases();
        renderPending();
        renderDevices();
        renderQr();
      } catch (_) {
        els.status.innerHTML = '<span class="dot off"></span>bridge \u672A\u8FDE\u63A5';
        els.mode.textContent = '';
      }
    }

    function renderBases() {
      var sel = els.base;
      var prev = state.base;
      sel.innerHTML = '';
      state.bases.forEach(function (b) {
        var opt = document.createElement('option');
        opt.value = b.url;
        opt.textContent = (b.kind === 'tailscale' ? 'Tailscale \u00B7 ' : b.kind === 'lan' ? '\u5C40\u57DF\u7F51 \u00B7 ' : '') + b.url;
        sel.appendChild(opt);
      });
      if (state.bases.length === 0) {
        var empty = document.createElement('option');
        empty.value = '';
        empty.textContent = '\u672A\u68C0\u6D4B\u5230\u53EF\u7528\u5730\u5740';
        sel.appendChild(empty);
      }
      var found = Array.prototype.some.call(sel.options, function (o) { return o.value === prev; });
      state.base = found ? prev : sel.value;
    }

    function renderQr() {
      if (!els.qr) return;
      if (!state.code || !state.base) {
        els.qr.style.display = 'none';
        els.qrEmpty.style.display = 'block';
        els.url.textContent = '';
        els.webUrl.textContent = '';
        els.countdown.textContent = '';
        return;
      }
      els.qr.src = BRIDGE + '/pair/qr.svg?code=' + encodeURIComponent(state.code) + '&base=' + encodeURIComponent(state.base);
      els.qr.style.display = 'block';
      els.qrEmpty.style.display = 'none';
      els.url.textContent = pairPayload(state.base, state.code);
      els.webUrl.textContent = '\u7F51\u9875\u7248\uFF08\u672A\u88C5 App \u65F6\u7528\uFF09\uFF1A' + webPayload(state.base, state.code);
    }

    function tick() {
      if (!state.code || !els.countdown) return;
      var left = Math.max(0, Math.floor((state.expiresAt - Date.now()) / 1000));
      els.countdown.textContent = left > 0 ? '\u4E8C\u7EF4\u7801\u5269\u4F59 ' + left + ' \u79D2\uFF0C\u8FC7\u671F\u81EA\u52A8\u5931\u6548' : '\u4E8C\u7EF4\u7801\u5DF2\u8FC7\u671F';
      if (left === 0 && state.code) {
        state.code = null;
        renderQr();
      }
    }

    function renderPending() {
      if (!els.pending) return;
      if (!state.pending.length) {
        els.pending.innerHTML = '<div class="dsh-remote-muted">\u6682\u65E0</div>';
        return;
      }
      els.pending.innerHTML = '<table><tr><th>\u8BBE\u5907</th><th>\u6765\u6E90 IP</th><th></th></tr>' + state.pending.map(function (p) {
        return '<tr><td>' + esc(p.deviceName) + '</td><td>' + esc(p.ip) + '</td>' +
          '<td style="text-align:right"><button class="primary" data-action="approve" data-id="' + esc(p.id) + '">\u5141\u8BB8</button> ' +
          '<button class="danger" data-action="reject" data-id="' + esc(p.id) + '">\u62D2\u7EDD</button></td></tr>';
      }).join('') + '</table>';
      els.pending.querySelectorAll('button[data-action]').forEach(function (btn) {
        btn.addEventListener('click', function () {
          decide(btn.getAttribute('data-action'), btn.getAttribute('data-id'));
        });
      });
    }

    function renderDevices() {
      if (!els.devices) return;
      if (!state.devices.length) {
        els.devices.innerHTML = '<div class="dsh-remote-muted">\u6682\u65E0</div>';
        return;
      }
      els.devices.innerHTML = '<table><tr><th>\u8BBE\u5907</th><th>\u7ED1\u5B9A\u65F6\u95F4</th><th>\u6700\u8FD1\u6D3B\u8DC3</th><th></th></tr>' + state.devices.map(function (d) {
        return '<tr><td>' + esc(d.name) + '</td><td>' + esc(fmtTime(d.createdAt)) + '</td>' +
          '<td>' + esc(fmtTime(d.lastSeenAt)) + '</td>' +
          '<td style="text-align:right"><button class="danger" data-device="' + esc(d.id) + '">\u540A\u9500</button></td></tr>';
      }).join('') + '</table>';
      els.devices.querySelectorAll('button[data-device]').forEach(function (btn) {
        btn.addEventListener('click', function () {
          revoke(btn.getAttribute('data-device'));
        });
      });
    }

    async function startPair() {
      try {
        var data = await api('/pair/start', { method: 'POST', body: '{}' });
        state.code = data.code;
        state.expiresAt = data.expiresAt;
        renderQr();
      } catch (err) {
        alert('\u751F\u6210\u914D\u5BF9\u7801\u5931\u8D25\uFF1A' + err.message);
      }
    }

    async function decide(action, id) {
      try {
        await api('/pair/' + action, { method: 'POST', body: JSON.stringify({ id: id }) });
        await refresh();
      } catch (err) {
        alert('\u64CD\u4F5C\u5931\u8D25\uFF1A' + err.message);
      }
    }

    async function revoke(deviceId) {
      if (!window.confirm('\u786E\u5B9A\u540A\u9500\u8FD9\u53F0\u8BBE\u5907\uFF1F\u540A\u9500\u540E\u5B83\u9700\u8981\u91CD\u65B0\u626B\u7801\u7ED1\u5B9A\u3002')) return;
      try {
        await api('/pair/revoke', { method: 'POST', body: JSON.stringify({ deviceId: deviceId }) });
        await refresh();
      } catch (err) {
        alert('\u540A\u9500\u5931\u8D25\uFF1A' + err.message);
      }
    }

    async function copyPairUrl() {
      var text = els.url.textContent;
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        window.prompt('\u590D\u5236\u914D\u5BF9\u94FE\u63A5:', text);
      }
    }

    async function copyWebUrl() {
      var text = (els.webUrl.textContent || '').replace(/^\u7F51\u9875\u7248\uFF08\u672A\u88C5 App \u65F6\u7528\uFF09\uFF1A/, '');
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        window.prompt('\u590D\u5236\u7F51\u9875\u7248\u94FE\u63A5:', text);
      }
    }

    var SECTION_MARKUP = [
      '<div class="dsh-remote-root">',
      '  <div class="dsh-remote-card">',
      '    <div class="dsh-remote-row">',
      '      <span id="dsh-remote-status"><span class="dot off"></span>bridge \u68C0\u6D4B\u4E2D\u2026</span>',
      '      <span id="dsh-remote-mode" class="dsh-remote-muted"></span>',
      '      <span style="flex:1"></span>',
      '      <button id="dsh-remote-open-page">\u5728\u6D4F\u89C8\u5668\u6253\u5F00\u914D\u5BF9\u9875</button>',
      '    </div>',
      '  </div>',
      '  <div class="dsh-remote-card">',
      '    <div class="dsh-remote-row" style="margin-bottom:10px">',
      '      <span class="dsh-remote-muted">\u624B\u673A\u8BBF\u95EE\u5730\u5740</span>',
      '      <select id="dsh-remote-base" style="flex:1;min-width:220px"></select>',
      '      <button id="dsh-remote-refresh">\u5237\u65B0</button>',
      '    </div>',
      '    <div class="dsh-remote-qr">',
      '      <img id="dsh-remote-qr" alt="\u914D\u5BF9\u4E8C\u7EF4\u7801" style="display:none">',
      '      <div id="dsh-remote-qr-empty" class="dsh-remote-muted">\u70B9\u51FB\u300C\u751F\u6210\u914D\u5BF9\u4E8C\u7EF4\u7801\u300D\u5F00\u59CB</div>',
      '      <div class="dsh-remote-row">',
      '        <button id="dsh-remote-start" class="primary">\u751F\u6210\u914D\u5BF9\u4E8C\u7EF4\u7801</button>',
      '        <button id="dsh-remote-copy">\u590D\u5236 App \u914D\u5BF9\u94FE\u63A5</button>',
      '        <button id="dsh-remote-copy-web">\u590D\u5236\u7F51\u9875\u7248\u94FE\u63A5</button>',
      '      </div>',
      '      <div id="dsh-remote-url" class="url"></div>',
      '      <div id="dsh-remote-web-url" class="url"></div>',
      '      <div id="dsh-remote-countdown" class="dsh-remote-muted"></div>',
      '    </div>',
      '  </div>',
      '  <div class="dsh-remote-card">',
      '    <div class="dsh-remote-row" style="margin-bottom:8px"><strong>\u5F85\u786E\u8BA4\u7684\u8BBE\u5907</strong></div>',
      '    <div id="dsh-remote-pending"></div>',
      '  </div>',
      '  <div class="dsh-remote-card">',
      '    <div class="dsh-remote-row" style="margin-bottom:8px"><strong>\u5DF2\u7ED1\u5B9A\u8BBE\u5907</strong></div>',
      '    <div id="dsh-remote-devices"></div>',
      '  </div>',
      '</div>'
    ].join('\n');

    function mountSection(host) {
      var style = ensureStyle();
      host.innerHTML = SECTION_MARKUP;
      els = {
        status: host.querySelector('#dsh-remote-status'),
        mode: host.querySelector('#dsh-remote-mode'),
        base: host.querySelector('#dsh-remote-base'),
        qr: host.querySelector('#dsh-remote-qr'),
        qrEmpty: host.querySelector('#dsh-remote-qr-empty'),
        url: host.querySelector('#dsh-remote-url'),
        webUrl: host.querySelector('#dsh-remote-web-url'),
        countdown: host.querySelector('#dsh-remote-countdown'),
        pending: host.querySelector('#dsh-remote-pending'),
        devices: host.querySelector('#dsh-remote-devices')
      };

      host.querySelector('#dsh-remote-open-page').addEventListener('click', function () {
        window.open(BRIDGE + '/pair/qr', '_blank', 'noopener');
      });
      host.querySelector('#dsh-remote-refresh').addEventListener('click', refresh);
      host.querySelector('#dsh-remote-start').addEventListener('click', startPair);
      host.querySelector('#dsh-remote-copy').addEventListener('click', copyPairUrl);
      host.querySelector('#dsh-remote-copy-web').addEventListener('click', copyWebUrl);
      host.querySelector('#dsh-remote-base').addEventListener('change', function (event) {
        state.base = event.target.value;
        renderQr();
      });

      var intervals = [
        window.setInterval(refresh, 2000),
        window.setInterval(tick, 1000)
      ];
      refresh();

      return function () {
        intervals.forEach(window.clearInterval);
        host.innerHTML = '';
        els = {};
        if (style.parentNode) style.parentNode.removeChild(style);
      };
    }

    function RemoteSection() {
      var ref = React.useRef(null);
      React.useEffect(function () {
        if (!ref.current) return undefined;
        return mountSection(ref.current);
      }, []);
      return React.createElement('div', { ref: ref });
    }

    function apply(ctx) {
      ctx.slots.inject('settings.section', function () {
        return ctx.slots.register({
          name: 'settings.section',
          id: 'remote',
          order: 40,
          label: function () {
            return '\u624B\u673A\u9065\u63A7';
          }
        }, RemoteSection);
      });
    }

    exports.apply = apply;
    exports.inject = ['slots'];
    return module.exports;
  }
});
