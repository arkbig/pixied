#!/usr/bin/env bash
# @brief JSON operations used by self-contained exposure wrappers.

if [ -n "${PIXIED_EXPOSE_JSON_LOADED:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
PIXIED_EXPOSE_JSON_LOADED=1

# @description Validate and query Pixi JSON, or update Docker plugin metadata.
# Reads JSON from stdin except for quote. Parameters are passed through the
# PIXIED_JSON_ENV, PIXIED_JSON_PACKAGE, PIXIED_JSON_COMMAND and
# PIXIED_JSON_VERSION environment variables.
#
# @arg $1 string Operation: validate, version, metadata, or quote.
# @stdout The requested version or JSON, except for validate.
# @stderr A diagnostic when input or metadata is invalid.
# @exitcode 0 When the operation succeeds.
# @exitcode 1 When JSON or requested metadata is invalid.
pixied_expose_json() {
    LC_ALL=C awk -v action="$1" '
    function fail(message) {
        print "pixied exposure: " message > "/dev/stderr"
        exit 1
    }
    function whitespace( c) {
        while (pos <= size) {
            c = substr(doc, pos, 1)
            if (c != " " && c != "\t" && c != "\r" && c != "\n") break
            pos++
        }
    }
    function utf8(n) {
        if (n < 128) return sprintf("%c", n)
        if (n < 2048) return sprintf("%c%c", 192 + int(n / 64), 128 + n % 64)
        if (n < 65536) return sprintf("%c%c%c", 224 + int(n / 4096), 128 + int(n / 64) % 64, 128 + n % 64)
        return sprintf("%c%c%c%c", 240 + int(n / 262144), 128 + int(n / 4096) % 64, 128 + int(n / 64) % 64, 128 + n % 64)
    }
    function hex4( h, n, i, c) {
        h = substr(doc, pos, 4)
        if (length(h) != 4 || h !~ /^[0-9a-fA-F]+$/) fail("invalid JSON Unicode escape")
        n = 0
        h = tolower(h)
        for (i = 1; i <= 4; i++) {
            c = index("0123456789abcdef", substr(h, i, 1)) - 1
            n = n * 16 + c
        }
        pos += 4
        return n
    }
    function string( result, c, esc, n, low) {
        if (substr(doc, pos, 1) != "\"") fail("expected JSON string")
        pos++
        result = ""
        while (pos <= size) {
            c = substr(doc, pos++, 1)
            if (c == "\"") return result
            if (c ~ /[[:cntrl:]]/) fail("unescaped control character in JSON string")
            if (c != "\\") {
                result = result c
                continue
            }
            if (pos > size) fail("incomplete JSON escape")
            esc = substr(doc, pos++, 1)
            if (esc == "\"" || esc == "\\" || esc == "/") result = result esc
            else if (esc == "b") result = result sprintf("%c", 8)
            else if (esc == "f") result = result sprintf("%c", 12)
            else if (esc == "n") result = result "\n"
            else if (esc == "r") result = result "\r"
            else if (esc == "t") result = result "\t"
            else if (esc == "u") {
                n = hex4()
                if (n >= 55296 && n <= 56319) {
                    if (substr(doc, pos, 2) != "\\u") fail("invalid JSON surrogate pair")
                    pos += 2
                    low = hex4()
                    if (low < 56320 || low > 57343) fail("invalid JSON surrogate pair")
                    n = 65536 + (n - 55296) * 1024 + low - 56320
                } else if (n >= 56320 && n <= 57343) fail("invalid JSON surrogate pair")
                result = result utf8(n)
            } else fail("invalid JSON escape")
        }
        fail("unterminated JSON string")
    }
    function record(depth, value, id) {
        if (action != "version" && action != "validate") return
        if (depth == 2 && types[0] == "array" && types[1] == "object" && path[2] == "name")
            env_names[path[1]] = value
        if (depth == 4 && types[0] == "array" && types[1] == "object" &&
            types[2] == "array" && types[3] == "object") {
            id = path[1] SUBSEP path[3]
            if (path[2] == "dependencies") {
                dep_env[id] = path[1]
                if (path[4] == "name") dep_names[id] = value
                if (path[4] == "version") dep_versions[id] = value
            } else if (path[2] == "exposed" && path[4] == "exposed_name" &&
                       value == ENVIRON["PIXIED_JSON_COMMAND"])
                exposed[path[1]] = 1
        }
    }
    function value(depth, key, c, name, id, count, start, token, text) {
        if (depth > 128) fail("JSON nesting limit exceeded")
        path[depth] = key
        whitespace()
        start = pos
        c = substr(doc, pos, 1)
        if (depth == 0) root = c
        if (c == "{") {
            types[depth] = "object"
            id = ++object_id
            count = 0
            pos++
            whitespace()
            if (substr(doc, pos, 1) != "}") {
                while (1) {
                    whitespace()
                    name = string()
                    if ((id SUBSEP name) in seen) fail("duplicate JSON object key")
                    seen[id SUBSEP name] = 1
                    whitespace()
                    if (substr(doc, pos++, 1) != ":") fail("expected JSON colon")
                    whitespace()
                    value(depth + 1, name)
                    count++
                    whitespace()
                    c = substr(doc, pos++, 1)
                    if (c == "}") break
                    if (c != ",") fail("expected JSON object separator")
                }
            } else pos++
            if (depth == 0) {
                root_close = pos - 1
                root_count = count
            }
        } else if (c == "[") {
            types[depth] = "array"
            count = 0
            pos++
            whitespace()
            if (substr(doc, pos, 1) != "]") {
                while (1) {
                    value(depth + 1, count++)
                    whitespace()
                    c = substr(doc, pos++, 1)
                    if (c == "]") break
                    if (c != ",") fail("expected JSON array separator")
                }
            } else pos++
        } else if (c == "\"") {
            text = string()
            record(depth, text)
        } else {
            token = substr(doc, pos)
            if (match(token, /^(true|false|null)/)) pos += RLENGTH
            else if (match(token, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) pos += RLENGTH
            else fail("invalid JSON value")
        }
        if (action == "metadata" && depth == 1 && key == "Version") {
            version_start = start
            version_end = pos - 1
        }
    }
    function quote(text, result, i, c) {
        result = "\""
        for (i = 1; i <= length(text); i++) {
            c = substr(text, i, 1)
            if (c == "\"" || c == "\\") result = result "\\" c
            else if (c in controls) result = result sprintf("\\u%04x", controls[c])
            else result = result c
        }
        return result "\""
    }
    BEGIN {
        for (i = 1; i < 32; i++) controls[sprintf("%c", i)] = i
        if (action == "quote") {
            print quote(ENVIRON["PIXIED_JSON_VERSION"])
            exit
        }
        while ((read_status = getline line) > 0) doc = doc line "\n"
        if (read_status < 0) fail("failed to read JSON")
        size = length(doc)
        pos = 1
        value(0, "")
        whitespace()
        if (pos <= size) fail("trailing data after JSON")
        if (action == "metadata") {
            if (root != "{") fail("invalid Docker plugin metadata")
            replacement = quote(ENVIRON["PIXIED_JSON_VERSION"])
            if (version_start)
                print substr(doc, 1, version_start - 1) replacement substr(doc, version_end + 1)
            else
                print substr(doc, 1, root_close - 1) (root_count ? "," : "") "\"Version\":" replacement substr(doc, root_close)
            exit
        }
        if (action != "version" && action != "validate") fail("invalid JSON operation")
        if (root != "[") fail("invalid Pixi Global metadata")
        matches = 0
        for (id in dep_names) {
            env = dep_env[id]
            if (env_names[env] == ENVIRON["PIXIED_JSON_ENV"] &&
                dep_names[id] == ENVIRON["PIXIED_JSON_PACKAGE"] &&
                dep_versions[id] != "" && dep_versions[id] !~ /[[:cntrl:]]/ &&
                (action != "validate" || exposed[env])) {
                matches++
                result = dep_versions[id]
            }
        }
        if (matches != 1) fail("expected exactly one installed package version")
        if (action == "version") print result
    }
    '
}
