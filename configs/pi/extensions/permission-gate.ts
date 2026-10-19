// permission-gate.ts - permission gate for Pi 1.1.0 (bash/powershell, write/edit, secret reads).
//
// Why: Pi reads web content (MCP "web") and its bash tool runs anything without asking, so a prompt
// injection in a fetched page could make the model push code, delete files or read keys. This
// extension inspects every tool call BEFORE it runs (event `tool_call`):
//   bash / powershell  command split on ; && || | & newline ( ) { } and backticks; heredoc bodies and
//                      nested scripts are analysed recursively: bash/sh -c, powershell/pwsh -Command
//                      and -EncodedCommand, cmd /c, eval, iex, Start-Process, find -exec, xargs, sudo,
//                      env, npx, string literals of inline python/node/php/perl/ruby code.
//   write / edit       target outside the session cwd, or .ssh, .env*, PowerShell profile, Startup
//                      folder, shell rc files / ~/.gitconfig, .git/hooks, .git/config, any .pi/ dir
//                      (the model must not edit its own config or this gate).
//   read/grep/find/ls  only secret paths (.ssh, private keys, credential files, Pi auth.json).
// Categories (bash): network (ssh/scp/sftp/rsync remote, git push, git remote add|set-url, gh writes,
//   curl/wget/iwr/irm sending data, download|exec, iex, npm publish), destructive (rm -r/-f,
//   Remove-Item -Recurse, del|rmdir|rd /s, git reset --hard / clean -f / checkout -- / restore /
//   branch -D / stash drop|clear, dd, mkfs, format X:, shutdown, reboot), database (artisan
//   migrate:fresh|reset|rollback|refresh, db:wipe, --force; DROP/TRUNCATE via mysql/psql/sqlite),
//   secrets (.ssh, private keys, known_hosts, authorized_keys, env/printenv/set/Env: dumps,
//   $..KEY/TOKEN/SECRET/PASSWORD), system (sudo, runas, -Verb RunAs, reg add|delete,
//   Set-ExecutionPolicy, schtasks /create, Register-ScheduledTask, sc create, New-Service, Startup
//   folder, setx, SetEnvironmentVariable User|Machine, global installs npm -g / pip outside venv /
//   winget / choco / scoop / uv tool / cargo / go install), config (Pi config), outside-cwd.
//
// Behaviour:
//   interactive (TUI/RPC, ctx.hasUI)  ctx.ui.select: "Deny" (first = default) / "Allow once" /
//                                     "Allow this pattern for this session" (same category+rule until
//                                     the session ends). Prompts are serialised.
//   non-interactive (-p, --mode json) BLOCK with a reason telling the model to ask the user.
//   Every decision is appended to ~/.pi/agent/gate.log (time, decision, mode, tool, categories,
//   command summary <= 200 chars with secrets redacted). Write/edit contents are never logged.
// Off switch: PI_GATE=off (or 0/false/no) in the environment of the pi process -> no handler is
//   registered (automated harnesses in a disposable clone). Example (pwsh):
//     $env:PI_GATE = 'off'; .\scripts\pi-local.ps1 -p "..."; Remove-Item Env:PI_GATE
//   PI_GATE_LOG=<file> overrides the log path (unit tests).
// Limits: a speed bump against prompt injection, NOT a sandbox. It matches command text; code hidden
//   in script files, variables or interpreter APIs (subprocess argument lists, strings built at run
//   time) is not seen. Run untrusted tasks in a throwaway clone.
//
// Installed as ~/.pi/agent/extensions/permission-gate.ts (copy of configs/pi/extensions/). Unit tests:
// tests/permission-gate.test.mjs (node >= 23.6 strips the types). Keep this file free of
// TypeScript-only runtime syntax (enum, namespace, parameter properties) so plain node can load it.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import * as nodePath from "node:path";
import { fileURLToPath } from "node:url";

export type Flavor = "bash" | "ps" | "cmd";
export interface Hit {
	category: string;
	rule: string;
}
type Acc = Map<string, Hit>;

const MAX_DEPTH = 8;

function add(acc: Acc, category: string, rule: string): void {
	const key = `${category}:${rule}`;
	if (!acc.has(key)) acc.set(key, { category, rule });
}

export function hitKey(h: Hit): string {
	return `${h.category}:${h.rule}`;
}

// ---------------------------------------------------------------- lexing helpers

/** Lower-case basename without .exe/.cmd/.bat, stripped of grouping characters. */
function cmdName(w: string): string {
	let b = w.replace(/^[({[]+|[)}\]]+$/g, "");
	const i = Math.max(b.lastIndexOf("/"), b.lastIndexOf("\\"));
	if (i >= 0) b = b.slice(i + 1);
	return b.toLowerCase().replace(/\.(exe|cmd|bat|com)$/, "");
}

/** Index of the bracket closing the one at `i` (quote aware); end of string when unbalanced. */
function matchClose(src: string, i: number, open: string, close: string): number {
	let depth = 0;
	let q: string | null = null;
	for (let j = i; j < src.length; j++) {
		const c = src[j];
		if (q) {
			if (c === "\\" && q === '"') {
				j++;
				continue;
			}
			if (c === q) q = null;
			continue;
		}
		if (c === "'" || c === '"') {
			q = c;
			continue;
		}
		if (c === open) depth++;
		else if (c === close) {
			depth--;
			if (depth === 0) return j;
		}
	}
	return src.length - 1;
}

/** bash heredocs: bodies are cut out (each analysed on its own, so quotes in prose cannot hide code). */
function extractHeredocs(src: string): { text: string; bodies: string[] } {
	if (!src.includes("<<")) return { text: src, bodies: [] };
	const lines = src.split(/\r?\n/);
	const out: string[] = [];
	const bodies: string[] = [];
	for (let i = 0; i < lines.length; i++) {
		const tags: Array<{ tag: string; dash: boolean }> = [];
		out.push(
			lines[i].replace(
				/(^|[^<])<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\3/g,
				(_m: string, pre: string, dash: string, _q: string, tag: string) => {
					tags.push({ tag, dash: dash === "-" });
					return `${pre}< __HEREDOC__`;
				},
			),
		);
		for (const t of tags) {
			const body: string[] = [];
			while (i + 1 < lines.length) {
				i++;
				const l = lines[i];
				if ((t.dash ? l.replace(/^\t+/, "") : l).trim() === t.tag) break;
				body.push(l);
			}
			bodies.push(body.join("\n"));
		}
	}
	return { text: out.join("\n"), bodies };
}

interface Segment {
	text: string;
	group: number; // segments joined only by pipes / brackets share a group
	piped: boolean; // stdin comes from the previous segment (|)
}

