#!/usr/bin/env python3
import base64
import mimetypes
import re
import sys
import unicodedata
from html import escape as esc
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = ROOT / "docs" / "manual"
DIST_DIR = ROOT / "dist" / "manual"
DEFAULT_VERSION = "0.1.3"

LANGS = [
    {
        "code": "ja",
        "src": "ja.md",
        "out": "Koedex-Manual-ja.html",
        "html_lang": "ja",
        "missing_image_text": "画像は後日追加されます",
        "version_label": "対象バージョン",
        "version_re": r"\|\s*対象アプリバージョン\s*\|\s*([^|]+?)\s*\|",
    },
    {
        "code": "en",
        "src": "en.md",
        "out": "Koedex-Manual-en.html",
        "html_lang": "en",
        "missing_image_text": "Image will be added soon",
        "version_label": "Target version",
        "version_re": r"\|\s*App version covered\s*\|\s*([^|]+?)\s*\|",
    },
]

HEADING_RE = re.compile(r"^(#{1,4})\s+(.*)$")
FENCE_RE = re.compile(r"^(\s*)```(\S*)\s*$")
LIST_ITEM_RE = re.compile(r"^(\s*)(-|\d+\.)\s+(.*)$")
IMAGE_RE = re.compile(r"^!\[([^\]]*)\]\(([^)]+)\)$")
TABLE_SEP_RE = re.compile(r"^\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?$")
INLINE_RE = re.compile(
    r"`(?P<code>[^`]+)`"
    r"|\[(?P<linktext>[^\]]+)\]\((?P<linkhref>[^)]+)\)"
    r"|\*\*(?P<bold>[^*]+)\*\*"
)

SAFE_LINK_SCHEMES = frozenset({"http", "https", "mailto"})


class ManualBuildError(Exception):
    """A manual source violates the fail-closed build contract."""


def has_control_character(value):
    return any(
        unicodedata.category(character) == "Cc" or character in {"\u2028", "\u2029"}
        for character in value
    )


def safe_link_href(value):
    """Return a safe link target, or None when it must not become an anchor."""
    if not value or value != value.strip() or has_control_character(value):
        return None
    if value.startswith("#"):
        return value

    parsed = urlsplit(value)
    scheme = parsed.scheme.casefold()
    if scheme in SAFE_LINK_SCHEMES and scheme != "mailto" and parsed.netloc:
        return value
    if scheme == "mailto" and parsed.path:
        return value
    return None


def safe_manual_image_path(src):
    """Resolve a manual image only when it remains inside docs/manual/images."""
    if not src or has_control_character(src) or src.startswith("/") or "\\" in src:
        raise ManualBuildError("unsafe manual image reference")

    relative = PurePosixPath(src)
    if (
        relative.is_absolute()
        or not relative.parts
        or relative.parts[0] != "images"
        or any(part in {".", ".."} for part in relative.parts)
    ):
        raise ManualBuildError("unsafe manual image reference")

    raw_candidate = DOCS_DIR.joinpath(*relative.parts)
    component = DOCS_DIR
    for part in relative.parts:
        component = component / part
        if component.is_symlink():
            raise ManualBuildError("unsafe manual image reference")

    image_root = (DOCS_DIR / "images").resolve()
    candidate = raw_candidate.resolve()
    try:
        candidate.relative_to(image_root)
    except ValueError as error:
        raise ManualBuildError("unsafe manual image reference") from error
    return candidate


def slugify(text):
    s = text.lower()
    s = re.sub(r"[^\w\s-]", "", s, flags=re.UNICODE)
    s = re.sub(r"\s+", "-", s.strip())
    return s


def join_wrapped(lines):
    out = lines[0]
    for line in lines[1:]:
        prev = out[-1] if out else ""
        nxt = line[0] if line else ""
        if re.match(r"[A-Za-z0-9]", prev) and re.match(r"[A-Za-z0-9]", nxt):
            out += " " + line
        else:
            out += line
    return out


