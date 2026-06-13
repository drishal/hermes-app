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
    if (t === "web_search" || t === "web_search_results" || t === "search_web" || t === "mcp_argus_search_web") return "travel_explore"
    if (t === "web_extract" || t === "web_fetch" || t === "fetch" || t === "http" || t === "url" || t === "curl" || t === "mcp_argus_extract_content") return "language"
    if (t === "delete" || t === "rm" || t === "remove") return "delete"
    if (t === "move" || t === "mv" || t === "rename") return "drive_file_move"
    if (t === "todo" || t === "task" || t === "plan") return "checklist"
    if (t === "delegate" || t === "delegate_task") return "account_tree"
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
        || t === "search_web" || t === "mcp_argus_search_web") return "Searched the web"
    if (t === "web" || t === "web_fetch" || t === "fetch" || t === "fetch_url"
        || t === "web_extract" || t === "mcp_argus_extract_content") return "Read webpage"
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
        && t !== "search_web" && t !== "mcp_argus_search_web") return false
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

// ── Structured content rendering ────────────────────────────────
// Instead of always dumping raw JSON via JsonView, these helpers
// classify tool content and return a structured object that QML can
// render with dedicated components (code blocks, diff views, etc.).
//
// classifyResultContent returns:
//   { type: "code"|"diff"|"text"|"json", ... }
//
// type "code" — terminal output or file content:
//   { type: "code", language: string, body: string, meta: string }
//   meta is e.g. "exit code: 0" or "512 lines"
//
// type "diff" — patch/edit result:
//   { type: "diff", path: string, body: string, added: int, removed: int }
//
// type "text" — plain text (search results, etc.):
//   { type: "text", body: string }
//
// type "json" — fallback, use JsonView tree:
//   { type: "json" }

function _isTerminalTool(tool) {
    const t = String(tool || "").toLowerCase()
    return t === "terminal" || t === "bash" || t === "shell" || t === "run" || t === "exec"
}
function _isPatchTool(tool) {
    const t = String(tool || "").toLowerCase()
    return t === "patch" || t === "edit" || t === "str_replace" || t === "replace"
}
function _isReadTool(tool) {
    const t = String(tool || "").toLowerCase()
    return t === "read" || t === "read_file" || t === "view" || t === "cat"
}
function _isWriteTool(tool) {
    const t = String(tool || "").toLowerCase()
    return t === "write" || t === "write_file" || t === "create_file" || t === "create"
}
function _isSearchTool(tool) {
    const t = String(tool || "").toLowerCase()
    return t === "search" || t === "grep" || t === "find" || t === "ripgrep" || t === "rg"
        || t === "search_files" || t === "glob"
}

