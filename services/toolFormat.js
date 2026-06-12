.pragma library

// Helpers for turning raw tool-call args / tool-result JSON into a single-line
// pretty preview. Used by ChatArea.qml's tool_call and tool_result delegates so
// the chat doesn't show big blobs of `{"mode":"replace","new_string":"..."}`.

function _parseArgs(raw) {
    if (raw === undefined || raw === null) return null
    if (typeof raw === "object") return raw
    const s = String(raw).trim()
    if (!s) return null
    try { return JSON.parse(s) } catch (e) { return null }
}

function _collapseWs(s) {
    return String(s || "").replace(/\s+/g, " ").trim()
}

function _truncate(s, n) {
    s = _collapseWs(s)
    return s.length > n ? s.substring(0, n - 1) + "…" : s
}

function _basename(p) {
    if (!p) return ""
    const s = String(p)
    const i = s.lastIndexOf("/")
    return i >= 0 ? s.substring(i + 1) || s : s
}

function _shortenPath(p) {
    if (!p) return ""
    const s = String(p).replace(/^\/home\/[^/]+/, "~")
    if (s.length <= 48) return s
    const parts = s.split("/")
    if (parts.length <= 3) return s
    return parts.slice(0, 1).concat(["…"], parts.slice(-2)).join("/")
}

function iconFor(tool) {
    const t = String(tool || "").toLowerCase()
    if (t === "patch" || t === "edit" || t === "replace" || t === "str_replace") return "edit"
    if (t === "write" || t === "write_file" || t === "create_file" || t === "create") return "note_add"
    if (t === "read" || t === "read_file" || t === "view" || t === "cat") return "description"
    if (t === "terminal" || t === "bash" || t === "shell" || t === "run" || t === "exec") return "terminal"
    if (t === "search" || t === "grep" || t === "find" || t === "ripgrep" || t === "rg") return "search"
    if (t === "ls" || t === "list" || t === "list_directory" || t === "tree") return "folder_open"
    if (t === "glob") return "filter_alt"
    if (t === "fetch" || t === "web_fetch" || t === "http" || t === "url" || t === "curl") return "language"
    if (t === "delete" || t === "rm" || t === "remove") return "delete"
    if (t === "move" || t === "mv" || t === "rename") return "drive_file_move"
    if (t === "todo" || t === "task" || t === "plan") return "checklist"
    return "build"
}

// Returns { hint: string, detail: string }
//   hint   — short verb-ish badge ("replace", "$", "GET")
//   detail — main descriptor (file path, command, query)
function summarize(tool, rawArgs) {
    const t = String(tool || "").toLowerCase()
    const args = _parseArgs(rawArgs)

    if (!args) {
        return { hint: "", detail: _truncate(rawArgs, 80) }
    }

    if (t === "patch" || t === "edit" || t === "replace" || t === "str_replace") {
        const path = args.path || args.file || args.filename || args.file_path || ""
        const mode = args.mode || (args.old_string !== undefined ? "replace" : "")
        if (path) return { hint: mode || "patch", detail: _shortenPath(path) }
        const snip = args.new_string || args.old_string || args.diff || ""
        return { hint: mode || "patch", detail: _truncate(snip, 60) }
    }
    if (t === "write" || t === "write_file" || t === "create_file" || t === "create") {
        return { hint: "write", detail: _shortenPath(args.path || args.file || args.file_path || "") }
    }
    if (t === "read" || t === "read_file" || t === "view" || t === "cat") {
        const path = args.path || args.file || args.file_path || ""
        const range = (args.offset || args.start_line) ? (" :" + (args.offset || args.start_line)) : ""
        return { hint: "read", detail: _shortenPath(path) + range }
    }
    if (t === "terminal" || t === "bash" || t === "shell" || t === "run" || t === "exec") {
        const cmd = args.command || args.cmd || args.script || args.input || ""
        return { hint: "$", detail: _truncate(cmd, 90) }
    }
    if (t === "search" || t === "grep" || t === "find" || t === "ripgrep" || t === "rg") {
        const q = args.query || args.pattern || args.q || args.regex || ""
        const where = args.path ? "  in " + _shortenPath(args.path) : ""
        return { hint: "find", detail: _truncate(q + where, 80) }
    }
    if (t === "glob") {
        return { hint: "glob", detail: _truncate(args.pattern || args.glob || "", 80) }
    }
    if (t === "ls" || t === "list" || t === "list_directory" || t === "tree") {
        return { hint: "ls", detail: _shortenPath(args.path || ".") }
    }
    if (t === "fetch" || t === "web_fetch" || t === "http" || t === "url" || t === "curl") {
        return { hint: args.method || "GET", detail: _truncate(args.url || args.uri || "", 80) }
    }
    if (t === "delete" || t === "rm" || t === "remove") {
        return { hint: "rm", detail: _shortenPath(args.path || args.file || "") }
    }
    if (t === "move" || t === "mv" || t === "rename") {
        return { hint: "mv", detail: _shortenPath(args.from || args.src || "") + " → " + _shortenPath(args.to || args.dst || "") }
    }
    if (t === "todo" || t === "task" || t === "plan") {
        const items = args.items || args.tasks || args.todos
        if (Array.isArray(items)) return { hint: "todo", detail: items.length + " item" + (items.length === 1 ? "" : "s") }
    }

    // Generic fallback — pick the first meaningful field
    const keys = ["path", "file", "file_path", "url", "uri", "query", "pattern", "command", "input", "name", "title", "message", "text"]
    for (const k of keys) {
        if (args[k] !== undefined && args[k] !== null && args[k] !== "") {
            return { hint: "", detail: _truncate(String(args[k]), 80) }
        }
    }
    for (const k in args) {
        const v = args[k]
        if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") {
            return { hint: "", detail: k + ": " + _truncate(String(v), 60) }
        }
    }
    return { hint: "", detail: "" }
}

