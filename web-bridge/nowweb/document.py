"""One semantic document tree, its deterministic lenses, and HTML emitters."""

from __future__ import annotations

from dataclasses import dataclass, field
import html
from html.parser import HTMLParser
import json
import subprocess
import unicodedata
from urllib.parse import quote, urljoin

from .profile import BrowserProfile


_SKIP = {"script", "style", "noscript", "template", "svg", "link", "meta",
         "iframe", "video", "audio", "canvas", "object", "embed", "source",
         "track", "map"}
_FLOW = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "dl",
         "table", "pre", "blockquote", "hr", "form", "nav"}
_KEEP = _FLOW | {"li", "tr", "td", "th", "br", "b", "strong", "i", "em",
                 "code", "tt", "dt", "dd", "button", "input", "select",
                 "textarea"}
_BLOCKISH = {"html", "body", "div", "section", "article", "main", "header",
             "footer", "aside",
             "figure", "figcaption", "details", "summary", "address",
             "fieldset"}
_VOID = {"br", "hr", "img", "input", "meta", "link", "source", "col",
         "area", "base", "wbr", "embed", "track", "param"}


@dataclass
class Node:
    tag: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list["Node | str"] = field(default_factory=list)


@dataclass
class Block:
    identifier: str
    node: Node

    def text(self) -> str:
        return text_content(self.node).strip()


@dataclass
class Document:
    title: str
    url: str
    blocks: list[Block]


class _Parser(HTMLParser):
    def __init__(self, base_url: str):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.root = Node("root")
        self.stack: list[tuple[str, Node]] = [("root", self.root)]
        self.skip: list[str] = []
        self.title_parts: list[str] = []
        self.in_title = False

    @property
    def output(self) -> Node:
        return self.stack[-1][1]

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attrs = {key.lower(): value or "" for key, value in attrs}
        if self.skip:
            if tag == self.skip[-1] and tag not in _VOID:
                self.skip.append(tag)
            return
        if tag == "title":
            self.in_title = True
            return
        if tag in _SKIP:
            if tag not in _VOID:
                self.skip.append(tag)
            return
        if tag == "img":
            src = attrs.get("src", "")
            self.output.children.append(Node("img", {
                "src": urljoin(self.base_url, src) if src else "",
                "alt": attrs.get("alt", ""),
            }))
            return
        node_attrs: dict[str, str] = {}
        if tag == "a":
            node_attrs["href"] = urljoin(self.base_url, attrs.get("href", ""))
        elif tag == "form":
            node_attrs["action"] = urljoin(self.base_url, attrs.get("action", ""))
            node_attrs["method"] = attrs.get("method", "get").lower()
        elif tag in {"input", "button", "textarea", "select"}:
            node_attrs = {key: attrs.get(key, "") for key in
                          ("name", "value", "type", "placeholder")}
        semantic = tag if tag in _KEEP or tag == "a" else (
            "block" if tag in _BLOCKISH else "span")
        node = Node(semantic, node_attrs)
        self.output.children.append(node)
        if tag not in _VOID:
            self.stack.append((tag, node))

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "title":
            self.in_title = False
            return
        if self.skip:
            if tag == self.skip[-1]:
                self.skip.pop()
            return
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        if self.skip:
            return
        if self.in_title:
            self.title_parts.append(data)
            return
        value = " ".join(data.split())
        if value:
            self.output.children.append(value)


def parse_document(source: str, url: str) -> Document:
    parser = _Parser(url)
    parser.feed(source)
    parser.close()
    blocks: list[Block] = []

    def append(node: Node) -> None:
        if node.tag == "block":
            flow_children = [child for child in node.children
                             if isinstance(child, Node) and
                             child.tag in (_FLOW | {"block"})]
            if flow_children:
                for child in node.children:
                    if isinstance(child, Node):
                        append(child)
                return
            node.tag = "p"
        if node.tag in _FLOW:
            blocks.append(Block("b%d" % (len(blocks) + 1), node))
            return
        for child in node.children:
            if isinstance(child, Node):
                append(child)

    loose: list[Node | str] = []
    for child in parser.root.children:
        if isinstance(child, Node) and child.tag in (_FLOW | {"block"}):
            if loose:
                blocks.append(Block("b%d" % (len(blocks) + 1),
                                    Node("p", children=loose)))
                loose = []
            append(child)
        else:
            loose.append(child)
    if loose:
        blocks.append(Block("b%d" % (len(blocks) + 1), Node("p", children=loose)))
    title = " ".join(" ".join(parser.title_parts).split()) or url
    return Document(title=title, url=url, blocks=blocks)


def text_content(node: Node | str) -> str:
    if isinstance(node, str):
        return node
    return " ".join(text_content(child) for child in node.children)


def reader(document: Document) -> Document:
    kept = [block for block in document.blocks
            if block.node.tag not in {"nav", "form"} and block.text()]
    return Document(document.title, document.url, kept)


class PlanError(ValueError):
    pass


def apply_plan(document: Document, plan: dict) -> Document:
    order = plan.get("order")
    if not isinstance(order, list) or not all(isinstance(item, str) for item in order):
        raise PlanError("AI plan needs an order array of block IDs")
    by_id = {block.identifier: block for block in document.blocks}
    if len(order) != len(set(order)) or set(order) != set(by_id):
        raise PlanError("AI plan must name every original block exactly once")
    return Document(document.title, document.url, [by_id[item] for item in order])


def command_plan(document: Document, command: list[str], timeout: float) -> dict:
    payload = {"version": "now-web-layout-plan/1", "url": document.url,
               "title": document.title,
               "blocks": [{"id": item.identifier, "text": item.text()[:512]}
                          for item in document.blocks]}
    result = subprocess.run(command, input=json.dumps(payload), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, check=True)
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise PlanError("AI planner returned a non-object")
    return value