function classifyResultContent(tool, rawContent) {
    if (!rawContent) return { type: "json" }
    const s = String(rawContent)

    // ── Terminal output ──────────────────────────────────────
    if (_isTerminalTool(tool)) {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            const output = String(obj.output || obj.stdout || "")
            const stderr = obj.stderr ? String(obj.stderr) : ""
            const exitCode = obj.exit_code !== undefined ? obj.exit_code : obj.exitCode
            const body = output + (stderr ? "\n" + stderr : "")
            const meta = exitCode !== undefined ? ("exit code: " + exitCode) : ""
            if (body.trim()) return { type: "code", language: "bash", body: body, meta: meta }
        }
        // If it's not structured JSON, it's probably raw output.
        if (s.trim()) return { type: "code", language: "bash", body: s, meta: "" }
        return { type: "json" }
    }

    // ── Patch / edit result ──────────────────────────────────
    if (_isPatchTool(tool)) {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            if (obj.diff) {
                const lines = String(obj.diff).split("\n")
                let added = 0, removed = 0
                for (const ln of lines) {
                    if (ln.startsWith("+") && !ln.startsWith("+++")) added++
                    else if (ln.startsWith("-") && !ln.startsWith("---")) removed++
                }
                const path = obj.path || obj.file || obj.file_path || ""
                return { type: "diff", path: String(path), body: String(obj.diff),
                         added: added, removed: removed }
            }
            // No diff but has path — just show success/failure.
            if (obj.path || obj.file || obj.file_path) {
                const path = obj.path || obj.file || obj.file_path
                const detail = obj.success === false ? "failed" : "ok"
                return { type: "text", body: _shortenPath(String(path)) + " — " + detail }
            }
        }
        return { type: "json" }
    }

    // ── Read file result ─────────────────────────────────────
    if (_isReadTool(tool)) {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            const content = obj.content !== undefined ? String(obj.content) : ""
            const path = obj.path || obj.file || obj.file_path || ""
            const totalLines = obj.total_lines || obj.lines || 0
            const meta = (path ? _shortenPath(String(path)) : "")
                       + (totalLines ? (" — " + totalLines + " lines") : "")
            if (content) return { type: "code", language: "", body: content, meta: meta }
        }
        return { type: "json" }
    }

    // ── Write file result ────────────────────────────────────
    if (_isWriteTool(tool)) {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            const path = obj.path || obj.file || obj.file_path || ""
            if (path) {
                const detail = obj.success === false ? " — failed" : ""
                return { type: "text", body: "Wrote " + _shortenPath(String(path)) + detail }
            }
        }
        return { type: "json" }
    }

    // ── Search / grep result ─────────────────────────────────
    if (_isSearchTool(tool)) {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            // If there's a matches array with file paths, show as a file list.
            const items = obj.matches || obj.files || obj.results
            if (Array.isArray(items) && items.length > 0) {
                const lines = items.slice(0, 30).map(function(m) {
                    if (typeof m === "string") return m
                    return m.path || m.file || m.name || m.url || JSON.stringify(m)
                })
                if (items.length > 30) lines.push("… and " + (items.length - 30) + " more")
                return { type: "code", language: "", body: lines.join("\n"),
                         meta: items.length + " match" + (items.length === 1 ? "" : "es") }
            }
        }
        return { type: "json" }
    }

    // ── Delegate task result ─────────────────────────────────
    if (t === "delegate_task" || t === "delegate") {
        let obj = null
        try { obj = JSON.parse(s) } catch (e) {}
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
            // The result often has a "summary" or "result" field with the
            // subagent's final output, plus metadata like duration.
            const summary = obj.summary || obj.result || obj.output || ""
            const status = obj.status || ""
            if (summary) {
                const meta = status ? status : ""
                return { type: "code", language: "", body: String(summary), meta: meta }
            }
        }
        // If it's plain text (not JSON), show it directly.
        if (s.trim() && s.charAt(0) !== "{" && s.charAt(0) !== "[") {
            return { type: "text", body: _truncate(s, 400) }
        }
        return { type: "json" }
    }

    // ── Fallback ─────────────────────────────────────────────
    // If the content isn't JSON, show it as text instead of feeding
    // garbage to JsonView (which renders nothing for non-JSON input).
    if (s.trim() && s.charAt(0) !== "{" && s.charAt(0) !== "[") {
        return { type: "text", body: _truncate(s, 400) }
    }
    return { type: "json" }
}

// ── Structured tool-call argument rendering ─────────────────────
// Returns { type: "kv"|"code"|"json", fields: [...], body: string }
// type "kv" — key-value pairs: { fields: [{ key, value, highlight }] }
// type "code" — code block: { body: string, language: string }
// type "json" — fallback to JsonView