// Friendly Claude-web-style label for a tool name ("Searched the web",
// "Read file", "Ran a command", …). Falls back to a humanised version of
// the raw tool name for things we haven't enumerated yet.
function labelFor(tool) {
    const t = String(tool || "").toLowerCase()
    if (t === "web_search" || t === "web_search_results"
        || t === "search_web") return "Searched the web"
    if (t === "web" || t === "web_fetch" || t === "fetch" || t === "fetch_url") return "Fetched"
    if (t === "read" || t === "read_file" || t === "view" || t === "cat") return "Read file"
    if (t === "terminal" || t === "bash" || t === "shell" || t === "exec") return "Ran a command"
    if (t === "patch" || t === "edit" || t === "str_replace" || t === "replace") return "Edited file"
    if (t === "write" || t === "write_file" || t === "create_file" || t === "create") return "Wrote file"
    if (t === "delete" || t === "rm" || t === "remove") return "Deleted file"
    if (t === "move" || t === "mv" || t === "rename") return "Moved file"
    if (t === "ls" || t === "list" || t === "list_directory" || t === "tree") return "Listed directory"
    if (t === "glob") return "Matched files"
    if (t === "grep" || t === "ripgrep" || t === "rg") return "Searched files"
    if (t === "todo" || t === "task" || t === "plan") return "Updated tasks"
    if (t === "image_gen" || t === "image") return "Generated image"
    if (t === "tts" || t === "text_to_speech") return "Generated audio"
    if (t === "vision" || t === "vision_analyze") return "Analyzed image"
    if (t === "delegate" || t === "delegate_task") return "Delegated task"
    if (t === "cron" || t === "cronjob") return "Scheduled job"
    // Fallback: turn `web_search_results` into `Web search results` rather
    // than showing the raw snake_case name.
    if (!t) return "Tool"
    return t.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase())
}

// True if the tool's result body is shaped like a list of web search hits —
// used to swap the JsonView for the Claude-style results list.
function isWebResults(tool, rawContent) {
    const t = String(tool || "").toLowerCase()
    // "Searched the web" tools render as a result list. "Fetched" is a single
    // page — keep the JsonView tree for those so a 50KB HTML blob doesn't
    // blow up the chat.
    if (t !== "web_search" && t !== "web_search_results"
        && t !== "search_web") return false
    const items = _parseResultsArray(rawContent)
    return Array.isArray(items) && items.length > 0
    && items.every(r => r && typeof r === "object" && (r.url || r.title || r.name))
}