def render_inline(text):
    out = []
    pos = 0
    for m in INLINE_RE.finditer(text):
        if m.start() > pos:
            out.append(esc(text[pos : m.start()]))
        if m.group("code") is not None:
            out.append("<code>%s</code>" % esc(m.group("code")))
        elif m.group("linktext") is not None:
            href = safe_link_href(m.group("linkhref"))
            if href is None:
                out.append(esc(m.group("linktext")))
            else:
                out.append('<a href="%s">%s</a>' % (esc(href), esc(m.group("linktext"))))
        elif m.group("bold") is not None:
            out.append("<strong>%s</strong>" % esc(m.group("bold")))
        pos = m.end()
    out.append(esc(text[pos:]))
    return "".join(out)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    return line.strip() == ""


# ---- block parsing ----


def parse_blocks(lines, start=0, end=None):
    if end is None:
        end = len(lines)
    blocks = []
    i = start
    while i < end:
        line = lines[i]
        if is_blank(line):
            i += 1
            continue

        m = HEADING_RE.match(line)
        if m:
            level = len(m.group(1))
            blocks.append({"type": "heading", "level": level, "text": m.group(2).strip()})
            i += 1
            continue

        if line.strip() == "---":
            blocks.append({"type": "hr"})
            i += 1
            continue

        fm = FENCE_RE.match(line)
        if fm and fm.group(1) == "":
            lang = fm.group(2)
            code_lines = []
            i += 1
            while i < end and not (FENCE_RE.match(lines[i]) and indent_of(lines[i]) == 0):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            blocks.append({"type": "code", "lang": lang, "text": "\n".join(code_lines)})
            continue

        if line.startswith(">"):
            quote_lines = []
            while i < end and lines[i].startswith(">"):
                quote_lines.append(lines[i][1:].lstrip(" ") if lines[i] != ">" else "")
                i += 1
            blocks.append({"type": "quote", "paras": split_quote_paragraphs(quote_lines)})
            continue

        im = IMAGE_RE.match(line.strip())
        if im:
            blocks.append({"type": "image", "alt": im.group(1), "src": im.group(2)})
            i += 1
            continue

        if line.lstrip().startswith("|") and i + 1 < end and TABLE_SEP_RE.match(lines[i + 1].strip()):
            table, i = parse_table(lines, i, end)
            blocks.append(table)
            continue

        lm = LIST_ITEM_RE.match(line)
        if lm:
            node, i = parse_list(lines, i, end, indent_of(line))
            blocks.append(node)
            continue

        # paragraph: consume until blank line
        para_lines = []
        while i < end and not is_blank(lines[i]):
            para_lines.append(lines[i])
            i += 1
        blocks.append({"type": "para", "text": join_wrapped(para_lines)})

    return blocks


def split_quote_paragraphs(raw_lines):
    paras = []
    current = []
    for line in raw_lines:
        if line.strip() == "":
            if current:
                paras.append(join_wrapped(current))
                current = []
        else:
            current.append(line)
    if current:
        paras.append(join_wrapped(current))
    return paras


def parse_table(lines, i, end):
    header_cells = split_row(lines[i])
    i += 2  # skip header + separator
    rows = []
    while i < end and lines[i].lstrip().startswith("|"):
        rows.append(split_row(lines[i]))
        i += 1
    return {"type": "table", "header": header_cells, "rows": rows}, i


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def parse_list(lines, i, end, indent):
    m = LIST_ITEM_RE.match(lines[i])
    list_type = "ol" if m.group(2) != "-" else "ul"
    items = []

    while i < end:
        m = LIST_ITEM_RE.match(lines[i])
        if not m or indent_of(lines[i]) != indent:
            break
        this_type = "ol" if m.group(2) != "-" else "ul"
        if this_type != list_type:
            break
        content_col = indent + len(m.group(2)) + 1
        while content_col < len(lines[i]) and lines[i][content_col] == " ":
            content_col += 1
        first_text = m.group(3)
        i += 1

        sub_blocks = []
        pending = [first_text]

        def flush():
            if pending:
                sub_blocks.append({"type": "para", "text": join_wrapped(pending)})
                pending.clear()

        while i < end:
            line = lines[i]
            if is_blank(line):
                j = i + 1
                while j < end and is_blank(lines[j]):
                    j += 1
                if j < end and (
                    indent_of(lines[j]) >= content_col
                    or (LIST_ITEM_RE.match(lines[j]) and indent_of(lines[j]) == indent)
                ):
                    flush()
                    i = j
                    continue
                break

            if indent_of(line) >= content_col:
                nested_m = LIST_ITEM_RE.match(line)
                if nested_m and indent_of(line) > indent:
                    flush()
                    nested, i = parse_list(lines, i, end, indent_of(line))
                    sub_blocks.append(nested)
                    continue
                fenced = FENCE_RE.match(line)
                if fenced and indent_of(line) == content_col:
                    flush()
                    lang = fenced.group(2)
                    code_lines = []
                    i += 1
                    while i < end and not (
                        FENCE_RE.match(lines[i]) and indent_of(lines[i]) == content_col
                    ):
                        code_lines.append(lines[i][content_col:])
                        i += 1
                    i += 1
                    sub_blocks.append({"type": "code", "lang": lang, "text": "\n".join(code_lines)})
                    continue
                pending.append(line[content_col:])
                i += 1
                continue

            break

        flush()
        items.append(sub_blocks)

    return {"type": list_type, "items": items}, i


