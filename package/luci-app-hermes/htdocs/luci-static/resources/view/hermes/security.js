'use strict';
'require view';
'require rpc';
'require ui';
'require hermes.flash as flash';

/* Security.
 *
 * In the owner profile the agent changes the router only through openwrt-mcp, and only while
 * its owner has unlocked it from Telegram. What unlocking asks for is set here, once: a PIN,
 * a phone with an authenticator app, both, or neither (then nothing can change the router).
 *
 * The page holds to the rule the other two pages hold to, for two more things that are not
 * keys but are credentials: the PIN fields are never filled in from the router, and what the
 * router returns for a phone being added, its QR code and its secret, is on this page once
 * and is taken off it again when the phone is activated, when the page is left, or when the
 * owner cancels. Neither is kept anywhere: not in the tab's storage, not in a message, not
 * in a call. The router tells this page facts (is a PIN set, is a phone enrolled) and never
 * the PIN or the secret, so there is nothing here that could be read back.
 *
 * The page offers what the router could honour and nothing else. A factor that needs a PIN
 * or an enrolled phone that does not exist yet cannot be chosen, which is what keeps the
 * owner from locking themselves out, and outside the owner profile, or when openwrt-mcp is
 * not answering, or before the agent has been started once (which is what pairs it), the
 * page offers no field and no button. The backend refuses the same calls; this is the
 * page saying so before it is asked.
 *
 * One more switch, the owner's opt-in to package installs from the official OpenWrt feed. It can
 * be turned on only with a factor in force, since an install, like any change, waits for an
 * unlock; and on, it is still the agent's start that decides whether openwrt-mcp is one that
 * installs official packages only, so the page says what the switch asks for, not what the agent
 * was given.
 *
 * And who approves a high-impact change (0.21.5-r16): openwrt-mcp holds such a change (a port opened
 * to the internet, the firewall weakened, the ports or VLANs rewired, VPN routing, DNS, the time
 * servers, an open Wi-Fi into a trusted network, a guard stopped, a reboot) until that one change is
 * approved in Telegram with the PIN and an app code. The approver is one of the Telegram ids allowed to talk to the agent, and the
 * page offers only those; with exactly one allowed, that one approves unless another is chosen.
 *
 * What the agent's own connections reach (hermes-agent 0.21.5-r21): limited or open, and the hosts of
 * the house the owner adds, as host:port lines the page holds to the shape the agent reads. And the
 * wrong tries on record (openwrt-mcp 0.5.0.8), which survive a restart: the count, and a Reset that
 * runs `openwrt-mcp mfa reset`, the way out for an owner a guesser has left waiting.
 *
 * And the router's own bot (luci-app-hermes 0.21.5-r7, openwrt-mcp with owner_approves_past_the_listener).
 * @decided 2026-11-08 (openwrt-mcp's docs/approval-path.md, option A2, paraphrased): openwrt-mcp sends
 * the card and reads the owner's answer itself, through a bot of the router's own, so the agent's
 * gateway leaves the approval path. The token field is a key's field: never filled from the router,
 * emptied as soon as it is sent. What comes back is a one-time code and the t.me link that sends it
 * when Start is pressed, shown on the page once and nowhere else; once the chat is bound the agent
 * starts again, and from then on the owner unlocks and approves in the router's chat.
 */

var callStatus   = rpc.declare({ object: 'hermes', method: 'security_status' });
var callSetPin   = rpc.declare({ object: 'hermes', method: 'set_pin', params: ['pin', 'again'] });
var callClearPin = rpc.declare({ object: 'hermes', method: 'clear_pin' });
var callEnrol    = rpc.declare({ object: 'hermes', method: 'enrol_start' });
var callActivate = rpc.declare({ object: 'hermes', method: 'enrol_activate', params: ['code'] });
var callFactor   = rpc.declare({ object: 'hermes', method: 'set_factor', params: ['factor', 'window', 'max_failures', 'lockout'] });
var callPackages = rpc.declare({ object: 'hermes', method: 'set_packages', params: ['packages'] });
var callApprover = rpc.declare({ object: 'hermes', method: 'set_approver', params: ['approver_id'] });
var callNetwork  = rpc.declare({ object: 'hermes', method: 'set_network', params: ['agent_network', 'lan_allow'] });
var callReset    = rpc.declare({ object: 'hermes', method: 'reset_tries' });
var callBotSet   = rpc.declare({ object: 'hermes', method: 'set_owner_bot', params: ['token'] });
var callBotBind  = rpc.declare({ object: 'hermes', method: 'bind_owner_bot' });
var callBotDone  = rpc.declare({ object: 'hermes', method: 'owner_bot_done' });
var callBotClear = rpc.declare({ object: 'hermes', method: 'clear_owner_bot' });

/* A bot token as BotFather gives it, the shape the backend and openwrt-mcp accept. */
var BOT_TOKEN = /^[0-9]{5,16}:[A-Za-z0-9_-]{30,80}$/;

/* What a failure of the router's bot is told by: one word of openwrt-mcp's fixed set, each with its
 * own sentence here. A word outside the set is told as "other", never shown as it came. */
