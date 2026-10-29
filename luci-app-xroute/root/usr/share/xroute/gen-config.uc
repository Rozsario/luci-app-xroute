#!/usr/bin/ucode
// Builds the Xray config from /etc/config/xroute and the stored subscriptions.
// Writes /var/etc/xroute/config.json, /var/etc/xroute/servers (server hosts, one per line)
// and /var/etc/xroute/tests.json (servers, their test ports and the servers that were skipped).
// Supported share links: vless:// (raw/tcp, xhttp, ws, grpc; reality or tls) and hy2:// / hysteria2://,
// including the parameters 3x-ui puts into them (pinSHA256/pcs, vcn, ech, mport, fm, extra).
// XROUTE_SKIP=id1,id2 leaves out servers that Xray rejected, XROUTE_ONLY=id keeps just that one
// server to test it alone (see the init script).

'use strict';

import { cursor } from 'uci';
import { mkdir, readfile, writefile } from 'fs';

const OUTDIR = getenv('XROUTE_OUT_DIR') ?? '/var/etc/xroute';
const SUBDIR = getenv('XROUTE_SUB_DIR') ?? '/etc/xroute/subs';
const PRIVATE_NETS = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4' ];
// TSPU drops the TLS ClientHello of new connections to many foreign servers; cut into small TCP
// segments it passes (measured: 0 of 8 handshakes without, 8 of 8 with). Off with main.fragment = 0.
const FRAGMENT = { type: 'fragment', settings: { packets: 'tlshello', length: '10-30', interval: '5-10' } };
let fragment = true;

// reason of the last rejected link, shown on the status page
let last_err = null;

function reject(msg) {
	last_err = msg;
	return null;
}

function complain(msg) {
	warn('xroute: ' + msg + '\n');
}

function pdec(s) {
	if (s == null)
		return null;
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}

