/* Markdown preview pipeline:
   markdown-it (GFM) -> DOMPurify (allowlist) -> relative image rewrite -> morphdom.
   API called by Dart: window.__cockpit.setContent(md, docDir) and window.__cockpit.setTheme(vars). */
(function () {
  "use strict";

  var md = window.markdownit({
    html: true, // raw HTML passed through; filtered by DOMPurify
    linkify: true,
    typographer: false,
  });

  // DOMPurify allowlist
  var SANITIZE = {
    USE_PROFILES: { html: true },
    ADD_TAGS: ["details", "summary"],
    // "checked"/"disabled" preserve GFM task list checkboxes
    ADD_ATTR: ["align", "width", "height", "open", "checked", "disabled"],
    FORBID_TAGS: ["style", "form", "button"],
    ALLOW_UNKNOWN_PROTOCOLS: false,
  };

  function rewriteImages(root, docDir) {
    var imgs = root.querySelectorAll("img");
    for (var i = 0; i < imgs.length; i++) {
      var src = imgs[i].getAttribute("src") || "";
      if (!src || /^[a-z][a-z0-9+.-]*:/i.test(src)) {
        // explicit scheme: only data: survives (CSP blocks the rest)
        continue;
      }
      var abs = src.charAt(0) === "/" ? src : docDir + "/" + src;
      imgs[i].setAttribute("src", "ckp-res://local/" + encodeURIComponent(abs));
    }
  }

  /* YAML frontmatter at top of document (--- ... ---).
     Follows MarkdownFrontmatter.split rules from Flutter core/ui/widgets/markdown_frontmatter.dart */
  function splitFrontmatter(source) {
    var text = source.replace(/\r\n?/g, "\n").replace(/^\uFEFF/, "");
    var lead = /^[ \t\n]*/.exec(text)[0];
    var candidate = text.slice(lead.length);
    if (candidate.slice(0, 3) !== "---") return null;
    var lines = candidate.split("\n");
    if (lines[0].replace(/\s+$/, "") !== "---") return null;
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      var t = lines[i].replace(/\s+$/, "");
      if (t === "---" || t === "...") {
        close = i;
        break;
      }
    }
    if (close < 0) return null;
    var fields = parseFields(lines.slice(1, close));
    if (!fields.length) return null;
    return { fields: fields, body: lines.slice(close + 1).join("\n") };
  }

  /* Parses frontmatter key-value subset. */
  function parseFields(lines) {
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line.trim() || line.trim().charAt(0) === "#") continue;
      if (/^\s/.test(line) && out.length) {
        // Continuation (list item, nested map): append to current key.
        var cont = line.trim().replace(/^-\s*/, "");
        out[out.length - 1].value += out[out.length - 1].value ? ", " + cont : cont;
        continue;
      }
      var sep = line.indexOf(":");
      if (sep < 1) continue;
      out.push({
        key: line.slice(0, sep).trim(),
        value: unquote(line.slice(sep + 1).trim()),
      });
    }
    return out;
  }

  function unquote(v) {
    if (v.length > 1) {
      var f = v.charAt(0);
      if ((f === '"' || f === "'") && v.charAt(v.length - 1) === f) {
        return v.slice(1, -1);
      }
    }
    return v;
  }

  /* Frontmatter key/value table matching MarkdownFrontmatterTable in Flutter. */
  function frontmatterTable(fields) {
    var table = document.createElement("table");
    table.className = "ckp-frontmatter";
    var body = document.createElement("tbody");
    for (var i = 0; i < fields.length; i++) {
      var row = document.createElement("tr");
      var k = document.createElement("th");
      k.textContent = fields[i].key;
      var v = document.createElement("td");
      v.textContent = fields[i].value;
      row.appendChild(k);
      row.appendChild(v);
      body.appendChild(row);
    }
    table.appendChild(body);
    return table;
  }

  function render(markdown, docDir) {
    var front = splitFrontmatter(markdown);
    var html = md.render(front ? front.body : markdown);
    var clean = window.DOMPurify.sanitize(html, SANITIZE);
    var next = document.createElement("div");
    next.id = "content";
    next.innerHTML = clean;
    if (front) next.insertBefore(frontmatterTable(front.fields), next.firstChild);
    rewriteImages(next, docDir);
    var cur = document.getElementById("content");
    // DOM diffing preserves scroll position
    window.morphdom(cur, next);
  }

  window.__cockpit = {
    setContent: function (markdown, docDir) {
      try {
        render(markdown, docDir || "");
      } catch (e) {
        var cur = document.getElementById("content");
        cur.textContent = String((e && e.message) || e);
      }
    },
    setTheme: function (vars) {
      var root = document.documentElement;
      for (var k in vars) {
        if (Object.prototype.hasOwnProperty.call(vars, k)) {
          root.style.setProperty(k, vars[k]);
        }
      }
    },
  };
})();