var BOT_FAILURES = {
	token_rejected: _('Telegram does not know this token: paste the token again from @BotFather.'),
	telegram_refused: _('Telegram refused a call of the router\'s bot.'),
	telegram_error: _('Telegram answered the router\'s bot with an error.'),
	tls: _('The connection to Telegram failed its TLS check: check the router\'s date and time.'),
	pipe: _('openwrt-mcp\'s listener, which carries the bot\'s connection, is not answering.'),
	network: _('The router could not reach Telegram.'),
	other: _('The router\'s bot failed.')
};

/* Text from the router always goes into the page as text. In LuCI a string given to E() as its only
 * child is set as HTML, and one inside an array is a text node, so every child here is an array. */
var BIND_CODE = /^[A-Za-z0-9_-]{22}$/;

/* The same shapes the backend and the init accept, so nothing is sent that would be refused. */
var PIN = /^[0-9]{4,8}$/;
var CODE = /^[0-9]{6}$/;
var DURATION = /^([0-9]+(\.[0-9]+)?(s|m|h))+$|^[0-9]+(\.[0-9]+)?d$/;
var LAN_ALLOW = /^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\]):([0-9]{1,5})$/;

function lanAllowOk(line) {
	var m = LAN_ALLOW.exec(line);
	return !!m && +m[3] >= 1 && +m[3] <= 65535;
}

function factors() {
	return [
		['none', _('No second factor'), _('Changes to the router are refused. The agent can still read it.')],
		['pin', _('PIN'), _('needs a PIN to be set first')],
		['totp', _('Authenticator app code'), _('needs a phone to be enrolled first')],
		['pin+totp', _('PIN and app code'), _('needs both a PIN and an enrolled phone')]
	];
}

function needsPin(factor) { return factor === 'pin' || factor === 'pin+totp'; }

/* A factor in force that could unlock an install: the switch below is open only then, as the
 * backend's set_packages accepts official only then. */
function hasFactor(st) {
	return (st.factor === 'pin' || st.factor === 'totp' || st.factor === 'pin+totp') && st.factor_ready !== false;
}

/* Whether the router could honour a factor: what the page offers and what Save lets through. */
function allowed(factor, st) {
	switch (factor) {
	case 'none':     return true;
	case 'pin':      return !!st.pin_set;
	case 'totp':     return !!st.totp_enrolled;
	case 'pin+totp': return !!st.pin_set && !!st.totp_enrolled;
	}
	return false;
}

function say(text, kind) {
	ui.addNotification(null, E('p', {}, [ text ]), kind || 'info');
}

function fail(text) { say(text, 'danger'); }

/* A field of the page: title left, control right, the way LuCI lays out its own. */
function row(title, control, hint) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, [ title ]),
		E('div', { 'class': 'cbi-value-field' }, [ control, hint ? E('div', { 'class': 'cbi-value-description' }, [ hint ]) : '' ])
	]);
}

function pill(ok, yes, no) {
	return E('span', {
		'class': ok ? 'label' : 'label warning',
		'style': 'padding:2px 8px;border-radius:10px;' + (ok ? 'background:#5cb85c;color:#fff' : 'background:#f0ad4e;color:#fff')
	}, [ ok ? yes : no ]);
}

function factorName(f) {
	var hit = factors().filter(function (x) { return x[0] === f; })[0];
	return hit ? hit[1] : _('not a factor the service accepts');
}

/* The page when there is nothing it may offer: a reason, and no control. */
function nothing(title, lines) {
	return E('div', {}, [
		E('h2', {}, _('Security')),
		E('div', { 'class': 'alert-message warning' }, [ E('h4', {}, title) ].concat(lines.map(function (l) { return E('p', {}, [ l ]); })))
	]);
}