/** Split a command line into simple commands. Command substitutions inside double quotes go to `nested`. */
function splitSegments(src: string, flavor: Flavor, nested: string[]): Segment[] {
	const segs: Segment[] = [];
	let cur = "";
	let group = 0;
	let piped = false;
	let q: string | null = null;
	const flush = () => {
		if (cur.trim()) {
			segs.push({ text: cur.trim(), group, piped });
			piped = false;
		}
		cur = "";
	};
	const hard = () => {
		flush();
		group++;
		piped = false;
	};
	for (let i = 0; i < src.length; i++) {
		const c = src[i];
		const n = src[i + 1];
		if (q === "'") {
			cur += c;
			if (c === "'") q = null;
			continue;
		}
		if (q === '"') {
			if (flavor === "bash" && c === "\\" && n !== undefined) {
				cur += c + n;
				i++;
				continue;
			}
			if (flavor === "ps" && c === "`" && n !== undefined) {
				cur += c + n;
				i++;
				continue;
			}
			if (flavor !== "cmd" && c === "$" && n === "(") {
				const end = matchClose(src, i + 1, "(", ")");
				nested.push(src.slice(i + 2, end));
				cur += "__SUB__";
				i = end;
				continue;
			}
			if (flavor === "bash" && c === "`") {
				const e = src.indexOf("`", i + 1);
				const end = e < 0 ? src.length : e;
				nested.push(src.slice(i + 1, end));
				cur += "__SUB__";
				i = end;
				continue;
			}
			cur += c;
			if (c === '"') q = null;
			continue;
		}
		if (c === "'" && flavor !== "cmd") {
			q = "'";
			cur += c;
			continue;
		}
		if (c === '"') {
			q = '"';
			cur += c;
			continue;
		}
		if (flavor === "bash" && c === "\\" && n !== undefined) {
			if (n === "\n") {
				i++;
				continue;
			}
			cur += c + n;
			i++;
			continue;
		}
		if (flavor === "ps" && c === "`" && n !== undefined) {
			if (n === "\n") {
				i++;
				continue;
			}
			cur += c + n;
			i++;
			continue;
		}
		if (flavor === "cmd" && c === "^" && n !== undefined) {
			cur += n;
			i++;
			continue;
		}
		if (flavor !== "cmd" && c === "$" && n === "{") {
			const end = matchClose(src, i + 1, "{", "}");
			cur += src.slice(i, end + 1);
			i = end;
			continue;
		}
		if (c === "\n" || c === ";" || c === "\r") {
			hard();
			continue;
		}
		if (c === "&") {
			if (n === "&") {
				hard();
				i++;
				continue;
			}
			const p = src[i - 1];
			if (p === ">" || p === "<" || n === ">") {
				cur += c;
				continue;
			}
			hard();
			continue;
		}
		if (c === "|") {
			if (n === "|") {
				hard();
				i++;
				continue;
			}
			flush();
			piped = true;
			if (n === "&") i++;
			continue;
		}
		if (c === "(" || c === ")" || c === "{" || c === "}") {
			flush();
			continue;
		}
		if (flavor === "bash" && c === "`") {
			flush();
			continue;
		}
		cur += c;
	}
	flush();
	return segs;
}