// Parse the untrusted_tool_result envelope and pull out the `results` array.
// Mirrors jsonFormat.unwrap (kept inline so toolFormat.js has no module
// dependency — same trick summarizeResult uses). Returns [] on any miss.
function _parseResultsArray(rawContent) {
    if (!rawContent) return []
    let text = String(rawContent)
    // Strip the untrusted envelope opening tag + security preamble.
    const m = text.match(/<untrusted_tool_result(?:\s+source="[^"]*")?\s*>/)
    if (m) {
        text = text.slice(m.index + m[0].length)
        text = text.replace(/<\/untrusted_tool_result>\s*$/, "")
        const brace = text.search(/[{[]/)
        if (brace > 0) {
            const preamble = text.slice(0, brace)
            if (/retrieved from an external source|Treat it as DATA/i.test(preamble))
                text = text.slice(brace)
        }
    }
    text = text.trim()
    let obj = null
    try { obj = JSON.parse(text) } catch (e) {}
    if (!obj) {
        // Fallback: take the largest {...} or [...] slice.
        const first = text.search(/[{[]/)
        const last = Math.max(text.lastIndexOf("}"), text.lastIndexOf("]"))
        if (first >= 0 && last > first) {
            try { obj = JSON.parse(text.slice(first, last + 1)) } catch (e) {}
        }
    }
    if (!obj || typeof obj !== "object") return []
    if (Array.isArray(obj.results)) return obj.results
    if (Array.isArray(obj)) return obj
    return []
}

// Normalise a single web result into { title, url, source, snippet } so the
// QML side can render the same row regardless of which field names the
// upstream provider used.
function normaliseWebResult(r) {
    if (!r || typeof r !== "object") return null
    const title = r.title || r.name || r.headline || ""
    const url = r.url || r.link || r.href || ""
    const snippet = r.snippet || r.description || r.content || r.excerpt || ""
    let source = r.source || r.domain || ""
    if (!source && url) {
        try { source = String(url).replace(/^https?:\/\//, "").split("/")[0] } catch (e) {}
    }
    return { title: String(title), url: String(url),
             source: String(source), snippet: String(snippet) }
}

// Parse web results into a normalised array. Empty array on any miss so
// callers fall back to the JsonView tree.
function parseWebResults(rawContent) {
    return _parseResultsArray(rawContent).map(normaliseWebResult).filter(Boolean)
}

// Result-row header summary. Returns { success: bool, detail: string }
function summarizeResult(tool, rawContent) {
    if (!rawContent) return { success: true, detail: "" }
    const s = String(rawContent)
    let obj = null
    try { obj = JSON.parse(s) } catch (e) {}

    if (obj && typeof obj === "object" && !Array.isArray(obj)) {
        if (obj.error) {
            return { success: false, detail: _truncate(typeof obj.error === "string" ? obj.error : JSON.stringify(obj.error), 80) }
        }
        const success = obj.success !== false
        if (obj.diff) {
            const lines = String(obj.diff).split("\n")
            let added = 0, removed = 0
            for (const ln of lines) {
                if (ln.startsWith("+") && !ln.startsWith("+++")) added++
                else if (ln.startsWith("-") && !ln.startsWith("---")) removed++
            }
            return { success: success, detail: "+" + added + " −" + removed }
        }
        if (obj.output !== undefined && obj.output !== null) {
            const o = String(obj.output)
            const lc = o.split("\n").length
            return { success: success, detail: lc + " line" + (lc === 1 ? "" : "s") }
        }
        if (obj.stdout !== undefined || obj.stderr !== undefined) {
            const out = String(obj.stdout || "") + (obj.stderr ? String(obj.stderr) : "")
            const lc = out.split("\n").filter(Boolean).length
            return { success: success, detail: lc + " line" + (lc === 1 ? "" : "s") }
        }
        if (Array.isArray(obj.results)) {
            return { success: success, detail: obj.results.length + " result" + (obj.results.length === 1 ? "" : "s") }
        }
        if (Array.isArray(obj.matches)) {
            return { success: success, detail: obj.matches.length + " match" + (obj.matches.length === 1 ? "" : "es") }
        }
        if (Array.isArray(obj.files)) {
            return { success: success, detail: obj.files.length + " file" + (obj.files.length === 1 ? "" : "s") }
        }
        if (obj.lines !== undefined) {
            return { success: success, detail: obj.lines + " lines" }
        }
        return { success: success, detail: success ? "ok" : "failed" }
    }

    if (Array.isArray(obj)) {
        return { success: true, detail: obj.length + " item" + (obj.length === 1 ? "" : "s") }
    }

    const lc = s.split("\n").length
    return { success: true, detail: lc + " line" + (lc === 1 ? "" : "s") }
}
