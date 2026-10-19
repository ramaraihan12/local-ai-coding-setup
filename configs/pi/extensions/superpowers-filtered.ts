// superpowers-filtered.ts - runs the official Superpowers Pi extension with deliberate deviations.
//
// Package: git:github.com/obra/superpowers@v7.0.0 (settings.json "packages", its own extension
// disabled there with "extensions": []). The upstream code (.pi/extensions/superpowers.ts) runs
// unchanged; this wrapper only filters which of its event handlers get registered.
//
// Deliberate deviations from upstream:
// 1. `resources_discover` dropped. Upstream registers the package's whole skills/ directory; Pi adds
//    those paths after the package filter and ignores --no-skills for them, so all 15 skills (incl.
//    the sub-agent ones) would load. Now only the skills selected in settings.json load.
// 2. `agent_end` dropped. Upstream stops injecting after the first run; the injection is not stored in
//    the session, so from prompt 2 on the bootstrap vanished from requests: the prefix changed right
//    after the system prompt (llama-server re-prefilled the whole history once per session) and the
//    model lost the skill rules. Now the bootstrap is injected into EVERY request at the same position
//    (start of the conversation, after compaction summaries) -> stable prefix. It never piles up: it is
//    never persisted, and upstream skips injection when a message already contains its marker.
// 3. PI_SUPERPOWERS=0 in the environment (pi-local.ps1 -Lite) -> register nothing (no bootstrap).
//
// Installed as ~/.pi/agent/extensions/superpowers-filtered.ts; the import below is relative to that folder.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import superpowers from "../git/github.com/obra/superpowers/.pi/extensions/superpowers.ts";

const DROPPED = new Set(["resources_discover", "agent_end"]);

export default function superpowersFiltered(pi: ExtensionAPI) {
	if (process.env.PI_SUPERPOWERS === "0") return;
	const api: ExtensionAPI = Object.create(pi);
	api.on = ((event: string, handler: unknown) => {
		if (DROPPED.has(event)) return;
		return (pi.on as (e: string, h: unknown) => void)(event, handler);
	}) as ExtensionAPI["on"];
	return superpowers(api);
}