# ---- rendering ----


def assign_heading_ids(blocks, seen, toc):
    for b in blocks:
        if b["type"] == "heading":
            slug = slugify(b["text"]) or "section"
            if slug in seen:
                seen[slug] += 1
                slug = "%s-%d" % (slug, seen[slug])
            else:
                seen[slug] = 0
            b["id"] = slug
            if b["level"] == 2:
                toc.append((slug, b["text"]))
        elif b["type"] in ("ul", "ol"):
            for item in b["items"]:
                assign_heading_ids(item, seen, toc)


def render_blocks(blocks, ctx):
    out = []
    for b in blocks:
        out.append(render_block(b, ctx))
    return "\n".join(out)


def render_block(b, ctx):
    t = b["type"]
    if t == "heading":
        tag = "h%d" % b["level"]
        return '<%s id="%s">%s</%s>' % (tag, b["id"], render_inline(b["text"]), tag)
    if t == "para":
        return "<p>%s</p>" % render_inline(b["text"])
    if t == "hr":
        return "<hr>"
    if t == "code":
        lang_class = ' class="language-%s"' % esc(b["lang"]) if b["lang"] else ""
        return "<pre><code%s>%s</code></pre>" % (lang_class, esc(b["text"]))
    if t == "quote":
        paras = "".join("<p>%s</p>" % render_inline(p) for p in b["paras"])
        return "<blockquote>%s</blockquote>" % paras
    if t == "image":
        return render_image(b["alt"], b["src"], ctx)
    if t == "table":
        return render_table(b)
    if t in ("ul", "ol"):
        items = "".join("<li>%s</li>" % render_blocks(item, ctx) for item in b["items"])
        return "<%s>%s</%s>" % (t, items, t)
    return ""


def render_image(alt, src, ctx):
    path = safe_manual_image_path(src)
    if path.is_file():
        mime = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        return (
            '<figure class="manual-image"><img src="data:%s;base64,%s" alt="%s" loading="lazy"></figure>'
            % (mime, data, esc(alt))
        )
    ctx["missing_images"].append(src)
    return (
        '<figure class="manual-image missing-image"><div class="missing-image-box">'
        "%s<br><span class=\"missing-filename\">%s</span></div></figure>"
        % (esc(ctx["missing_image_text"]), esc(src))
    )


def render_table(b):
    thead = "<tr>" + "".join("<th>%s</th>" % render_inline(c) for c in b["header"]) + "</tr>"
    rows = ""
    for row in b["rows"]:
        rows += "<tr>" + "".join("<td>%s</td>" % render_inline(c) for c in row) + "</tr>"
    return '<div class="table-wrap"><table><thead>%s</thead><tbody>%s</tbody></table></div>' % (
        thead,
        rows,
    )


# ---- anchor validation ----


def check_anchors(html_text):
    ids = set(re.findall(r'\bid="([^"]+)"', html_text))
    hrefs = re.findall(r'href="#([^"]+)"', html_text)
    broken = [h for h in hrefs if h not in ids]
    return broken