def _ascii(value: str, entities: str) -> str:
    replacements = {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-",
                    "—": " - ", "…": "...", " ": " ", "•": "*"}
    for before, after in replacements.items():
        value = value.replace(before, after)
    escaped = html.escape(value, quote=False)
    if entities == "numeric":
        return "".join(ch if ord(ch) < 128 else "&#%d;" % ord(ch)
                       for ch in escaped)
    folded = unicodedata.normalize("NFKD", escaped)
    return "".join(ch if ord(ch) < 128 else "" if unicodedata.combining(ch)
                   else "?" for ch in folded)


def gateway_url(url: str, profile: str, lens: str,
                handlers: bool = True) -> str:
    return "/go?u=%s&profile=%s&lens=%s&handlers=%s" % (
        quote(url, safe=""), quote(profile, safe=""), quote(lens, safe=""),
        "on" if handlers else "off")


def _table_rows(node: Node) -> list[list[str]]:
    rows: list[list[str]] = []
    for child in node.children:
        if isinstance(child, Node) and child.tag == "tr":
            rows.append([text_content(cell).strip() for cell in child.children
                         if isinstance(cell, Node) and cell.tag in {"td", "th"}])
        elif isinstance(child, Node):
            rows.extend(_table_rows(child))
    return [row for row in rows if row]


def _emit(node: Node | str, profile: BrowserProfile, lens: str,
          handlers: bool, link_count: list[int]) -> str:
    if isinstance(node, str):
        return _ascii(node, profile.entities)
    tag = node.tag
    children = "".join(_emit(child, profile, lens, handlers, link_count)
                       for child in node.children)
    if tag == "a":
        href = node.attrs.get("href", "")
        if href.startswith(("http://", "https://")) and link_count[0] < profile.link_cap:
            link_count[0] += 1
            href = gateway_url(href, profile.name, lens, handlers)
            return '<a href="%s">%s</a>' % (html.escape(href, quote=True),
                                              children or _ascii(href, profile.entities))
        return children
    if tag == "img":
        alt = _ascii(node.attrs.get("alt", "Image"), profile.entities)
        if profile.images == "off":
            return "[Image: %s]" % alt
        src = node.attrs.get("src", "")
        return '<img src="%s" alt="%s">' % (html.escape(src, quote=True), alt)
    if tag == "table" and profile.tables != "keep":
        rows = _table_rows(node)
        if profile.tables == "pre":
            return "<pre>%s</pre>" % "\n".join(
                " | ".join(_ascii(cell, profile.entities) for cell in row)
                for row in rows)
        return "".join("<p>%s</p>" % " - ".join(
            _ascii(cell, profile.entities) for cell in row) for row in rows)
    if tag == "form":
        return "%s <i>[form submission unavailable]</i>" % children
    if tag in {"button", "input", "select", "textarea"}:
        marker = children or node.attrs.get("value") or node.attrs.get("placeholder")
        return "%s <i>[interactive control unavailable]</i>" % _ascii(marker, profile.entities)
    allowed = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "li",
               "pre", "blockquote", "b", "strong", "i", "em", "dl", "dt", "dd",
               "table", "tr", "td", "th", "hr", "br"}
    if tag == "nav":
        return "<p>%s</p>" % children
    if tag == "code":
        tag = "tt"
    if tag not in allowed and tag != "tt":
        return children
    if tag in {"hr", "br"}:
        return "<%s>" % tag
    return "<%s>%s</%s>" % (tag, children, tag)


def render_blocks(document: Document, profile: BrowserProfile, lens: str,
                  handlers: bool = True) -> list[str]:
    links = [0]
    return [_emit(block.node, profile, lens, handlers, links)
            for block in document.blocks]


def assemble_pages(document: Document, profile: BrowserProfile, lens: str,
                   handlers: bool = True) -> list[bytes]:
    pieces = render_blocks(document, profile, lens, handlers)
    body_pages: list[list[str]] = [[]]
    for piece in pieces:
        candidate = "".join(body_pages[-1] + [piece]).encode("ascii")
        if profile.paginate and body_pages[-1] and len(candidate) > profile.page_bytes:
            body_pages.append([piece])
        else:
            body_pages[-1].append(piece)
    pages: list[bytes] = []
    for index, body in enumerate(body_pages, 1):
        chrome = ('<html><head><title>%s</title></head><body>'
                  '<p><b>%s</b> - <a href="/">NOW Web</a> - '
                  '<a href="%s">reload</a> - '
                  '<a href="%s">Compatible</a> - '
                  '<a href="%s">Reader</a> - '
                  '<a href="%s">AI Layout</a></p><hr>' % (
                      _ascii(document.title, profile.entities),
                      _ascii(document.url, profile.entities),
                      gateway_url(document.url, profile.name, lens, handlers),
                      gateway_url(document.url, profile.name, "compatible", handlers),
                      gateway_url(document.url, profile.name, "reader", handlers),
                      gateway_url(document.url, profile.name, "ai", handlers)))
        navigation = ""
        if len(body_pages) > 1:
            navigation = '<hr><p>Page %d of %d</p>' % (index, len(body_pages))
        payload = (chrome + "".join(body) + navigation + "</body></html>").encode("ascii")
        if len(payload) > profile.page_budget:
            marker = b"<hr><p><i>[page exceeded this browser profile's byte budget]</i></p></body></html>"
            payload = payload[:max(0, profile.page_budget - len(marker))] + marker
        pages.append(payload)
    return pages