return view.extend({
	load: function () {
		/* A failed call is an answer too: the page then says it could not read, and offers nothing. */
		return callStatus().catch(function () { return {}; });
	},

	render: function (st) {
		st = (st && typeof st === 'object') ? st : {};
		var dom = L.dom;
		var page;

		if (!st.profile)
			page = nothing(_('The security status could not be read.'), [
				_('The router did not answer this page. Reload it; if it stays like this, the hermes-agent and luci-app-hermes packages may be out of step.')
			]);
		else if (st.applies !== true)
			page = nothing(_('This page applies to the owner profile only.'), [
				_('The agent runs in the %s profile, where there is no second factor to set: it either runs as root with no unlock, or has no terminal and no way to change the router. Choose the owner profile on the Settings tab to use this page.').format(st.profile)
			]);
		else if (!st.mcp_ok)
			page = nothing(_('openwrt-mcp is not answering.'), [
				_('The PIN and the phone are kept by openwrt-mcp, which hermes-agent installs. Start it with: /etc/init.d/openwrt-mcp start')
			]);
		else if (!st.paired)
			page = nothing(_('The agent has not been started yet.'), [
				_('Starting it once in the owner profile pairs it with openwrt-mcp, which is what this page sets up. Enable the service on the Settings tab and start it, then come back here.')
			]);
		else
			page = this.renderOwner(st, dom);

		flash.show();
		return page;
	},

	renderOwner: function (st, dom) {
		var self = this;
		var held = null;      /* the phone being added: its QR and secret, and nowhere else */

		/* ---- what is in force ---- */
		var factorOk = st.factor === 'invalid' ? false : st.factor_ready !== false;
		var phone = st.totp_enrolled
			? (st.totp_pending ? _('enrolled; another is being added and does not count until its code is entered') : _('enrolled'))
			: (st.totp_pending ? _('being added: not in force until its code is entered') : _('not enrolled'));
		var facts = [
			[_('Profile'), E('span', {}, [ st.profile ])],
			[_('Factor in force'), E('span', {}, [ factorName(st.factor) ])],
			[_('PIN'), pill(st.pin_set, _('set'), _('not set'))],
			[_('Phone'), E('span', {}, [ phone ])],
			[_('Unlock window'), E('span', {}, [ st.window ])],
			[_('Wrong tries before the first wait'), E('span', {}, [ String(st.max_failures) ])],
			[_('First wait after them'), E('span', {}, [ st.lockout ])],
			[_('Package installs'), E('span', {}, st.packages === 'official' ? _('on: the official OpenWrt feed only') : (st.packages === 'invalid' ? _('not a value the service accepts') : _('off')))],
			[_('Who approves high-impact changes'), st.approver
				? E('span', {}, [ _('Telegram id %s').format(st.approver), ' ', pill(!!st.approvals_ready, _('ready'), _('needs a PIN and a phone')) ])
				: pill(false, '', _('nobody: they are refused'))],
			[_("The agent's network"), E('span', {}, st.agent_network === 'open' ? _('open: nothing is limited') : (st.agent_network === 'invalid' ? _('not a value the service accepts') : _('limited')))]
		];
		var table = E('table', { 'class': 'table' }, facts.map(function (r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:33%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]);
		}));

		/* ---- the PIN ---- */
		var pinA = E('input', { 'type': 'password', 'id': 'hermes-sec-pin', 'class': 'cbi-input-password', 'value': '',
			'autocomplete': 'new-password', 'maxlength': '8', 'inputmode': 'numeric',
			'placeholder': st.pin_set ? '••••  ' + _('set') : _('not set') });
		var pinB = E('input', { 'type': 'password', 'id': 'hermes-sec-pin-again', 'class': 'cbi-input-password', 'value': '',
			'autocomplete': 'new-password', 'maxlength': '8', 'inputmode': 'numeric', 'placeholder': _('the same PIN again') });

		function wipePin() { pinA.value = ''; pinB.value = ''; }

		var setPin = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-pin-set',
			'click': ui.createHandlerFn(this, function () {
				var pin = pinA.value, again = pinB.value;
				/* Out of the fields before anything else happens, whatever comes of it. */
				wipePin();
				if (!PIN.test(pin)) return fail(_('A PIN is 4 to 8 digits and nothing else.'));
				if (pin !== again) return fail(_('The two PINs are not the same.'));
				return callSetPin(pin, again).then(function (r) {
					pin = again = '';
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The PIN was not saved.'));
					flash.keep(_('PIN saved. It is kept only as a salted hash, and cannot be shown again.'), 'info');
					/* The PIN and the factor have a Save each, and a PIN alone unlocks nothing while the
					 * factor in force is none: a person set one and missed the other (2026-10-08). */
					if (st.factor === 'none')
						flash.keep(_('The router does not ask for this PIN yet. Under "What unlocking asks for" below, choose PIN and press Save there.'), 'warning');
					window.location.reload();
				}, function () {
					pin = again = '';
					fail(_('The PIN was not saved: the router did not answer.'));
				});
			}) }, st.pin_set ? _('Change PIN') : _('Set PIN'));

		var clearAttrs = { 'class': 'cbi-button cbi-button-remove', 'id': 'hermes-sec-pin-clear',
			'click': ui.createHandlerFn(this, function () {
				return callClearPin().then(function (r) {
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The PIN was not cleared.'));
					flash.keep(_('PIN cleared.'), 'info');
					window.location.reload();
				}, function () { fail(_('The PIN was not cleared: the router did not answer.')); });
			}) };
		var clearWhy = '';
		if (!st.pin_set) { clearAttrs.disabled = 'disabled'; clearWhy = _('No PIN is set.'); }
		else if (needsPin(st.factor)) {
			clearAttrs.disabled = 'disabled';
			clearWhy = _('The factor in force asks for the PIN, so it cannot be cleared: choose another factor below first, or nothing could unlock.');
		}
		var clearPin = E('button', clearAttrs, _('Clear PIN'));

		var pinSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-pin-section' }, [
			E('h3', {}, _('PIN')),
			E('p', { 'class': 'cbi-section-descr' }, (st.pin_set ? _('A PIN is set. ') : _('No PIN is set. ')) +
				_('4 to 8 digits. The router keeps only a salted hash of it, so this page can say that a PIN is set and never what it is. It refuses the PINs a guesser tries first, such as 1234.')),
			row(st.pin_set ? _('New PIN') : _('PIN'), pinA),
			row(_('Again'), pinB),
			E('div', { 'class': 'cbi-page-actions' }, [ setPin, ' ', clearPin, clearWhy ? E('p', { 'class': 'cbi-value-description' }, clearWhy) : '' ])
		]);

		/* ---- the phone ---- */
		var box = E('div', { 'id': 'hermes-sec-phone' });
		var codeIn = null;

		/* Everything of a phone being added goes with this: the QR, the secret, the field for the code. */
		function drop() {
			held = null;
			codeIn = null;
			paint();
		}

		function start() {
			return callEnrol().then(function (r) {
				if (!r || r.ok === false)
					return fail((r && r.error) || _('A phone could not be added.'));
				held = { secret: r.secret, png: r.qr_png_base64 };
				paint();
			}, function () { fail(_('A phone could not be added: the router did not answer.')); });
		}

		function activate() {
			var code = codeIn ? codeIn.value : '';
			if (codeIn) codeIn.value = '';
			if (!CODE.test(code)) return fail(_('A code is the six digits the app shows.'));
			return callActivate(code).then(function (r) {
				code = '';
				if (!r || r.ok === false)
					return fail((r && r.error) || _('That code did not activate the phone.'));
				/* Off the page first, then the reload that shows what is in force. */
				drop();
				flash.keep(_('Phone added. Its code is now one of the things the router can ask for.'), 'info');
				window.location.reload();
			}, function () { fail(_('The phone was not activated: the router did not answer.')); });
		}

		function cancel() {
			drop();
			say(_('Nothing changed: what was in force before is still in force. The phone that was being added is not active, and its code unlocks nothing.'), 'info');
		}

		function paint() {
			if (!held) {
				dom.content(box, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'hermes-sec-enrol',
						'click': ui.createHandlerFn(self, start) }, st.totp_enrolled ? _('Add another phone') : _('Add a phone'))
				]);
				return;
			}
			codeIn = E('input', { 'type': 'text', 'id': 'hermes-sec-code', 'class': 'cbi-input-text', 'value': '',
				'autocomplete': 'off', 'maxlength': '6', 'inputmode': 'numeric', 'placeholder': '123456' });
			dom.content(box, [
				E('p', {}, _('Scan this with an authenticator app (Google Authenticator, Aegis, 1Password and the like), then type the six-digit code the app shows. The phone counts only once that code is entered; until then everything that was in force stays in force.')),
				/* White behind the code and a margin round it, because a code on a dark theme is not scanned. */
				E('div', { 'style': 'display:inline-block;background:#fff;padding:12px;border-radius:4px' }, [
					E('img', { 'id': 'hermes-sec-qr', 'alt': _('QR code to scan with an authenticator app'),
						'width': '256', 'height': '256', 'style': 'display:block;image-rendering:pixelated',
						'src': 'data:image/png;base64,' + held.png })
				]),
				E('p', {}, [ _('Or type this secret into the app: '),
					E('code', { 'id': 'hermes-sec-secret', 'style': 'font-size:1.2em;letter-spacing:.08em;word-break:break-all' }, [ held.secret ]) ]),
				E('p', { 'class': 'cbi-value-description' }, _('This is shown here once. Leaving the page, or Cancel, takes it off; the router keeps nothing that can show it again, so a new QR code is made if you start again.')),
				row(_('Code from the app'), codeIn),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-activate', 'click': ui.createHandlerFn(self, activate) }, _('Check the code and add the phone')),
					' ',
					E('button', { 'class': 'cbi-button', 'id': 'hermes-sec-cancel', 'click': ui.createHandlerFn(self, cancel) }, _('Cancel')),
					' ',
					E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'hermes-sec-enrol', 'click': ui.createHandlerFn(self, start) }, _('Start again with a new QR code'))
				])
			]);
		}
		paint();
		/* A page that is left takes the QR with it, in the page's own view of it too. */
		window.addEventListener('pagehide', function () { held = null; codeIn = null; paint(); });

		var phoneSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Phone')),
			E('p', { 'class': 'cbi-section-descr' }, _('An authenticator app on your phone gives a new six-digit code every thirty seconds. Adding one shows a QR code here, once.')),
			box
		]);

		/* ---- the factor ---- */
		var radios = factors().map(function (f) {
			var ok = allowed(f[0], st);
			var attrs = { 'type': 'radio', 'name': 'hermes-sec-factor', 'id': 'hermes-sec-factor-' + f[0], 'value': f[0] };
			if (st.factor === f[0]) attrs.checked = 'checked';
			if (!ok) attrs.disabled = 'disabled';
			return { value: f[0], node: E('input', attrs), label: f };
		});
		function chosen() {
			var hit = radios.filter(function (r) { return r.node.checked; })[0];
			return hit ? hit.value : null;
		}
		var inWindow = E('input', { 'type': 'text', 'id': 'hermes-sec-window', 'class': 'cbi-input-text', 'value': st.window, 'size': '8' });
		var inMax = E('input', { 'type': 'text', 'id': 'hermes-sec-max', 'class': 'cbi-input-text', 'value': String(st.max_failures), 'size': '3', 'inputmode': 'numeric' });
		var inLockout = E('input', { 'type': 'text', 'id': 'hermes-sec-lockout', 'class': 'cbi-input-text', 'value': st.lockout, 'size': '8' });

		var save = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-save',
			'click': ui.createHandlerFn(this, function () {
				var f = chosen(), win = inWindow.value.trim(), max = inMax.value.trim(), lock = inLockout.value.trim();
				if (!f) return fail(_('Choose what unlocking asks for.'));
				/* A stale tab, a script or a hand-edited page can tick what is disabled; it goes no further. */
				if (!allowed(f, st)) return fail(_('That choice needs something that is not set up yet, so it cannot be saved.'));
				if (!DURATION.test(win)) return fail(_('The unlock window is a duration such as 15m, 1h or 1d.'));
				if (!/^[0-9]{1,2}$/.test(max) || +max < 1) return fail(_('Wrong tries before the first wait is a whole number from 1 to 99.'));
				if (!DURATION.test(lock)) return fail(_('The first wait is a duration such as 15m, 1h or 1d.'));
				return callFactor(f, win, +max, lock).then(function (r) {
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The choice was not saved.'));
					flash.keep(_('Saved. The agent restarts to apply it; send /unlock in the private chat to try it.'), 'info');
					window.location.reload();
				}, function () { fail(_('The choice was not saved: the router did not answer.')); });
			}) }, _('Save'));

		/* Beside the choice, and an alert when it is the factor in force. There is no last try: a
		 * PIN of four digits falls to one try an hour in about fourteen months. */
		var pinAlone = E('div', { 'id': 'hermes-sec-pin-alone', 'style': 'margin-left:1.6em',
			'class': st.factor === 'pin' ? 'alert-message warning' : 'cbi-value-description' },
			_('A PIN alone is the weakest choice. Wrong tries cost a wait of up to an hour and there is no last try, so someone patient gets through every four-digit PIN in about fourteen months. PIN and app code does not have this problem.'));

		var factorSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('What unlocking asks for')),
			E('p', { 'class': 'cbi-section-descr' }, _('Each of these is optional, and the choice is yours. A choice is open only when what it needs is already set up; that keeps you from choosing something the router could never satisfy.')),
			!factorOk ? E('div', { 'class': 'alert-message warning' }, _('The factor in force asks for something that is not set up, so nothing can be unlocked right now. Choose another below, or set up what it needs.')) : '',
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Factor')),
				E('div', { 'class': 'cbi-value-field' }, radios.map(function (r) {
					return E('div', { 'style': 'margin-bottom:.4em' }, [
						E('label', { 'for': 'hermes-sec-factor-' + r.value }, [ r.node, ' ', r.label[1] ]),
						(allowed(r.value, st) && r.value !== 'none') ? '' : E('div', { 'class': 'cbi-value-description', 'style': 'margin-left:1.6em' }, r.label[2]),
						r.value === 'pin' ? pinAlone : ''
					]);
				}))
			]),
			row(_('Unlock window'), inWindow, _('How long one unlock keeps changes open, such as 15m.')),
			row(_('Wrong tries'), inMax, _('Wrong tries in a row before the first wait, 1 to 99.')),
			row(_('First wait'), inLockout, _('How long unlocking is refused after them, such as 15m. Each further wrong try doubles it, up to an hour, and there is no last try: a wait ends by itself.')),
			E('div', { 'class': 'cbi-page-actions' }, [ save ])
		]);

		/* ---- package installs, the owner's opt-in ---- */
		var pkgAttrs = { 'type': 'checkbox', 'id': 'hermes-sec-packages', 'value': 'official' };
		if (st.packages === 'official') pkgAttrs.checked = 'checked';
		var pkgOpen = hasFactor(st);
		/* Turning it off is always open; turning it on needs a factor. */
		if (!pkgOpen && st.packages !== 'official') pkgAttrs.disabled = 'disabled';
		var pkgBox = E('input', pkgAttrs);
		var pkgSave = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-packages-save',
			'click': ui.createHandlerFn(this, function () {
				var want = pkgBox.checked ? 'official' : 'off';
				/* A stale tab or a script can tick what is disabled; it goes no further. */
				if (want === 'official' && !hasFactor(st))
					return fail(_('Package installs need a second factor in force, since an install waits for an unlock like any change. Choose one under "What unlocking asks for" first.'));
				return callPackages(want).then(function (r) {
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The choice was not saved.'));
					flash.keep(want === 'official'
						? _('Saved. After the restart the agent can install packages from the official OpenWrt feed while you have changes unlocked, if openwrt-mcp is one that installs official packages only; the log says so if it is not.')
						: _('Saved. After the restart the agent cannot install packages.'), 'info');
					window.location.reload();
				}, function () { fail(_('The choice was not saved: the router did not answer.')); });
			}) }, _('Save'));
		var pkgWhy = '';
		if (st.packages === 'invalid')
			pkgWhy = E('div', { 'class': 'alert-message warning' }, _('hermes.security.packages holds a value the service does not accept, so it will not start. Save here to put it back to off or official.'));
		else if (st.packages === 'official' && !pkgOpen)
			pkgWhy = E('div', { 'class': 'alert-message warning' }, _('This is on, but no second factor is in force, so the agent is given nothing to install with. Choose a factor above, or turn this off.'));
		else if (!pkgOpen)
			pkgWhy = E('p', { 'class': 'cbi-value-description' }, _('Needs a second factor in force first: an install waits for an unlock like any change.'));
		var packagesSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-packages-section' }, [
			E('h3', {}, _('Package installs')),
			E('p', { 'class': 'cbi-section-descr' }, _('Off unless you turn it on. On, the agent may install a package you ask for from the official OpenWrt feed only, never from a link, a file or another feed, and only while you have changes unlocked; it tries the install first without installing and tells you what it would add and how much space that takes. Every install is in the audit log of openwrt-mcp.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'hermes-sec-packages' }, _('Packages')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'for': 'hermes-sec-packages' }, [ pkgBox, ' ', _('Let the agent install packages from the official OpenWrt feed') ]),
					pkgWhy
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [ pkgSave ])
		]);

		/* ---- who approves a high-impact change ---- */
		var choices = (st.approver_choices || []).filter(function (id) { return /^[0-9]+$/.test(id); });
		var auto = choices.length === 1
			? _('The one Telegram user allowed (%s), chosen automatically').format(choices[0])
			: _('Nobody: high-impact changes are refused');
		var apSel = E('select', { 'id': 'hermes-sec-approver', 'class': 'cbi-input-select' },
			[ E('option', { 'value': '' }, auto) ].concat(choices.map(function (id) {
				var attrs = { 'value': id };
				if (st.approver_id === id) attrs.selected = 'selected';
				return E('option', attrs, [ _('Telegram id %s').format(id) ]);
			})));
		if (!choices.length) apSel.disabled = 'disabled';
		var apSave = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-approver-save',
			'click': ui.createHandlerFn(this, function () {
				var want = apSel.value || '';
				/* A stale tab or a script can put anything in the select; only an allowed id or none goes. */
				if (want !== '' && choices.indexOf(want) < 0)
					return fail(_('Only a Telegram user allowed to talk to the agent can approve; add the id on the Settings tab first.'));
				return callApprover(want).then(function (r) {
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The choice was not saved.'));
					flash.keep(_('Saved. The agent restarts to apply it.'), 'info');
					window.location.reload();
				}, function () { fail(_('The choice was not saved: the router did not answer.')); });
			}) }, _('Save'));
		if (!choices.length) apSave.disabled = 'disabled';
		var apWhy = '';
		if (st.approvals_where === 'router')
			apWhy = E('div', { 'class': 'alert-message info', 'id': 'hermes-sec-approver-router' }, _('You approve in the router\'s own chat (above), so who approves here is not used.'));
		else if (!choices.length)
			apWhy = E('div', { 'class': 'alert-message warning' }, _('Approvals are given in the private Telegram chat with the agent. Turn Telegram on and allow your Telegram id on the Settings tab first; until then high-impact changes are refused.'));
		else if (st.approver && !st.approvals_ready)
			apWhy = E('div', { 'class': 'alert-message warning' }, _('Approving takes both your PIN and a code from your phone, and one of them is not set up yet, so a high-impact change is refused until it is. Set up what is missing above.'));
		else if (st.approver_id === 'invalid')
			apWhy = E('div', { 'class': 'alert-message warning' }, _('hermes.security.approver_id holds a value the service does not accept, so it will not start. Save here to choose again.'));
		var approverSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-approver-section' }, [
			E('h3', {}, _('High-impact changes')),
			E('p', { 'class': 'cbi-section-descr' }, _('Some changes wait for your approval of that one change, even while changes are unlocked: opening a port to the internet, weakening the firewall, rewiring ports or VLANs, changing VPN routing, DNS or the time servers, opening a Wi-Fi without a password into a trusted network, stopping a service that guards the router, a reboot. The agent cannot make them alone: the bot sends you the change, and you approve it with your PIN and a code from your phone, or reject it with one tap.')),
			row(_('Who approves'), apSel, _('One of the Telegram users allowed to talk to the agent.')),
			apWhy,
			E('div', { 'class': 'cbi-page-actions' }, [ apSave ])
		]);

		/* ---- the router's own bot: where the owner approves, past the agent ---- */
		var botSection = '';
		if (st.owner_bot_supported) {
			var botToken = E('input', { 'type': 'password', 'id': 'hermes-sec-bot-token', 'class': 'cbi-input-password',
				'autocomplete': 'off', 'spellcheck': 'false', 'placeholder': '123456789:AA...' });
			var botLink = E('div', { 'id': 'hermes-sec-bot-link' });
			var waiting = 0;
			/* The code and its link, once, on this page; then the page asks every three seconds, for ten
			 * minutes at most, whether the chat is bound, and once it is restarts the agent and reloads. */
			var showLink = function (r) {
				var code = String((r && r.code) || ''), link = String((r && r.link) || '');
				if (!BIND_CODE.test(code)) return fail(_('The router answered without a code to bind your chat.'));
				var lines = [ E('p', {}, _('Open the router\'s bot in Telegram and press Start; this page notices when your chat is bound.')) ];
				if (/^https:\/\/t\.me\/[A-Za-z0-9_]+\?start=[A-Za-z0-9_-]{22}$/.test(link))
					lines.push(E('p', {}, E('a', { 'href': link, 'target': '_blank', 'rel': 'noopener noreferrer', 'id': 'hermes-sec-bot-start' }, [ link ])));
				lines.push(E('p', {}, [ _('Or send it this code after pressing Start:'), ' ', E('code', { 'id': 'hermes-sec-bot-code' }, [ code ]) ]));
				lines.push(E('p', {}, _('The code works once, for 30 minutes.')));
				dom.content(botLink, lines);
				var round = ++waiting, tries = 0;
				var ask = function () {
					if (round !== waiting || ++tries > 200) return;
					return callStatus().then(function (s) {
						if (round !== waiting) return;
						if (!s || !s.owner_bot_bound) return void window.setTimeout(ask, 3000);
						waiting++;
						dom.content(botLink, []);
						return callBotDone().then(function () {
							flash.keep(_('Your chat is bound. From now on you unlock and approve in the router\'s own chat; the agent restarts to leave the approval path.'), 'info');
							window.location.reload();
						});
					}, function () { if (round === waiting) window.setTimeout(ask, 3000); });
				};
				window.setTimeout(ask, 3000);
			};
			var botSave = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-bot-save',
				'click': ui.createHandlerFn(this, function () {
					var tok = botToken.value.trim();
					botToken.value = '';
					if (!BOT_TOKEN.test(tok)) return fail(_('That is not a bot token as BotFather gives it: digits, a colon, then the secret.'));
					return callBotSet(tok).then(function (r) {
						tok = '';
						if (!r || r.ok === false) return fail((r && r.error) || _('The token was not saved.'));
						showLink(r);
					}, function () { tok = ''; fail(_('The token was not saved: the router did not answer.')); });
				}) }, _('Save and bind'));
			var botBind = E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'hermes-sec-bot-bind',
				'click': ui.createHandlerFn(this, function () {
					return callBotBind().then(function (r) {
						if (!r || r.ok === false) return fail((r && r.error) || _('No code was made.'));
						showLink(r);
					}, function () { fail(_('No code was made: the router did not answer.')); });
				}) }, st.owner_bot_bound ? _('Bind another chat') : _('Show a code again'));
			var botClear = E('button', { 'class': 'cbi-button cbi-button-reset', 'id': 'hermes-sec-bot-clear',
				'click': ui.createHandlerFn(this, function () {
					return callBotClear().then(function (r) {
						if (!r || r.ok === false) return fail((r && r.error) || _('The bot was not removed.'));
						flash.keep(_('Removed. Unlocking and approving are back in the chat with the agent; the agent restarts.'), 'info');
						window.location.reload();
					}, function () { fail(_('The bot was not removed: the router did not answer.')); });
				}) }, _('Remove'));
			if (!st.owner_bot_configured) { botBind.disabled = 'disabled'; botClear.disabled = 'disabled'; }
			var botState = st.owner_bot_bound
				? pill(true, st.owner_bot_name ? _('bound: you approve in the chat with @%s').format(st.owner_bot_name) : _('bound: you approve in the router\'s chat'), '')
				: st.owner_bot_configured ? pill(false, '', _('token set, your chat is not bound yet')) : pill(false, '', _('not set up'));
			botSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-bot-section' }, [
				E('h3', {}, _('The router\'s own chat')),
				E('p', { 'class': 'cbi-section-descr' }, _('The router can ask you itself, through a Telegram bot of its own: the card of a change and your answer then never pass through the agent. You approve the same way, one tap and one message with your PIN and a code, in that chat. It takes about two minutes, once: create a bot with @BotFather (/newbot), paste its token here, then press Start on the link this page shows.')),
				row(_('State'), E('span', { 'id': 'hermes-sec-bot-state' }, botState)),
				st.owner_bot_failure ? E('div', { 'class': 'alert-message warning', 'id': 'hermes-sec-bot-error' },
					[ BOT_FAILURES[st.owner_bot_failure] || BOT_FAILURES.other ]) : '',
				row(_('Bot token'), botToken, _('From @BotFather. Kept on the router, root only; never shown again.')),
				botLink,
				E('div', { 'class': 'cbi-page-actions' }, [ botSave, ' ', botBind, ' ', botClear ])
			]);
		}

		/* ---- wrong tries on record ---- */
		var triesSection = '';
		if (st.tries_counted) {
			var resetAttrs = { 'class': 'cbi-button cbi-button-action', 'id': 'hermes-sec-tries-reset',
				'click': ui.createHandlerFn(this, function () {
					return callReset().then(function (r) {
						if (!r || r.ok === false)
							return fail((r && r.error) || _('The count was not cleared.'));
						flash.keep(_('Cleared. Unlocking is open again, at once.'), 'info');
						window.location.reload();
					}, function () { fail(_('The count was not cleared: the router did not answer.')); });
				}) };
			if (!st.failed_tries) resetAttrs.disabled = 'disabled';
			triesSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-tries-section' }, [
				E('h3', {}, _('Wrong tries')),
				E('p', { 'class': 'cbi-section-descr' }, _('Wrong tries in a row count against unlocking and approving, yours and anyone else\'s alike. Past the limit each one costs a wait that doubles up to an hour, for you too, and neither a restart nor a reboot clears them. A right answer does, and so does a day with none. If some of them did not come from your Telegram chat, the bot tells you there.')),
				row(_('On record'), E('strong', { 'id': 'hermes-sec-tries' }, [ String(st.failed_tries) ])),
				st.tries_saved === false ? E('div', { 'class': 'alert-message warning' }, _('openwrt-mcp cannot save this count right now, its storage may be full, so it counts in memory and this number can be behind.')) : '',
				E('div', { 'class': 'cbi-page-actions' }, [ E('button', resetAttrs, _('Reset')) ])
			]);
		}

		/* ---- what the agent's own connections reach ---- */
		var netSel = E('select', { 'id': 'hermes-sec-network', 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'limited' }, _('Limited')),
			E('option', { 'value': 'open' }, _('Open'))
		]);
		netSel.value = st.agent_network === 'open' ? 'open' : 'limited';
		/* A textarea takes its text as a value, not as an attribute. */
		var netHosts = E('textarea', { 'id': 'hermes-sec-lan-allow', 'class': 'cbi-input-textarea', 'rows': '3', 'style': 'width:100%',
			'autocomplete': 'off', 'spellcheck': 'false', 'placeholder': 'nas.lan:445' });
		netHosts.value = (st.lan_allow || []).join('\n');
		var netSave = E('button', { 'class': 'cbi-button cbi-button-save', 'id': 'hermes-sec-network-save',
			'click': ui.createHandlerFn(this, function () {
				var want = netSel.value;
				var hosts = netHosts.value.split('\n').map(function (l) { return l.trim(); }).filter(function (l) { return l !== ''; });
				var bad = hosts.filter(function (l) { return !lanAllowOk(l); })[0];
				/* A stale tab or a script can put anything here; only what the service accepts goes. */
				if (want !== 'limited' && want !== 'open') return fail(_('The agent\'s network is limited or open.'));
				if (bad !== undefined) return fail(_('%s is not host:port, or [IPv6 address]:port, with a port from 1 to 65535.').format(bad));
				return callNetwork(want, hosts).then(function (r) {
					if (!r || r.ok === false)
						return fail((r && r.error) || _('The choice was not saved.'));
					flash.keep(_('Saved. The agent restarts to apply it.'), 'info');
					window.location.reload();
				}, function () { fail(_('The choice was not saved: the router did not answer.')); });
			}) }, _('Save'));
		var netWhy = '';
		if (st.agent_network === 'invalid')
			netWhy = E('div', { 'class': 'alert-message warning' }, _('hermes.security.agent_network holds a value the service does not accept, so it will not start. Save here to put it back to limited or open.'));
		else if (st.agent_network === 'open')
			netWhy = E('div', { 'class': 'alert-message warning', 'id': 'hermes-sec-network-open' }, _('The agent\'s connections are not limited: it reaches SSH and LuCI on this router, its other services and every host of your house.'));
		var networkSection = E('div', { 'class': 'cbi-section', 'id': 'hermes-sec-network-section' }, [
			E('h3', {}, _('What the agent reaches')),
			E('p', { 'class': 'cbi-section-descr' }, _('Limited needs nothing from you: the agent keeps the internet, DNS, openwrt-mcp, llm-gateway and the model endpoints named in its settings, wherever they are, and loses SSH, LuCI and everything else on this router\'s own addresses, the other hosts of your house, over IPv4 or IPv6, and your tailnet. This is about the agent alone: your own SSH and LuCI are not touched.')),
			netWhy,
			row(_('The agent\'s network'), netSel),
			row(_('Hosts it may also reach'), netHosts, _('One host of your house per line, as host:port or [IPv6 address]:port, over TCP and UDP. Not for a model endpoint: the ones named in the settings already work. SSH and LuCI on this router stay closed whatever a line says.')),
			E('div', { 'class': 'cbi-page-actions' }, [ netSave ])
		]);

		var note = E('p', { 'class': 'cbi-section-descr' }, _('The unlock window that is open right now cannot be shown here: openwrt-mcp keeps it in memory only. /lock in the Telegram chat closes it at once.'));
		var plain = window.location.protocol === 'http:'
			? E('div', { 'class': 'alert-message warning' }, _('This page is not served over HTTPS, so a PIN or a QR code sent from here crosses your network unencrypted. On a network you do not trust, use the SSH way in the README instead.'))
			: '';

		return E('div', {}, [
			E('h2', {}, _('Security')),
			E('p', { 'class': 'cbi-map-descr' }, _('In the owner profile the agent reads this router freely and changes it only through openwrt-mcp, and only while you have unlocked it from Telegram with /unlock. This page sets up what unlocking asks for.')),
			plain,
			table,
			note,
			pinSection,
			phoneSection,
			factorSection,
			triesSection,
			botSection,
			approverSection,
			networkSection,
			packagesSection
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