/** Shell words with quotes removed. */
function words(seg: string, flavor: Flavor): string[] {
	const out: string[] = [];
	let cur = "";
	let has = false;
	let q: string | null = null;
	for (let i = 0; i < seg.length; i++) {
		const c = seg[i];
		const n = seg[i + 1];
		if (q === "'") {
			if (c === "'") {
				if (flavor === "ps" && n === "'") {
					cur += "'";
					i++;
					continue;
				}
				q = null;
			} else cur += c;
			continue;
		}
		if (q === '"') {
			if (c === '"') {
				q = null;
				continue;
			}
			if (flavor === "bash" && c === "\\" && n !== undefined && '"\\$`'.includes(n)) {
				cur += n;
				i++;
				continue;
			}
			if (flavor === "ps" && c === "`" && n !== undefined) {
				cur += n;
				i++;
				continue;
			}
			cur += c;
			continue;
		}
		if (/\s/.test(c)) {
			if (has) out.push(cur);
			cur = "";
			has = false;
			continue;
		}
		if (c === "'" && flavor !== "cmd") {
			q = "'";
			has = true;
			continue;
		}
		if (c === '"') {
			q = '"';
			has = true;
			continue;
		}
		if (flavor === "bash" && c === "\\" && n !== undefined && /[\s"'\\$;&|<>()`!*?#~{}]/.test(n)) {
			cur += n;
			i++;
			has = true;
			continue;
		}
		if (flavor === "ps" && c === "`" && n !== undefined) {
			cur += n;
			i++;
			has = true;
			continue;
		}
		cur += c;
		has = true;
	}
	if (has) out.push(cur);
	return out;
}

/** Drop leading options (and the values of options listed in `withValue`), then a lone `--`. */
function dropOpts(args: string[], withValue: Set<string>): string[] {
	let i = 0;
	while (i < args.length && args[i].startsWith("-") && args[i].length > 1) {
		if (args[i] === "--") {
			i++;
			break;
		}
		if (withValue.has(args[i])) i++;
		i++;
	}
	return args.slice(i);
}

function positionals(args: string[]): string[] {
	return args.filter((a) => !a.startsWith("-"));
}

const RECURSE = /^-r(e(c(u(r(s(e)?)?)?)?)?)?(:\$?true)?$/i;
const SECRET_NAME =
	/(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(?:_|$)|(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$/i;
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh", "fish", "ash", "mksh"]);
const POWERSHELLS = new Set(["powershell", "pwsh", "powershell_ise"]);
const DOWNLOADERS = new Set(["curl", "wget", "iwr", "irm", "invoke-webrequest", "invoke-restmethod", "aria2c", "http", "https", "xh"]);
const STDIN_INTERPRETERS = new Set([
	...SHELLS,
	...POWERSHELLS,
	"python",
	"python3",
	"py",
	"node",
	"deno",
	"bun",
	"perl",
	"ruby",
	"php",
	"cmd",
]);
const READ_ONLY = new Set([
	"cat", "less", "more", "head", "tail", "ls", "dir", "ll", "grep", "egrep", "fgrep", "rg", "fd", "find", "wc",
	"stat", "file", "type", "get-content", "gc", "select-string", "sls", "get-childitem", "gci", "get-item", "gi",
	"test-path", "resolve-path", "diff", "cmp", "sha256sum", "sha1sum", "md5sum", "get-filehash", "jq", "realpath",
	"readlink", "du", "tree", "echo", "printf", "write-output", "write-host", "code", "basename", "dirname",
]);
const GIT_READ = new Set(["status", "log", "diff", "show", "rev-parse", "describe", "ls-files", "ls-tree", "cat-file", "blame", "grep", "shortlog", "reflog"]);
const GH_WRITE_VERBS = new Set([
	"create", "merge", "close", "edit", "comment", "review", "delete", "reopen", "ready", "transfer", "lock", "unlock",
	"upload", "rename", "archive", "unarchive", "fork", "add", "remove", "rerun", "cancel", "enable", "disable", "sync",
	"pin", "unpin", "develop", "run", "set", "revert", "update-branch", "install", "upgrade",
]);
const ARTISAN_DANGER = new Set(["migrate:fresh", "migrate:reset", "migrate:rollback", "migrate:refresh", "db:wipe"]);
const INSTALL_VERBS = new Set([
	"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isntal", "isntall", "add", "update", "up", "upgrade",
	"uninstall", "un", "unlink", "remove", "rm", "r", "link", "ln",
]);

// ---------------------------------------------------------------- text-level rules

const TEXT_RULES: Array<[RegExp, string, string]> = [
	[/(^|[\s'"=:~/\\])\.ssh([/\\'"\s]|$)/i, "secrets", ".ssh directory"],
	[/\bid_(rsa|dsa|ecdsa|ed25519)(_sk)?\b/i, "secrets", "private key file"],
	[/\bknown_hosts\b/i, "secrets", "known_hosts"],
	[/\bauthorized_keys\b/i, "secrets", "authorized_keys"],
	[/\.git-credentials\b|\.aws[/\\]credentials\b|(^|[\s'"/\\~])\.netrc\b/i, "secrets", "credential file"],
	[/\.pi[/\\]+agent[/\\]+auth\.json/i, "secrets", "Pi auth.json"],
	[/GetEnvironmentVariables\s*\(/i, "secrets", "dump environment"],
	[/(^|[\s(;|&'"])env:[\\/]?\*?\s*($|[\s|;)'"&])/i, "secrets", "list Env: drive"],
	[/-Verb\s*:?\s*['"]?RunAs\b/i, "system", "-Verb RunAs (elevation)"],
	[/\bSet-ExecutionPolicy\b/i, "system", "Set-ExecutionPolicy"],
	[/SetEnvironmentVariable\s*\([^)]*\b(User|Machine)\b/i, "system", "persistent env var (User/Machine)"],
	[/EnvironmentVariableTarget\]::(User|Machine)/i, "system", "persistent env var (User/Machine)"],
	[/Start Menu[/\\]+Programs[/\\]+Startup|shell:(common\s*)?startup|[/\\]Startup[/\\]/i, "system", "Startup folder"],
	[/CurrentVersion[/\\]+Run(Once)?\b/i, "system", "registry Run key (autostart)"],
	[/\bRegister-ScheduledTask\b|\bNew-ScheduledTask\w*\b|\bSet-ScheduledTask\b/i, "system", "scheduled task"],
	[/\b(New|Set)-Service\b/i, "system", "Windows service"],
	[/\bInstall-(Module|Package|Script|PSResource)\b/i, "system", "global install (PowerShell)"],
	[/\bInvoke-Expression\b|\|\s*iex\b|(^|[\s;(&|])iex\s*[($'"]/i, "network", "Invoke-Expression"],
	[/\.Upload(String|File|Data|Values)(Async)?\s*\(/i, "network", "WebClient upload"],
	[/\b(ba|z|da|k)?sh\s+(-[a-zA-Z]+\s+)*<\(\s*(curl|wget)\b/i, "network", "download | exec"],
	[/\b(ba|z|da|k)?sh\s+(-[a-zA-Z]+\s+)*-c\s+["']?\$\(\s*(curl|wget)\b/i, "network", "download | exec"],
];
const DB_CLIENT = /\b(mysql|mariadb|psql|sqlite3?|sqlcmd|duckdb|tinker)\b|\bartisan\s+db\b/i;
const DB_DESTRUCT = /\bDROP\s+(DATABASE|SCHEMA|TABLE)\b|\bTRUNCATE\b/i;
const VAR_REF = /\$\{?(?:env:)?([A-Za-z_][A-Za-z0-9_]*)\}?|%([A-Za-z_][A-Za-z0-9_]*)%/gi;

function textRules(src: string, acc: Acc): void {
	for (const [re, cat, rule] of TEXT_RULES) if (re.test(src)) add(acc, cat, rule);
	if (DB_CLIENT.test(src) && DB_DESTRUCT.test(src)) add(acc, "database", "DROP/TRUNCATE via SQL client");
	if (/\bmysqladmin\b[^\n]*\bdrop\b/i.test(src)) add(acc, "database", "mysqladmin drop");
	for (const m of src.matchAll(VAR_REF)) {
		const name = m[1] ?? m[2];
		if (name && SECRET_NAME.test(name)) add(acc, "secrets", `secret variable ${name}`);
	}
}

// ---------------------------------------------------------------- per-command rules

/** Remove wrappers (sudo, env, nohup, timeout, xargs, npx, ...) and leading VAR=value. */
function unwrap(ws0: string[], flavor: Flavor, acc: Acc): string[] {
	let ws = ws0;
	for (let guard = 0; guard < 12; guard++) {
		while (ws.length && (ws[0] === "" || ws[0] === "!" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(ws[0]))) ws = ws.slice(1);
		if (!ws.length) return ws;
		const c = cmdName(ws[0]);
		const rest = ws.slice(1);
		if (c === "sudo" || c === "doas" || c === "gsudo" || c === "pkexec") {
			add(acc, "system", `${c} (elevation)`);
			ws = dropOpts(rest, new Set(["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "--user", "--group"]));
			continue;
		}
		if (c === "env") {
			let j = 0;
			while (j < rest.length && (rest[j].startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(rest[j]))) {
				if (rest[j] === "-u" || rest[j] === "-C" || rest[j] === "-S") j++;
				j++;
			}
			if (j >= rest.length) {
				add(acc, "secrets", "env (prints environment)");
				return [];
			}
			ws = rest.slice(j);
			continue;
		}
		if (["nohup", "time", "exec", "command", "builtin", "winpty", "stdbuf", "nice", "ionice", "call", "noglob"].includes(c)) {
			let r = dropOpts(rest, new Set(["-n", "-c", "-p", "-o", "-e", "-i"]));
			if ((c === "nice" || c === "ionice") && r.length && /^-?\d+$/.test(r[0])) r = r.slice(1);
			ws = r;
			continue;
		}
		if (c === "timeout" && flavor !== "cmd") {
			let r = dropOpts(rest, new Set(["-s", "-k", "--signal", "--kill-after"]));
			if (r.length && /^\d+(\.\d+)?[smhd]?$/.test(r[0])) r = r.slice(1);
			ws = r;
			continue;
		}
		if (c === "xargs") {
			ws = dropOpts(rest, new Set(["-I", "-n", "-P", "-d", "-L", "-s", "-a", "-E", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--replace"]));
			continue;
		}
		if (c === "npx" || c === "pnpx" || c === "bunx" || c === "uvx") {
			ws = dropOpts(rest, new Set(["-p", "--package", "--from", "--with", "-c", "--call"]));
			continue;
		}
		if ((c === "pnpm" || c === "yarn") && rest[0] === "dlx") {
			ws = dropOpts(rest.slice(1), new Set(["-p", "--package"]));
			continue;
		}
		if (c === "start" && flavor !== "ps") {
			let r = rest;
			while (r.length && (r[0] === "" || r[0].startsWith("/"))) r = r.slice(1);
			if (!r.length) return [];
			ws = r;
			continue;
		}
		break;
	}
	return ws;
}

/** Value of an option given as `-X POST`, `-XPOST`, `--request=POST`, `-Method:Post`. */
function optValue(args: string[], names: RegExp): string | undefined {
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		const m = a.match(/^(-{1,2}[A-Za-z-]+)(?:[=:](.*))?$/);
		if (m && names.test(m[1])) return (m[2] ?? args[i + 1] ?? "").toUpperCase();
	}
	return undefined;
}

const WRITE_METHODS = /^(POST|PUT|PATCH|DELETE)$/i;

// curl short options that take a value (the rest of a cluster is that value): -o file, -H hdr, -XPOST ...
const CURL_ARG = new Set("odFTXHAuxebcmrwKECYyzUQtPDh".split(""));

/** curl/wget (also PowerShell aliases) and Invoke-WebRequest/RestMethod that SEND data. GET stays allowed. */
function curlRules(c: string, a: string[], acc: Acc): void {
	const hit = () => add(acc, "network", `${c} sending data`);
	const curlLike = c === "curl" || c === "wget";
	if ((c === "http" || c === "https" || c === "xh") && WRITE_METHODS.test(positionals(a)[0] ?? "")) hit();
	for (let i = 0; i < a.length; i++) {
		const w = a[i];
		if (curlLike) {
			if (/^--(data|data-ascii|data-binary|data-raw|data-urlencode|json|form|form-string|upload-file|post-data|post-file|body-data|body-file)(=|$)/i.test(w)) {
				hit();
				return;
			}
			if (/^--(request|method)(=|$)/i.test(w)) {
				if (WRITE_METHODS.test(w.includes("=") ? w.slice(w.indexOf("=") + 1) : a[i + 1] ?? "")) hit();
				continue;
			}
			if (c === "curl" && /^-[A-Za-z]/.test(w)) {
				for (let k = 1; k < w.length; k++) {
					const ch = w[k];
					if (ch === "d" || ch === "F" || ch === "T") {
						hit();
						return;
					}
					if (ch === "X") {
						if (WRITE_METHODS.test(w.slice(k + 1) || a[i + 1] || "")) hit();
						break;
					}
					if (CURL_ARG.has(ch)) break;
				}
			}
		}
		// PowerShell parameters (Invoke-WebRequest/RestMethod; curl/wget are their aliases in Windows PowerShell 5.1)
		if (/^-(body|infile|form)(:.*)?$/i.test(w)) {
			hit();
			return;
		}
		const pm = w.match(/^-(m|me|met|meth|metho|method)(?::(.*))?$/i);
		if (pm && WRITE_METHODS.test(pm[2] ?? a[i + 1] ?? "")) hit();
	}
}

function gitRules(a: string[], acc: Acc): string {
	let i = 0;
	while (i < a.length && a[i].startsWith("-")) {
		if (["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"].includes(a[i])) i++;
		i++;
	}
	const sub = (a[i] ?? "").toLowerCase();
	const r = a.slice(i + 1);
	const rl = r.map((x) => x.toLowerCase());
	const shortHas = (ch: string) => r.some((x) => /^-[A-Za-z]+$/.test(x) && x.includes(ch));
	switch (sub) {
		case "push":
			add(acc, "network", "git push");
			break;
		case "send-email":
			add(acc, "network", "git send-email");
			break;
		case "remote":
			if (["add", "set-url"].includes(rl[0] ?? "")) add(acc, "network", `git remote ${rl[0]}`);
			break;
		case "reset":
			if (rl.includes("--hard")) add(acc, "destructive", "git reset --hard");
			break;
		case "clean":
			if (rl.includes("--force") || shortHas("f")) add(acc, "destructive", "git clean -f");
			break;
		case "checkout": {
			const dd = r.indexOf("--");
			if ((dd >= 0 && dd < r.length - 1) || r.includes(".") || rl.includes("-f") || rl.includes("--force"))
				add(acc, "destructive", "git checkout -- <paths> / -f");
			break;
		}
		case "restore": {
			const staged = rl.includes("--staged") || r.includes("-S");
			const worktree = rl.includes("--worktree") || r.includes("-W");
			if (!staged || worktree) add(acc, "destructive", "git restore (discards changes)");
			break;
		}
		case "branch":
			if (r.includes("-D") || ((rl.includes("-d") || rl.includes("--delete")) && (rl.includes("-f") || rl.includes("--force"))) || r.some((x) => /^-[a-zA-Z]*D/.test(x)))
				add(acc, "destructive", "git branch -D");
			break;
		case "stash":
			if (["drop", "clear"].includes(rl[0] ?? "")) add(acc, "destructive", `git stash ${rl[0]}`);
			break;
		case "filter-branch":
		case "filter-repo":
			add(acc, "destructive", `git ${sub}`);
			break;
		case "credential":
			add(acc, "secrets", "git credential");
			break;
	}
	return sub;
}

function ghRules(a: string[], acc: Acc): void {
	const pos: string[] = [];
	for (let i = 0; i < a.length; i++) {
		const w = a[i];
		if (w === "-R" || w === "--repo" || w === "--hostname") {
			i++;
			continue;
		}
		if (!w.startsWith("-")) pos.push(w.toLowerCase());
	}
	const [s1, s2] = pos;
	if (!s1) return;
	if (s1 === "api") {
		const m = optValue(a, /^(-X|--method)$/);
		const mx = a.find((x) => /^-X[A-Za-z]+$/.test(x));
		const method = m ?? (mx ? mx.slice(2).toUpperCase() : undefined);
		if (method && method !== "GET") add(acc, "network", "gh api write");
		else if (!method && a.some((x) => /^(-f|-F|--field|--raw-field|--input)(=|$)/.test(x))) add(acc, "network", "gh api write");
		return;
	}
	if (s1 === "auth") {
		if (s2 === "token") add(acc, "secrets", "gh auth token");
		else if (s2 && s2 !== "status") add(acc, "system", `gh auth ${s2}`);
		return;
	}
	if (s1 === "release") {
		if (s2 && !["list", "view", "download", "verify", "verify-asset"].includes(s2)) add(acc, "network", `gh release ${s2}`);
		return;
	}
	if ((s1 === "secret" || s1 === "variable") && s2 && s2 !== "list" && s2 !== "get") {
		add(acc, "network", `gh ${s1} ${s2}`);
		return;
	}
	if (s2 && GH_WRITE_VERBS.has(s2)) add(acc, "network", `gh ${s1} ${s2}`);
}

function pkgRules(c: string, a: string[], ws0: string, acc: Acc, fullText: string): void {
	const pos = positionals(a);
	const sub = (pos[0] ?? "").toLowerCase();
	const al = a.map((x) => x.toLowerCase());
	if ((c === "npm" || c === "pnpm" || c === "yarn") && (sub === "publish" || sub === "unpublish")) add(acc, "network", `${c} ${sub}`);
	if (c === "npm" || c === "pnpm" || c === "bun") {
		const global =
			al.includes("-g") || al.includes("--global") || al.includes("--location=global") ||
			al.some((x, i) => x === "--location" && al[i + 1] === "global");
		if (global && INSTALL_VERBS.has(sub)) add(acc, "system", `${c} global install`);
	}
	if (c === "yarn" && sub === "global") add(acc, "system", "yarn global");
	if (c === "composer" && sub === "global") add(acc, "system", "composer global");
	if ((c === "cargo" || c === "go") && sub === "install") add(acc, "system", `${c} install`);
	if (c === "cargo" && sub === "publish") add(acc, "network", "cargo publish");
	if (c === "gem" && ["install", "update", "uninstall"].includes(sub)) add(acc, "system", `gem ${sub}`);
	if (c === "gem" && sub === "push") add(acc, "network", "gem push");
	if (c === "twine" && sub === "upload") add(acc, "network", "twine upload");
	if (c === "dotnet" && sub === "tool" && (al.includes("-g") || al.includes("--global"))) add(acc, "system", "dotnet tool --global");
	if (c === "dotnet" && sub === "nuget" && pos[1] === "push") add(acc, "network", "dotnet nuget push");
	if (c === "winget" && ["install", "add", "upgrade", "update", "uninstall", "remove", "rm", "import", "configure"].includes(sub))
		add(acc, "system", `winget ${sub}`);
	if ((c === "choco" || c === "chocolatey") && ["install", "upgrade", "uninstall"].includes(sub)) add(acc, "system", `choco ${sub}`);
	if (c === "cinst" || c === "cup") add(acc, "system", "choco install");
	if (c === "scoop" && ["install", "update", "uninstall", "reset"].includes(sub)) add(acc, "system", `scoop ${sub}`);
	if (c === "pipx" && ["install", "inject", "upgrade", "upgrade-all", "reinstall", "reinstall-all", "uninstall"].includes(sub))
		add(acc, "system", `pipx ${sub}`);
	if (c === "uv") {
		if (sub === "tool" && ["install", "upgrade", "update"].includes((pos[1] ?? "").toLowerCase())) add(acc, "system", "uv tool install");
		if (sub === "pip" && al.includes("--system")) add(acc, "system", "uv pip --system");
	}
	// pip (pip, pip3, pip3.13, python -m pip, py -m pip)
	let pipArgs: string[] | undefined;
	if (/^pip(\d+(\.\d+)?)?$/.test(c)) pipArgs = a;
	else if (/^(python(\d+(\.\d+)?)?|py)$/.test(c)) {
		const k = a.indexOf("-m");
		if (k >= 0 && /^pip(\d+(\.\d+)?)?$/.test(a[k + 1] ?? "")) pipArgs = a.slice(k + 2);
	}
	if (pipArgs) {
		const ps = positionals(pipArgs);
		const pl = pipArgs.map((x) => x.toLowerCase());
		if (["install", "uninstall"].includes((ps[0] ?? "").toLowerCase())) {
			const inVenv =
				!!process.env.VIRTUAL_ENV || !!process.env.CONDA_PREFIX ||
				/(^|[/\\])\.?venv[/\\]|[/\\](scripts|bin)[/\\]pip/i.test(ws0) ||
				/\bactivate\b/.test(fullText) ||
				pl.some((x) => /^(--target|-t|--prefix|--root|--dry-run)(=|$)/.test(x));
			if (!inVenv) add(acc, "system", `pip ${ps[0].toLowerCase()} outside venv`);
		}
	}
}

/** Analyse one simple command. Returns {name, args} for the pipeline pass. */
function segmentRules(seg: Segment, flavor: Flavor, depth: number, acc: Acc, fullText: string): { c: string; a: string[] } {
	const ws = unwrap(words(seg.text, flavor), flavor, acc);
	if (!ws.length) return { c: "", a: [] };
	const c = cmdName(ws[0]);
	const a = ws.slice(1);
	const al = a.map((x) => x.toLowerCase());
	const sub = (positionals(a)[0] ?? "").toLowerCase();
	const nest = (script: string, f: Flavor) => analyze(script, f, depth + 1, acc, fullText);

	// ---- nested interpreters
	if (SHELLS.has(c)) {
		const k = a.findIndex((x) => /^-[A-Za-z]*c[A-Za-z]*$/.test(x));
		if (k >= 0) {
			const rest = a.slice(k + 1).filter((x) => !/^-[A-Za-z]+$/.test(x));
			if (rest.length) nest(rest[0], "bash");
		}
	} else if (POWERSHELLS.has(c)) {
		const VALUE_OPTS = /^-(ex|ep|executionpolicy|w|windowstyle|version|v|inputformat|if|outputformat|of|wd|workingdirectory|configurationname|config|custompipename|settingsfile)$/i;
		for (let i = 0; i < a.length; i++) {
			const w = a[i];
			if (/^-(c|co|com|comm|comma|comman|command)(:.*)?$/i.test(w)) {
				nest(a.slice(i + 1).join(" "), "ps");
				break;
			}
			if (/^-(e|ec|en|enc|enco|encod|encode|encoded|encodedc\w*)$/i.test(w)) {
				const b64 = a[i + 1] ?? "";
				let decoded = "";
				try {
					decoded = Buffer.from(b64, "base64").toString("utf16le");
				} catch {
					decoded = "";
				}
				const ascii = decoded.replace(/[^\x09\x0a\x0d\x20-\x7e]/g, "").length;
				if (decoded.trim() && ascii >= decoded.length * 0.9) nest(decoded, "ps");
				else add(acc, "system", "undecodable -EncodedCommand");
				break;
			}
			if (/^-(f|fi|fil|file)$/i.test(w)) break;
			if (VALUE_OPTS.test(w)) {
				i++;
				continue;
			}
			if (w.startsWith("-")) continue;
			nest(a.slice(i).join(" "), "ps"); // positional = command
			break;
		}
	} else if (c === "cmd") {
		const k = a.findIndex((x) => /^\/\/?[ck]$/i.test(x));
		if (k >= 0) nest(a.slice(k + 1).join(" "), "cmd");
	} else if (c === "eval") {
		nest(a.join(" "), "bash");
	} else if (c === "iex" || c === "invoke-expression") {
		add(acc, "network", "Invoke-Expression");
		nest(a.join(" "), "ps");
	} else if (c === "start-process" || c === "saps" || (c === "start" && flavor === "ps")) {
		const script = a
			.filter((x) => !/^-(filepath|argumentlist|args|wait|nonewwindow|windowstyle|workingdirectory|passthru|redirectstandard\w*|loaduserprofile|useshellexecute|verb)$/i.test(x))
			.join(" ")
			.replace(/,/g, " ");
		nest(script, "ps");
	} else if (/^(python(\d+(\.\d+)?)?|py|node|deno|bun|php|perl|ruby)$/.test(c)) {
		const k = a.findIndex((x) => /^(-c|-e|-E|-r|--eval|-p|--print)$/.test(x));
		if (k >= 0 && a[k + 1]) {
			for (const m of a[k + 1].matchAll(/(["'`])((?:\\.|(?!\1)[^\\])*)\1/g)) if (/\s/.test(m[2])) nest(m[2], "bash");
		}
	} else if (c === "find") {
		if (al.includes("-delete")) add(acc, "destructive", "find -delete");
		for (let i = 0; i < a.length; i++) {
			if (/^-(exec|execdir|ok|okdir)$/.test(a[i])) {
				const cmd: string[] = [];
				for (i++; i < a.length && a[i] !== ";" && a[i] !== "\\;" && a[i] !== "+"; i++) cmd.push(a[i]);
				nest(cmd.join(" "), "bash");
			}
		}
	}

	// ---- network
	if (["ssh", "scp", "sftp", "mosh", "telnet", "ftp", "nc", "ncat", "netcat", "socat"].includes(c)) add(acc, "network", c);
	if (c === "rsync") {
		const remote = a.some((x) => !x.startsWith("-") && (/^rsync:\/\//i.test(x) || x.includes("::") || (/^[^/\\\s]*:/.test(x) && !/^[A-Za-z]:([/\\]|$)/.test(x))));
		if (remote || al.includes("-e") || al.some((x) => x.startsWith("--rsh"))) add(acc, "network", "rsync to remote host");
	}
	if (c === "git") gitRules(a, acc);
	if (c === "gh") ghRules(a, acc);
	if (DOWNLOADERS.has(c) || (flavor === "ps" && c === "curl")) curlRules(c, a, acc);
	if (["invoke-command", "icm"].includes(c) && al.some((x) => /^-(computername|cn|session|hostname|vmname|containerid|uri)$/.test(x)))
		add(acc, "network", "Invoke-Command remote");
	if (["enter-pssession", "etsn", "new-pssession", "nsn"].includes(c)) add(acc, "network", "PowerShell remoting");
	if (c === "send-mailmessage") add(acc, "network", "Send-MailMessage");

	// ---- packages / installs
	pkgRules(c, a, ws[0], acc, fullText);
	if (c === "pi" && ["install", "remove", "uninstall", "update", "config"].includes(sub)) add(acc, "config", `pi ${sub}`);

	// ---- destructive
	if (c === "rm") {
		for (const x of a) {
			if (x === "--") break;
			if (/^--(recursive|force|no-preserve-root)$/i.test(x) || (/^-[^-]/.test(x) && /[rRf]/.test(x))) {
				add(acc, "destructive", "rm -r/-f");
				break;
			}
		}
	}
	if (["rmdir", "rd", "del", "erase", "ri", "remove-item"].includes(c) && a.some((x) => /^\/\/?s$/i.test(x) || RECURSE.test(x)))
		add(acc, "destructive", `${c} /s or -Recurse`);
	if (c === "dd" && a.some((x) => /^(if|of)=/i.test(x))) add(acc, "destructive", "dd");
	if (c === "mkfs" || c.startsWith("mkfs.") || ["format-volume", "clear-disk", "initialize-disk", "diskpart"].includes(c))
		add(acc, "destructive", c);
	if (c === "format" && a.some((x) => /^[A-Za-z]:\\?$/.test(x))) add(acc, "destructive", "format drive");
	if (["shutdown", "reboot", "poweroff", "halt", "restart-computer", "stop-computer"].includes(c)) add(acc, "destructive", c);
	if (["shred", "wipe", "rimraf"].includes(c)) add(acc, "destructive", c);

	// ---- database (artisan anywhere: php artisan, ./artisan, sail artisan)
	const ai = ws.findIndex((x) => cmdName(x) === "artisan");
	if (ai >= 0) {
		const aa = ws.slice(ai + 1);
		const asub = (positionals(aa)[0] ?? "").toLowerCase();
		if (ARTISAN_DANGER.has(asub)) add(acc, "database", `artisan ${asub}`);
		else if (aa.some((x) => /^--force(=|$)/i.test(x))) add(acc, "database", `artisan ${asub || "command"} --force`);
	}

	// ---- secrets
	if (c === "printenv") add(acc, "secrets", "printenv");
	if (c === "set" && flavor !== "ps") {
		if (!a.length || (flavor === "cmd" && !a[0].startsWith("/") && !a[0].includes("="))) add(acc, "secrets", "set (prints environment)");
	}
	if (c === "export" && (!a.length || (a.length === 1 && a[0] === "-p"))) add(acc, "secrets", "export -p (prints environment)");
	if ((c === "declare" || c === "typeset") && a.length && a.every((x) => /^-[A-Za-z]+$/.test(x)) && a.some((x) => /[xp]/.test(x)))
		add(acc, "secrets", `${c} (prints environment)`);
	if (c === "cmdkey") add(acc, "secrets", "cmdkey");

	// ---- system / persistent
	if (c === "runas") add(acc, "system", "runas (elevation)");
	if (c === "reg" && ["add", "delete", "import", "copy", "load", "unload", "restore"].includes(sub)) add(acc, "system", `reg ${sub}`);
	if (
		["set-itemproperty", "sp", "new-itemproperty", "remove-itemproperty", "rp", "new-item", "ni", "remove-item", "ri", "set-item", "si", "rename-itemproperty", "copy-itemproperty", "move-itemproperty"].includes(c) &&
		/\b(HKCU|HKLM|HKCR|HKU|HKCC|HKEY_[A-Z_]+)\b|Registry::/i.test(seg.text)
	)
		add(acc, "system", "registry write");
	if (c === "schtasks" && al.some((x) => /^[/-](create|change|delete)$/.test(x))) add(acc, "system", "schtasks create/change/delete");
	if (c === "sc" && ["create", "config", "delete", "failure", "sdset"].includes(sub)) add(acc, "system", `sc ${sub}`);
	if (c === "setx") add(acc, "system", "setx (persistent env var)");
	if (c === "bcdedit") add(acc, "system", "bcdedit");
	if (c === "netsh" && al.some((x) => ["add", "set", "delete"].includes(x))) add(acc, "system", "netsh change");

	// ---- config / profile writes through the shell (reads stay allowed)
	const unq = seg.text.replace(/'[^']*'|"(?:\\.|[^"\\])*"/g, "''");
	const redirect = /(^|[^0-9&<>])>{1,2}(?!&)/.test(unq);
	const writing = redirect || !(READ_ONLY.has(c) || (c === "git" && GIT_READ.has(sub)) || (c === "sed" && !al.some((x) => /^-[a-z]*i/.test(x) || x.startsWith("--in-place"))));
	if (writing && /\.pi[/\\]+agent|[/\\]agent[/\\]+extensions[/\\]/i.test(seg.text)) add(acc, "config", "modify Pi config via shell");
	if (writing && /\.bashrc|\.bash_profile|\.zshrc|\.zprofile|(^|[\s/\\~'"])\.profile\b|\$PROFILE\b|profile\.ps1/i.test(seg.text))
		add(acc, "system", "modify shell/PowerShell profile");

	return { c, a };
}

function analyze(src: string, flavor: Flavor, depth: number, acc: Acc, fullText: string): void {
	if (!src || !src.trim()) return;
	if (depth > MAX_DEPTH) {
		add(acc, "system", "command nested too deeply to check");
		return;
	}
	textRules(src, acc);
	let text = src;
	const extra: Array<[string, Flavor]> = [];
	if (flavor === "bash") {
		const h = extractHeredocs(src);
		text = h.text;
		for (const b of h.bodies) extra.push([b, "bash"]);
	}
	const nested: string[] = [];
	const segs = splitSegments(text, flavor, nested);
	for (const n of nested) extra.push([n, flavor]);
	const info = segs.map((s) => segmentRules(s, flavor, depth, acc, fullText));
	// pipeline pass: downloader | interpreter reading code from stdin; recursive listing | Remove-Item
	for (let i = 0; i < segs.length; i++) {
		const { c, a } = info[i];
		const earlier = info.filter((_x, j) => j < i && segs[j].group === segs[i].group);
		const readsStdin =
			c === "iex" || c === "invoke-expression" || (STDIN_INTERPRETERS.has(c) && (positionals(a).length === 0 || a.includes("-") || a.includes("-s")));
		if (segs[i].piped && readsStdin && earlier.some((x) => DOWNLOADERS.has(x.c))) add(acc, "network", "download | exec");
		// Get-ChildItem -Recurse | Remove-Item  /  ... | ForEach-Object { Remove-Item $_ }
		if (["remove-item", "ri", "rm", "del", "erase"].includes(c) && segs.some((s, j) => j < i && s.group === segs[i].group && /\s-r(e(c(u(r(s(e)?)?)?)?)?)?\b/i.test(s.text)))
			add(acc, "destructive", "recursive listing | Remove-Item");
	}
	for (const [t, f] of extra) analyze(t, f, depth + 1, acc, fullText);
}

/** Classify a shell command. `flavor` = syntax of the outer shell (bash tool = Git Bash). */
export function analyzeCommand(src: string, flavor: Flavor = "bash"): Hit[] {
	const acc: Acc = new Map();
	analyze(src, flavor, 0, acc, src);
	return [...acc.values()];
}

// ---------------------------------------------------------------- paths (write/edit/read tools)

/** Same normalisation as Pi's resolveToCwd (strip @, Git Bash /c/..., ~, file://), then resolve. */
export function resolveToolPath(p: string, cwd: string, home: string = homedir()): string {
	let s = p.replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, " ");
	if (s.startsWith("@")) s = s.slice(1);
	if (process.platform === "win32" && s.startsWith("/") && !s.startsWith("//") && !s.includes("\\")) {
		const m = s.match(/^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/(.*))?$/i);
		if (m) s = `${m[1].toUpperCase()}:\\${(m[2] ?? "").split("/").join("\\")}`;
	}
	if (s === "~") s = home;
	else if (s.startsWith("~/") || s.startsWith("~\\")) s = nodePath.join(home, s.slice(2));
	if (/^file:\/\//.test(s)) {
		try {
			s = fileURLToPath(s);
		} catch {
			/* keep */
		}
	}
	return nodePath.resolve(cwd, s);
}

/** Follow symlinks/junctions of the longest existing ancestor. */
function realish(p: string): string {
	let cur = p;
	const tail: string[] = [];
	for (let k = 0; k < 128; k++) {
		try {
			const r = realpathSync(cur);
			return tail.length ? nodePath.join(r, ...tail.reverse()) : r;
		} catch {
			/* go up */
		}
		const parent = nodePath.dirname(cur);
		if (parent === cur) return p;
		tail.push(nodePath.basename(cur));
		cur = parent;
	}
	return p;
}

function norm(p: string): string {
	const s = p.split("\\").join("/");
	return process.platform === "win32" ? s.toLowerCase() : s;
}

export function classifyPath(p: string, cwd: string, mode: "write" | "read", home: string = homedir()): Hit[] {
	const acc: Acc = new Map();
	if (!p) return [];
	const abs = realish(resolveToolPath(p, cwd, home));
	const lc = norm(abs);
	const base = nodePath.basename(abs).toLowerCase();
	if (
		/(^|\/)\.ssh(\/|$)/.test(lc) || /^id_(rsa|dsa|ecdsa|ed25519)/.test(base) || base === "known_hosts" ||
		base === "authorized_keys" || base === ".git-credentials" || base === ".netrc" || /(^|\/)\.aws\/credentials$/.test(lc) ||
		/\/\.pi\/agent\/auth\.json$/.test(lc)
	)
		add(acc, "secrets", "secret file");
	if (mode === "write") {
		if (/^\.env(\.|$)/.test(base)) add(acc, "secrets", ".env file");
		if (/^(microsoft\.[a-z]+_)?profile\.ps1$/.test(base) || (/\/documents\/(windows)?powershell\//.test(lc) && base.endsWith(".ps1")))
			add(acc, "system", "PowerShell profile");
		if (/\/start menu\/programs\/startup(\/|$)/.test(lc)) add(acc, "system", "Startup folder");
		if ([".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".zshrc", ".zprofile", ".zshenv", ".gitconfig"].includes(base))
			add(acc, "system", "shell rc / global git config");
		if (/(^|\/)\.git\/(hooks\/|config$)/.test(lc)) add(acc, "system", "git hooks/config");
		if (/(^|\/)\.pi(\/|$)/.test(lc)) add(acc, "config", "Pi config (.pi/)");
		const root = norm(realish(nodePath.resolve(cwd))).replace(/\/+$/, "");
		if (lc !== root && !lc.startsWith(`${root}/`)) add(acc, "outside-cwd", `outside cwd: ${nodePath.dirname(abs)}`);
	}
	return [...acc.values()];
}

// ---------------------------------------------------------------- decision helpers

export function isGateOff(v: string | undefined): boolean {
	return /^(off|0|false|no|disabled?)$/i.test((v ?? "").trim());
}

/** Mask anything that looks like a credential before it is written to gate.log. */
export function redact(s: string): string {
	let r = s;
	r = r.replace(/\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{6,}/gi, "$1 ***");
	r = r.replace(/\b(ctx7sk|sk|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|glpat|hf|xox[abprs])[-_][A-Za-z0-9_-]{6,}/g, "***");
	r = r.replace(/\bAIza[0-9A-Za-z_-]{20,}/g, "***");
	r = r.replace(
		/((?:api[_-]?key|apikey|token|secret|passw(?:or)?d|auth[a-z_]*|credential[a-z_]*)["']?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"',;&|]+)/gi,
		"$1***",
	);
	r = r.replace(/(--?(?:password|passwd|pass|token|secret|api-key|apikey)(?:=|\s+))("[^"]*"|'[^']*'|\S+)/gi, "$1***");
	r = r.replace(/(:\/\/[^/\s:@]+:)[^@\s/]+@/g, "$1***@");
	if (/\b(mysql|mariadb|mysqldump|mysqladmin)\b/i.test(r)) r = r.replace(/(\s-p)\S+/g, "$1***");
	r = r.replace(/[A-Za-z0-9+_=-]{40,}/g, "***");
	return r;
}

export function summarize(s: string, max = 200): string {
	const r = redact(s).replace(/\s+/g, " ").trim();
	return r.length > max ? `${r.slice(0, max - 3)}...` : r;
}

/** What the gate thinks of one tool call (pure; used by the handler and by the unit tests). */
export function checkToolCall(toolName: string, input: Record<string, unknown>, cwd: string): { hits: Hit[]; summary: string } {
	const str = (v: unknown) => (typeof v === "string" ? v : "");
	if (toolName === "bash" || toolName === "powershell") {
		const cmd = str(input.command);
		return { hits: analyzeCommand(cmd, toolName === "powershell" ? "ps" : "bash"), summary: cmd };
	}
	if (toolName === "write" || toolName === "edit") {
		const p = str(input.path);
		return { hits: classifyPath(p, cwd, "write"), summary: `${toolName} ${p}` };
	}
	if (["read", "grep", "find", "ls"].includes(toolName)) {
		const p = str(input.path);
		return { hits: p ? classifyPath(p, cwd, "read") : [], summary: `${toolName} ${p}` };
	}
	return { hits: [], summary: "" };
}

function localIso(d: Date = new Date()): string {
	const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
	const off = -d.getTimezoneOffset();
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${off >= 0 ? "+" : "-"}${pad(off / 60)}:${pad(off % 60)}`;
}

function writeLog(fields: string[]): void {
	try {
		const file = process.env.PI_GATE_LOG || nodePath.join(homedir(), ".pi", "agent", "gate.log");
		mkdirSync(nodePath.dirname(file), { recursive: true });
		appendFileSync(file, `${fields.map((x) => x.replace(/[\t\r\n]+/g, " ")).join("\t")}\n`, "utf8");
	} catch {
		/* logging must never break a tool call */
	}
}

const OPT_DENY = "Deny";
const OPT_ONCE = "Allow once";
const OPT_SESSION = "Allow this pattern for this session";
const LABEL: Record<string, string> = {
	network: "network/remote",
	destructive: "destructive",
	database: "database",
	secrets: "secrets",
	system: "system/persistent",
	config: "Pi config",
	"outside-cwd": "outside the working folder",
};

// The parts of Pi's tool_call event and context this gate reads.
interface ToolCallEvent {
	toolName: string;
	input?: Record<string, unknown>;
}
interface GateContext {
	cwd?: string;
	mode?: string;
	hasUI?: boolean;
	ui: { select(title: string, options: string[]): Promise<string | undefined> };
}

export default function permissionGate(pi: ExtensionAPI) {
	if (isGateOff(process.env.PI_GATE)) {
		pi.on("session_start", async () => {
			writeLog([localIso(), "gate-off", "-", "-", "-", `PI_GATE=${process.env.PI_GATE}`]);
		});
		return;
	}
	const allowed = new Set<string>();
	let queue: Promise<unknown> = Promise.resolve();
	pi.on("session_start", async () => {
		allowed.clear();
	});
	pi.on("tool_call", async (event: ToolCallEvent, ctx: GateContext) => {
		const { hits, summary } = checkToolCall(String(event.toolName), (event.input ?? {}) as Record<string, unknown>, ctx?.cwd ?? process.cwd());
		if (!hits.length) return undefined;
		const cats = [...new Set(hits.map((h) => h.category))].join(",");
		const desc = hits.map((h) => `${h.category}: ${h.rule}`).join("; ");
		const keys = hits.map(hitKey);
		const mode = ctx?.hasUI ? String(ctx?.mode ?? "ui") : "noui";
		const line = (decision: string) => writeLog([localIso(), decision, mode, String(event.toolName), cats, summarize(summary)]);
		if (keys.every((k) => allowed.has(k))) {
			line("allow-session");
			return undefined;
		}
		if (!ctx?.hasUI) {
			line("block-noui");
			return {
				block: true,
				reason:
					`Blocked by the permission gate (non-interactive run, nobody can approve it): ${desc}. ` +
					"Do not retry it and do not work around it with another command or tool. Tell the user exactly what " +
					"you wanted to run and why, and ask them to run it themselves or to approve it in an interactive pi session.",
			};
		}
		const shown = summary.length > 1500 ? `${summary.slice(0, 1500)} ...` : summary;
		const title =
			`Permission gate: approval needed\nCategory: ${hits.map((h) => `${LABEL[h.category] ?? h.category} (${h.rule})`).join(", ")}\n` +
			`Tool: ${event.toolName}\n\n${shown}\n`;
		const ask = () => ctx.ui.select(title, [OPT_DENY, OPT_ONCE, OPT_SESSION]);
		const pending = queue.then(ask, ask);
		queue = pending.catch(() => undefined);
		let choice: string | undefined;
		try {
			choice = (await pending) as string | undefined;
		} catch {
			choice = undefined;
		}
		if (choice === OPT_ONCE || choice === OPT_SESSION) {
			if (choice === OPT_SESSION) for (const k of keys) allowed.add(k);
			line(choice === OPT_ONCE ? "allow-once" : "allow-pattern");
			return undefined;
		}
		line("deny-user");
		return {
			block: true,
			reason: `Denied by the user (permission gate): ${desc}. Do not retry it or work around it with another command or tool; ask the user how to proceed.`,
		};
	});
}
