#!/usr/bin/ucode
// Prints the subscription body as plain text: as is if it already contains links,
// otherwise base64-decoded (standard or URL-safe alphabet, padding optional).
// BusyBox on OpenWrt has no base64 applet, hence ucode.
//   b64.uc <file>

'use strict';

import { readfile } from 'fs';

let s = readfile(ARGV[0]) ?? '';
if (index(s, '://') < 0) {
	s = replace(s, /[ \t\r\n]/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	while (length(s) % 4)
		s += '=';
	s = b64dec(s) ?? '';
}
print(s);
