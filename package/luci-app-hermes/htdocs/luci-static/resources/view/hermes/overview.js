'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/* Overview: what the agent is doing, and why it is not doing it.
 *
 * A router page is read in two situations only: setting the thing up, and finding out
 * why it stopped. Both want the same six facts on one screen with no clicking, so the
 * status, the version, the space left and the log tail live together here rather than
 * behind separate menu entries.
 *
 * Free space is on this page on purpose. Sessions and memory are a SQLite database that
 * only grows, and a router that fills its overlay stops routing. Putting the number
 * where it is seen every visit is the cheapest way to prevent that.
 */

var callStatus = rpc.declare({ object: 'hermes', method: 'status' });
var callLogs   = rpc.declare({ object: 'hermes', method: 'logs', params: ['lines'] });
var callInit   = rpc.declare({
	object: 'luci',
	method: 'setInitAction',
	params: ['name', 'action'],
	expect: { result: false }
});

function pill(ok, yes, no) {
	return E('span', {
		'class': ok ? 'label' : 'label warning',
		'style': 'padding:2px 8px;border-radius:10px;' +
		         (ok ? 'background:#5cb85c;color:#fff' : 'background:#f0ad4e;color:#fff')
	}, ok ? yes : no);
}

function humanKB(kb) {
	if (!kb) return '?';
	if (kb > 1048576) return (kb / 1048576).toFixed(1) + ' GB';
	if (kb > 1024) return (kb / 1024).toFixed(0) + ' MB';
	return kb + ' KB';
}

return view.extend({
	load: function () {
		/* Both calls tolerated: a fresh install has no service running and no log yet,
		 * and a page that errors out in that state is a page nobody can use to fix it. */
		return Promise.all([
			callStatus().catch(function () { return {}; }),
			callLogs(50).catch(function () { return { log: '' }; })
		]);
	},

	render: function (data) {
		var st = data[0] || {};
		var log = (data[1] || {}).log || '';

		var lowSpace = st.free_kb !== undefined && st.free_kb < 256 * 1024;

		var rows = [
			[_('Service'), pill(st.running, _('running'), _('stopped'))],
			[_('Start on boot'), pill(st.enabled, _('enabled'), _('disabled'))],
			[_('Version'), E('span', {}, st.version || _('unknown'))],
			[_('Data directory'), E('span', {}, st.data_dir || '-')],
			[_('Free space there'), E('span', {
				'style': lowSpace ? 'color:#d9534f;font-weight:bold' : ''
			}, humanKB(st.free_kb))],
			/* Presence only. The backend never returns a key, so there is nothing here
			 * to leak into a screenshot of this page. */
			[_('Model API key'), pill(st.provider_key_set, _('set'), _('missing'))],
			[_('Router access token'), pill(st.router_mcp_key_set, _('set'), _('optional, not set'))]
		];

		var table = E('table', { 'class': 'table' },
			rows.map(function (r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:33%' }, r[0]),
					E('td', { 'class': 'td left' }, r[1])
				]);
			})
		);

		var hint = null;
		if (!st.provider_key_set) {
			/* The single most common reason this page is being read at all. Say what to
			 * do rather than only that something is wrong. */
			hint = E('div', { 'class': 'alert-message warning' }, [
				E('p', {}, _('No model API key is set, so the service will refuse to start.')),
				E('p', {}, _('Set one on the Settings tab, then start the service here.'))
			]);
		} else if (lowSpace) {
			hint = E('div', { 'class': 'alert-message warning' },
				_('Less than 256 MB free where the agent stores sessions and memory. Both only grow; move the data directory to external storage before it fills.'));
		}

		var self = this;
		function act(action) {
			return function (ev) {
				ui.showModal(_('Please wait'), [ E('p', { 'class': 'spinning' }, _('Applying...')) ]);
				return callInit('hermes-agent', action)
					.then(function () { return new Promise(function (r) { window.setTimeout(r, 2000); }); })
					.finally(function () { ui.hideModal(); window.location.reload(); });
			};
		}

		var buttons = E('div', { 'class': 'cbi-page-actions' }, [
			E('button', { 'class': 'cbi-button cbi-button-apply', 'click': act('start') }, _('Start')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-reset', 'click': act('stop') }, _('Stop')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': act('restart') }, _('Restart')),
			' ',
			E('button', { 'class': 'cbi-button', 'click': act(st.enabled ? 'disable' : 'enable') },
				st.enabled ? _('Disable at boot') : _('Enable at boot'))
		]);

		var logBox = E('textarea', {
			'id': 'hermes-log',
			'class': 'cbi-input-textarea',
			'readonly': 'readonly',
			'wrap': 'off',
			'style': 'width:100%;font-family:monospace;font-size:12px',
			'rows': 18
		}, [ log || _('Nothing in the log yet.') ]);

		/* Polled rather than loaded once: the reason someone is on this page is usually
		 * unfolding right now, and making them reload to see the next line is the kind
		 * of small friction that sends people back to SSH. */
		poll.add(function () {
			return callLogs(50).then(function (res) {
				var el = document.getElementById('hermes-log');
				if (el && res && typeof res.log === 'string' && el.value !== res.log) {
					var atBottom = (el.scrollTop + el.clientHeight >= el.scrollHeight - 24);
					el.value = res.log;
					if (atBottom) el.scrollTop = el.scrollHeight;
				}
			}).catch(function () {});
		}, 5);

		return E([], [
			E('h2', {}, _('Hermes Agent')),
			E('p', { 'class': 'cbi-map-descr' },
				_('A self-hosted AI agent running as a service on this router. The model itself runs elsewhere; this device talks to it over the network.')),
			hint,
			table,
			buttons,
			E('h3', {}, _('Log')),
			E('p', { 'class': 'cbi-map-descr' },
				_('The last 50 lines mentioning hermes, refreshed every 5 seconds.')),
			logBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