def validate_image_blocks(blocks):
    for block in blocks:
        if block["type"] == "image":
            safe_manual_image_path(block["src"])
        elif block["type"] in ("ul", "ol"):
            for item in block["items"]:
                validate_image_blocks(item)


def validate_all_manual_images():
    """Reject unsafe image references before either manual can write HTML."""
    for lang in LANGS:
        src_path = DOCS_DIR / lang["src"]
        if not src_path.is_file():
            continue
        lines = src_path.read_text(encoding="utf-8").split("\n")
        body_start = 1 if lines and HEADING_RE.match(lines[0]) else 0
        validate_image_blocks(parse_blocks(lines, body_start))


# ---- css / shell ----

CSS = """
:root {
  --bg: #ffffff;
  --fg: #1c1c1e;
  --muted: #6b6b70;
  --accent: #0a5fff;
  --border: #e2e2e6;
  --code-bg: #f4f4f6;
  --nav-bg: #f8f8fa;
  --table-header-bg: #f0f0f3;
  --quote-bg: #f6f8fc;
  --quote-border: #b9c9f2;
  --missing-bg: #fbf6e9;
  --missing-border: #e3d6a1;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16161a;
    --fg: #e7e7ea;
    --muted: #a0a0a8;
    --accent: #6ea8ff;
    --border: #2e2e33;
    --code-bg: #201f24;
    --nav-bg: #1c1c21;
    --table-header-bg: #232329;
    --quote-bg: #1c2230;
    --quote-border: #3a4a78;
    --missing-bg: #2a2718;
    --missing-border: #52471f;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN",
    "Yu Gothic", "Segoe UI", sans-serif;
  line-height: 1.9;
}
a { color: var(--accent); }
.layout { display: flex; align-items: flex-start; min-height: 100vh; }
nav.toc {
  flex: 0 0 260px;
  width: 260px;
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
  background: var(--nav-bg);
  border-right: 1px solid var(--border);
  padding: 1.25rem 1rem;
}
nav.toc h2 { font-size: 0.85rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 0.75rem; }
nav.toc ol { list-style: none; margin: 0; padding: 0; }
nav.toc li { margin: 0 0 0.4rem; }
nav.toc a { text-decoration: none; font-size: 0.92rem; color: var(--fg); }
nav.toc a:hover { color: var(--accent); }
main {
  flex: 1 1 auto;
  min-width: 0;
  padding: 2.5rem 1.5rem 6rem;
}
.doc-header { max-width: 40rem; margin: 0 auto 2rem; }
.doc-header h1 { margin: 0 0 0.4rem; font-size: 1.7rem; }
.doc-header .version { color: var(--muted); font-size: 0.9rem; }
article { max-width: 40rem; margin: 0 auto; word-wrap: break-word; }
h2 { margin-top: 3rem; padding-top: 0.5rem; border-top: 1px solid var(--border); }
h3 { margin-top: 2.2rem; }
h4 { margin-top: 1.6rem; }
p { margin: 0.9em 0; }
code {
  background: var(--code-bg);
  border-radius: 4px;
  padding: 0.15em 0.4em;
  font-size: 0.92em;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
pre {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.9rem 1rem;
  overflow-x: auto;
}
pre code { background: none; padding: 0; font-size: 0.88em; }
blockquote {
  margin: 1.2em 0;
  padding: 0.7em 1.1em;
  background: var(--quote-bg);
  border-left: 4px solid var(--quote-border);
  border-radius: 4px;
}
blockquote p { margin: 0.5em 0; }
ul, ol { padding-left: 1.4em; }
li { margin: 0.4em 0; }
li > p { margin: 0.4em 0; }
hr { border: none; border-top: 1px solid var(--border); margin: 2.5rem 0; }
.table-wrap { overflow-x: auto; margin: 1.2em 0; }
table { border-collapse: collapse; width: 100%; min-width: max-content; font-size: 0.92em; }
th, td { border: 1px solid var(--border); padding: 0.5em 0.8em; text-align: left; vertical-align: top; }
th { background: var(--table-header-bg); white-space: nowrap; }
figure.manual-image { margin: 1.4em 0; }
figure.manual-image img { max-width: 100%; border: 1px solid var(--border); border-radius: 8px; }
.missing-image-box {
  border: 1px dashed var(--missing-border);
  background: var(--missing-bg);
  border-radius: 8px;
  padding: 1.2rem;
  text-align: center;
  color: var(--muted);
  font-size: 0.9rem;
}
.missing-filename { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
#nav-toggle { display: none; }
.nav-toggle-label { display: none; }
@media (max-width: 860px) {
  .layout { display: block; }
  nav.toc {
    position: static;
    width: auto;
    height: auto;
    border-right: none;
    border-bottom: 1px solid var(--border);
  }
  .nav-toggle-label {
    display: block;
    cursor: pointer;
    font-weight: 600;
    padding: 0.4rem 0;
  }
  nav.toc ol { display: none; }
  #nav-toggle:checked ~ nav.toc ol { display: block; }
}
@media print {
  nav.toc, .nav-toggle-label { display: none !important; }
  .layout { display: block; }
  main { padding: 0; }
  a { text-decoration: underline; color: inherit; }
  h2, h3, h4 { break-after: avoid; page-break-after: avoid; }
  pre, table, blockquote, figure { break-inside: avoid; page-break-inside: avoid; }
}
"""