function classifyCallContent(tool, rawArgs) {
    if (!rawArgs) return { type: "json" }
    const args = _parseArgs(rawArgs)
    if (!args) {
        // The ACP run path sends a pre-formatted, human-readable preview string
        // — markdown prose, fenced code blocks ("```python\n…```"), headings —
        // rather than a JSON args dict. Feeding that to the JsonView tree renders
        // an empty body, and a bare text line collapses newlines/fences. Render
        // it as markdown so code fences and line breaks survive; keep raw shell
        // output ("$ …\n<output>") as a verbatim code block.
        const s = String(rawArgs).trim()
        if (!s) return { type: "json" }
        if (/^\$ /.test(s)) return { type: "code", language: "bash", body: s }
        return { type: "markdown", body: s }
    }
    const t = String(tool || "").toLowerCase()

    // Terminal: show the command prominently.
    if (_isTerminalTool(tool)) {
        const cmd = args.command || args.cmd || args.script || args.input || ""
        if (cmd) return { type: "code", language: "bash", body: String(cmd) }
    }

    // Patch: show path + mode, with old/new as separate code blocks is too
    // complex — use a key-value layout for the main fields.
    if (_isPatchTool(tool)) {
        const path = args.path || args.file || args.file_path || ""
        const mode = args.mode || (args.old_string !== undefined ? "replace" : "")
        const fields = []
        if (path) fields.push({ key: "path", value: _shortenPath(String(path)), highlight: true })
        if (mode) fields.push({ key: "mode", value: String(mode), highlight: false })
        if (args.old_string !== undefined) {
            const oldS = _collapseWs(String(args.old_string))
            fields.push({ key: "old", value: _truncate(oldS, 120), highlight: false })
        }
        if (args.new_string !== undefined) {
            const newS = _collapseWs(String(args.new_string))
            fields.push({ key: "new", value: _truncate(newS, 120), highlight: false })
        }
        if (fields.length > 0) return { type: "kv", fields: fields }
    }

    // Read/write: show the path.
    if (_isReadTool(tool) || _isWriteTool(tool)) {
        const path = args.path || args.file || args.file_path || ""
        const fields = []
        if (path) fields.push({ key: "path", value: _shortenPath(String(path)), highlight: true })
        if (args.offset) fields.push({ key: "offset", value: String(args.offset), highlight: false })
        if (args.limit) fields.push({ key: "limit", value: String(args.limit), highlight: false })
        if (fields.length > 0) return { type: "kv", fields: fields }
    }

    // Web search: show the query.
    if (t === "web_search" || t === "web_search_results" || t === "search_web" || t === "mcp_argus_search_web") {
        const query = args.query || args.q || ""
        if (query) return { type: "code", language: "", body: String(query) }
    }

    // Search/grep: show the pattern.
    if (_isSearchTool(tool)) {
        const pattern = args.query || args.pattern || args.q || args.regex || args.glob || ""
        const path = args.path ? " in " + _shortenPath(String(args.path)) : ""
        if (pattern) return { type: "code", language: "", body: String(pattern) + path }
    }

    // Delegate task: show the goal and context.
    if (t === "delegate_task" || t === "delegate") {
        const fields = []
        const goal = args.goal || args.task || ""
        const ctx = args.context || ""
        const tasks = args.tasks
        if (goal) fields.push({ key: "goal", value: _truncate(String(goal), 200), highlight: true })
        if (ctx) fields.push({ key: "context", value: _truncate(String(ctx), 120), highlight: false })
        if (Array.isArray(tasks) && tasks.length > 0) {
            const summaries = tasks.slice(0, 3).map(function(task, i) {
                const tGoal = task.goal || task.task || ""
                return (i + 1) + ". " + _truncate(tGoal, 60)
            })
            if (tasks.length > 3) summaries.push("… and " + (tasks.length - 3) + " more")
            fields.push({ key: "tasks", value: summaries.join("\n"), highlight: false })
        }
        const toolsets = args.toolsets || args.enabled_toolsets
        if (Array.isArray(toolsets) && toolsets.length > 0) {
            fields.push({ key: "toolsets", value: toolsets.join(", "), highlight: false })
        }
        if (fields.length > 0) return { type: "kv", fields: fields }
    }

    // Generic: build key-value pairs from scalar fields.
    const fields = []
    const scalarKeys = ["path", "file", "file_path", "url", "uri", "query", "pattern",
                        "command", "input", "name", "title", "message", "text", "mode",
                        "offset", "limit", "language", "goal", "context", "task"]
    for (const k of scalarKeys) {
        if (args[k] !== undefined && args[k] !== null && args[k] !== "") {
            const v = String(args[k])
            fields.push({
                key: k,
                value: (k === "path" || k === "file" || k === "file_path" || k === "url")
                    ? _truncate(v, 80) : _truncate(v, 120),
                highlight: (k === "path" || k === "file" || k === "file_path" || k === "url" || k === "command")
            })
        }
    }
    if (fields.length > 0) return { type: "kv", fields: fields }

    // If we couldn't classify the content but the raw args string isn't
    // valid JSON, show it as plain text rather than feeding garbage to
    // JsonView (which renders nothing for non-JSON input).
    const rawS = String(rawArgs).trim()
    if (rawS) {
        // Quick check: does it look like JSON?
        if (rawS.charAt(0) !== "{" && rawS.charAt(0) !== "[") {
            return { type: "text", body: _truncate(rawS, 400) }
        }
    }

    return { type: "json" }
}
