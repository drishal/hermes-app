.pragma library

// Composer slash commands, modelled on hermes-webui's client-side command
// registry: a `/cmd args` line typed in the composer is intercepted and run
// locally (no round-trip to the agent) instead of being sent as a message.
//
// This module is the single source of truth for command names/aliases/
// descriptions — used by the autocomplete dropdown and `/help`. The side
// effects themselves run in ChatArea.qml (they need hermesService + UI
// signals), dispatched on the canonical `name` returned by parse().

var COMMANDS = [
    { name: "help",     desc: "List the available slash commands" },
    { name: "new",      desc: "Start a fresh conversation", aliases: ["reset", "clear"] },
    { name: "stop",     desc: "Stop the active run" },
    { name: "retry",    desc: "Resend the last user message" },
    { name: "model",    desc: "Show the model, or switch it", arg: "[name]" },
    { name: "history",  desc: "Search past sessions", aliases: ["sessions"] },
    { name: "settings", desc: "Open settings" },
];

function _canonical(name) {
    name = String(name || "").toLowerCase();
    for (var i = 0; i < COMMANDS.length; i++) {
        var c = COMMANDS[i];
        if (c.name === name) return c.name;
        if (c.aliases && c.aliases.indexOf(name) !== -1) return c.name;
    }
    return "";
}

// Parse a fully-typed command line. Returns {name, args} for a recognised
// command, else null (so the text is sent as a normal message). Only a
// single leading-slash token on its own line counts — a stray "/" mid-message
// or a multi-line paste is never swallowed.
function parse(text) {
    var s = String(text || "");
    if (s.charAt(0) !== "/") return null;
    var m = s.match(/^\/([a-zA-Z]+)(?:[ \t]+([^\n]*))?$/);
    if (!m) return null;
    var canonical = _canonical(m[1]);
    if (!canonical) return null;
    return { name: canonical, args: (m[2] || "").trim() };
}

// Live suggestions for the dropdown while typing the command word (before the
// first space). Matches by name prefix; "/" alone lists everything.
function suggest(text) {
    var s = String(text || "");
    var m = s.match(/^\/([a-zA-Z]*)$/);
    if (!m) return [];
    var q = m[1].toLowerCase();
    var out = [];
    for (var i = 0; i < COMMANDS.length; i++) {
        if (COMMANDS[i].name.indexOf(q) === 0) out.push(COMMANDS[i]);
    }
    return out;
}

function helpText() {
    var lines = ["Slash commands:"];
    for (var i = 0; i < COMMANDS.length; i++) {
        var c = COMMANDS[i];
        var usage = "/" + c.name + (c.arg ? " " + c.arg : "");
        var al = (c.aliases && c.aliases.length)
            ? "  (also " + c.aliases.map(function (a) { return "/" + a; }).join(", ") + ")"
            : "";
        lines.push("  " + usage + " — " + c.desc + al);
    }
    return lines.join("\n");
}