function parse_link(link) {
	let m = match(trim(link), /^([a-z0-9]+):\/\/([^@\/?#]*)@([^\/?#]+)\/?(\?[^#]*)?(#.*)?$/);
	if (!m)
		return null;

	let u = { scheme: m[1], user: pdec(m[2]), query: {}, name: m[5] ? pdec(substr(m[5], 1)) : null };
	let hp = match(m[3], /^\[([^\]]+)\]:(.+)$/) || match(m[3], /^([^:]+):(.+)$/);
	if (!hp)
		return null;

	u.host = hp[1];
	u.port = hp[2];

	if (m[4]) {
		for (let kv in split(substr(m[4], 1), '&')) {
			if (!length(kv))
				continue;
			let i = index(kv, '=');
			u.query[pdec(i < 0 ? kv : substr(kv, 0, i))] = pdec(i < 0 ? '' : substr(kv, i + 1));
		}
	}

	return u;
}

function nonempty(v) {
	return (v != null && v !== '') ? v : null;
}

// TLS for VLESS (security=tls) and Hysteria2. "allowInsecure" is gone in Xray 26 (it refuses to start),
// certificates can be pinned instead (pinSHA256 / pcs = hex SHA-256, comma-separated) or matched by name (vcn).
function tls_settings(q, def_alpn, quic) {
	let t = { serverName: nonempty(q.sni) ?? nonempty(q.peer) ?? '' };
	if (!quic)
		t.fingerprint = nonempty(q.fp) ?? 'chrome';
	if (nonempty(q.alpn))
		t.alpn = split(q.alpn, ',');
	else if (def_alpn)
		t.alpn = def_alpn;

	let pins = nonempty(q.pinSHA256) ?? nonempty(q.pcs);
	if (pins) {
		for (let p in split(pins, ','))
			if (!match(replace(trim(p), /:/g, ''), /^[0-9a-fA-F]{64}$/))
				return reject(`неверный отпечаток сертификата (pinSHA256): ${p}`);
		t.pinnedPeerCertSha256 = pins;
	}
	if (nonempty(q.vcn))
		t.verifyPeerCertByName = q.vcn;
	if (nonempty(q.ech))
		t.echConfigList = q.ech;
	if ((q.insecure == '1' || q.allowInsecure == '1' || q.allow_insecure == '1') && !pins && !nonempty(q.vcn))
		complain(`"insecure" is not supported by Xray 26, the certificate of ${t.serverName} will be verified`);
	return t;
}

function json_object(s) {
	let v = nonempty(s) ? json(s) : null;
	return (type(v) == 'object') ? v : null;
}

// VLESS Encryption: mlkem768x25519plus.<native|xorpub|random>.<1rtt|0rtt>[.padding...].<key>[.key...],
// a key is raw base64url of 32 (X25519) or 1184 (ML-KEM-768) bytes. Xray crashes on some malformed
// strings (no key at all) instead of naming the server, so they are checked here.
function valid_encryption(s) {
	let p = split(s, '.');
	if (length(p) < 4 || p[0] != 'mlkem768x25519plus' || index([ 'native', 'xorpub', 'random' ], p[1]) < 0 ||
	    index([ '1rtt', '0rtt' ], p[2]) < 0)
		return false;

	let keys = 0;
	for (let i = 3; i < length(p); i++) {
		if (length(p[i]) < 20) {
			// padding goes before the keys
			if (keys)
				return false;
			continue;
		}
		if (!match(p[i], /^[A-Za-z0-9_-]+$/) || (length(p[i]) != 43 && length(p[i]) != 1579))
			return false;
		keys++;
	}
	return keys > 0;
}

function vless_outbound(tag, u) {
	let q = u.query;
	let port = int(u.port);
	if (!match(u.user, /^[0-9a-fA-F-]{36}$/))
		return reject('неверный UUID');
	if (port < 1 || port > 65535)
		return reject('неверный порт');
	let enc = nonempty(q.encryption) ?? 'none';
	if (enc != 'none' && !valid_encryption(enc))
		return reject('неверный параметр encryption (VLESS Encryption)');

	let ob = {
		tag: tag,
		protocol: 'vless',
		settings: {
			address: u.host,
			port: port,
			id: u.user,
			encryption: enc,
		},
		streamSettings: {}
	};
	if (nonempty(q.flow))
		ob.settings.flow = q.flow;

	let ss = ob.streamSettings;
	let net = nonempty(q.type) ?? 'tcp';
	if (net == 'splithttp')
		net = 'xhttp';
	ss.network = (net == 'tcp') ? 'raw' : net;

	if (net == 'xhttp') {
		ss.xhttpSettings = { path: nonempty(q.path) ?? '/', mode: nonempty(q.mode) ?? 'auto' };
		if (nonempty(q.host))
			ss.xhttpSettings.host = q.host;
		if (nonempty(q.extra)) {
			let extra = json_object(q.extra);
			if (extra)
				ss.xhttpSettings.extra = extra;
			else
				complain(`${tag}: cannot parse the "extra" parameter of the xhttp link, ignored`);
		}
	}
	else if (net == 'ws') {
		ss.wsSettings = { path: nonempty(q.path) ?? '/' };
		if (nonempty(q.host))
			ss.wsSettings.host = q.host;
	}
	else if (net == 'grpc') {
		ss.grpcSettings = { serviceName: nonempty(q.serviceName) ?? '' };
		if (q.mode == 'multi')
			ss.grpcSettings.multiMode = true;
	}
	else if (net != 'tcp') {
		return reject(`транспорт «${net}» не поддерживается`);
	}

	let sec = nonempty(q.security) ?? 'none';
	ss.security = sec;
	if (sec == 'reality') {
		if (!nonempty(q.pbk))
			return reject('в ссылке Reality нет публичного ключа (pbk)');
		if (!match(q.pbk, /^[A-Za-z0-9_-]{43}$/))
			return reject('неверный публичный ключ Reality (pbk)');
		if (!match(q.sid ?? '', /^([0-9a-fA-F][0-9a-fA-F]){0,8}$/))
			return reject('неверный shortId Reality (sid)');
		ss.realitySettings = {
			serverName: nonempty(q.sni) ?? '',
			fingerprint: nonempty(q.fp) ?? 'chrome',
			publicKey: q.pbk,
			shortId: q.sid ?? '',
			spiderX: nonempty(q.spx) ?? '/',
		};
		if (nonempty(q.pqv))
			ss.realitySettings.mldsa65Verify = q.pqv;
	}
	else if (sec == 'tls') {
		ss.tlsSettings = tls_settings(q, null, false);
		if (!ss.tlsSettings)
			return null;
	}
	else if (sec != 'none') {
		return reject(`защита «${sec}» не поддерживается`);
	}

	// 3x-ui exports Xray's finalmask (fragment, noise, ...) as fm=<json>
	if (nonempty(q.fm)) {
		let fm = json_object(q.fm);
		if (fm)
			ss.finalmask = fm;
		else
			complain(`${tag}: cannot parse the "fm" parameter, ignored`);
	}
	if (fragment && sec != 'none' && !length(ss.finalmask?.tcp ?? [])) {
		ss.finalmask ??= {};
		ss.finalmask.tcp = [ FRAGMENT ];
	}

	return ob;
}

function hysteria2_outbound(tag, u) {
	let q = u.query;
	// port may carry a hopping list (443,20000-30000); 3x-ui puts the range into mport instead
	let first = match(u.port, /^([0-9]+)/);
	let port = first ? int(first[1]) : 0;
	if (port < 1 || port > 65535)
		return reject('неверный порт');
	if (!length(u.user))
		return reject('нет пароля (auth)');

	let tls = tls_settings(q, [ 'h3' ], true);
	if (!tls)
		return null;

	let ss = {
		network: 'hysteria',
		security: 'tls',
		tlsSettings: tls,
		hysteriaSettings: { version: 2, auth: u.user },
	};

	// Xray accepts a malformed range at start and only fails on connect, so it is checked here
	let hop = match(u.port, /[,-]/) ? u.port : nonempty(q.mport);
	if (hop) {
		if (!match(hop, /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/))
			return reject(`неверный диапазон портов: ${hop}`);
		ss.hysteriaSettings.udphop = { ports: hop };
	}

	if (nonempty(q.obfs)) {
		if (q.obfs != 'salamander')
			return reject(`маскировка «${q.obfs}» не поддерживается Xray`);
		ss.finalmask = { udp: [ { type: 'salamander', settings: { password: q['obfs-password'] ?? '' } } ] };
	}

	return {
		tag: tag,
		protocol: 'hysteria',
		settings: { version: 2, address: u.host, port: port },
		streamSettings: ss
	};
}

let c = cursor(getenv('XROUTE_UCI_DIR'));
let main = c.get_all('xroute', 'main') ?? {};
let tport = int(main.tproxy_port ?? 12701);
fragment = (main.fragment ?? '1') != '0';
let skip_ids = {};
for (let id in split(getenv('XROUTE_SKIP') ?? '', ','))
	if (length(id))
		skip_ids[id] = true;
let only_id = nonempty(getenv('XROUTE_ONLY'));

let outbounds = [];
let rules = [];
let servers = [];
let test_inbounds = [];
let tests = [];
let skipped = [];

// Adds one server from a share link; id becomes the outbound tag suffix, source is 'manual' or 'sub:<section>'.
function add_server(id, link, label, source) {
	if (only_id && id != only_id)
		return;

	let tag = 'proxy-' + id;
	let u = parse_link(link);
	let ob = null;
	last_err = null;

	if (skip_ids[id])
		last_err = 'Xray отверг настройки этого сервера (подробности — в системном журнале)';
	else if (!u)
		last_err = 'не удалось разобрать ссылку';
	else if (u.scheme == 'vless')
		ob = vless_outbound(tag, u);
	else if (u.scheme == 'hy2' || u.scheme == 'hysteria2')
		ob = hysteria2_outbound(tag, u);
	else
		last_err = `тип ссылки «${u.scheme}» не поддерживается`;

	if (!ob) {
		complain(`${id}: skipped (${last_err ?? 'unknown reason'})`);
		push(skipped, { name: id, label: label ?? u?.name ?? id, source: source, reason: last_err ?? 'неизвестная ошибка' });
		return;
	}

	push(outbounds, ob);
	push(servers, u.host);

	// local SOCKS port to test this exact server from the status page
	let itag = 'test-' + id;
	let tp = tport + 2 + length(test_inbounds);
	push(test_inbounds, { tag: itag, listen: '127.0.0.1', port: tp, protocol: 'socks', settings: { udp: false } });
	push(rules, { type: 'field', inboundTag: [ itag ], outboundTag: tag });
	push(tests, { name: id, label: label ?? u.name ?? id, proto: ob.protocol, host: u.host, port: tp, source: source });
}

c.foreach('xroute', 'server', function(s) {
	if (s.enabled == '0' || !nonempty(s.link))
		return;
	add_server(s['.name'], s.link, nonempty(s.label), 'manual');
});

// subscriptions: links saved by sub.sh; an optional filter (regex, case-insensitive) is applied to server names
c.foreach('xroute', 'subscription', function(s) {
	if (s.enabled == '0')
		return;

	let data = readfile(SUBDIR + '/' + s['.name'] + '.links');
	if (!data)
		return;

	let re = null;
	if (nonempty(s.filter)) {
		try {
			re = regexp(s.filter, 'i');
		}
		catch (e) {
			complain(`${s['.name']}: invalid filter "${s.filter}", ignored`);
		}
	}

	let n = 0;
	for (let line in split(data, '\n')) {
		line = trim(line);
		if (!length(line))
			continue;
		let u = parse_link(line);
		let name = u?.name ?? `${nonempty(s.label) ?? s['.name']} #${n + 1}`;
		if (re && !match(name, re))
			continue;
		n++;
		add_server(`${s['.name']}_${n}`, line, name, 'sub:' + s['.name']);
	}
});

mkdir(OUTDIR, 0700);

if (!length(outbounds)) {
	writefile(OUTDIR + '/tests.json', sprintf('%J\n', { auto_port: tport + 1, mode: 'auto', servers: [], skipped: skipped }));
	complain('no usable servers configured');
	exit(1);
}

push(outbounds, { tag: 'direct', protocol: 'freedom' });
push(outbounds, { tag: 'block', protocol: 'blackhole' });

push(rules, { type: 'field', ip: PRIVATE_NETS, outboundTag: 'direct' });

// mode: 'auto', a manual server section name, or 'sub:<section>:<server name>' (subscription servers
// are pinned by name, so a reordered subscription does not silently switch to another server)
let mode = main.mode ?? 'auto';
let fixed = null;
if (mode != 'auto') {
	let m = match(mode, /^sub:([^:]+):(.*)$/);
	let t = m ? filter(tests, t => t.source == 'sub:' + m[1] && t.label == m[2])[0]
	          : filter(tests, t => t.name == mode && t.source == 'manual')[0];
	if (t)
		fixed = 'proxy-' + t.name;
	else
		complain(`server "${mode}" is not available, using auto mode`);
}
if (fixed)
	push(rules, { type: 'field', inboundTag: [ 'tproxy', 'test-auto' ], outboundTag: fixed });
else
	push(rules, { type: 'field', inboundTag: [ 'tproxy', 'test-auto' ], balancerTag: 'auto' });

let cfg = {
	log: { loglevel: main.loglevel ?? 'warning', access: 'none' },
	inbounds: [
		{
			tag: 'tproxy', listen: '0.0.0.0', port: tport, protocol: 'dokodemo-door',
			settings: { network: 'tcp,udp', followRedirect: true },
			streamSettings: { sockopt: { tproxy: 'tproxy' } },
			sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true }
		},
		{ tag: 'test-auto', listen: '127.0.0.1', port: tport + 1, protocol: 'socks', settings: { udp: false } },
		...test_inbounds
	],
	outbounds: outbounds,
	observatory: {
		subjectSelector: [ 'proxy-' ],
		probeUrl: main.probe_url ?? 'https://www.gstatic.com/generate_204',
		probeInterval: main.probe_interval ?? '1m',
		enableConcurrency: true
	},
	routing: {
		domainStrategy: 'AsIs',
		balancers: [ { tag: 'auto', selector: [ 'proxy-' ], strategy: { type: 'leastPing' }, fallbackTag: 'direct' } ],
		rules: rules
	}
};

writefile(OUTDIR + '/config.json', sprintf('%J\n', cfg));
writefile(OUTDIR + '/servers', join('\n', servers) + '\n');
writefile(OUTDIR + '/tests.json', sprintf('%J\n',
	{ auto_port: tport + 1, mode: fixed ? mode : 'auto', servers: tests, skipped: skipped }));
exit(0);