def build_page(title, version_label, version, toc, body_html, html_lang):
    toc_items = "".join(
        '<li><a href="#%s">%s</a></li>' % (slug, esc(text)) for slug, text in toc
    )
    return """<!doctype html>
<html lang="%s">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<style>%s</style>
</head>
<body>
<div class="layout">
<input type="checkbox" id="nav-toggle">
<nav class="toc">
<label class="nav-toggle-label" for="nav-toggle">%s ▾</label>
<h2>%s</h2>
<ol>%s</ol>
</nav>
<main>
<div class="doc-header">
<h1>%s</h1>
<div class="version">%s: %s</div>
</div>
<article>
%s
</article>
</main>
</div>
</body>
</html>
""" % (
        html_lang,
        esc(title),
        CSS,
        esc(title),
        esc(title),
        toc_items,
        esc(title),
        esc(version_label),
        esc(version),
        body_html,
    )


def convert(lang):
    src_path = DOCS_DIR / lang["src"]
    if not src_path.is_file():
        print("skip: %s not found (not written yet)" % src_path, file=sys.stderr)
        return

    text = src_path.read_text(encoding="utf-8")
    lines = text.split("\n")

    m = HEADING_RE.match(lines[0]) if lines else None
    title = m.group(2).strip() if m and len(m.group(1)) == 1 else lang["src"]
    body_start = 1 if m and len(m.group(1)) == 1 else 0

    blocks = parse_blocks(lines, body_start)

    seen_slugs = {}
    toc = []
    assign_heading_ids(blocks, seen_slugs, toc)

    version_match = re.search(lang["version_re"], text)
    version = version_match.group(1).strip() if version_match else DEFAULT_VERSION

    ctx = {"missing_images": [], "missing_image_text": lang["missing_image_text"]}
    body_html = render_blocks(blocks, ctx)

    page = build_page(title, lang["version_label"], version, toc, body_html, lang["html_lang"])

    broken = check_anchors(page)

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    out_path = DIST_DIR / lang["out"]
    out_path.write_text(page, encoding="utf-8")

    print("wrote %s (%d bytes)" % (out_path, out_path.stat().st_size), file=sys.stderr)
    if ctx["missing_images"]:
        print("missing images (%d):" % len(ctx["missing_images"]), file=sys.stderr)
        for name in ctx["missing_images"]:
            print("  - %s" % name, file=sys.stderr)
    if broken:
        print("broken anchors (%d):" % len(broken), file=sys.stderr)
        for h in broken:
            print("  - #%s" % h, file=sys.stderr)
    else:
        print("anchors: all resolved", file=sys.stderr)


def main():
    try:
        # Validate both sources before writing either HTML file.  A malformed
        # image reference must never produce a partial manual set.
        validate_all_manual_images()
        for lang in LANGS:
            convert(lang)
    except ManualBuildError:
        print("error: unsafe manual image reference", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
