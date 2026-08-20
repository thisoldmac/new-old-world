from .raster import Raster


def _color(depth, desired):
    if depth == 1:
        return 1 if desired in {"black", "dark", "accent"} else 0
    return {
        "white": 0,
        "black": 1,
        "light": 2,
        "mid": 3,
        "dark": 5,
        "accent": 7,
        "success": 8,
        "warning": 9,
        "danger": 10,
        "purple": 11,
        "selection": 12,
    }.get(desired, 1)


def _bevel(raster, x, y, width, height, pressed=False):
    white = _color(raster.depth, "white")
    black = _color(raster.depth, "black")
    light = _color(raster.depth, "light")
    dark = _color(raster.depth, "dark")
    raster.fill(x, y, width, height, light)
    raster.line(x, y, x + width - 1, y, dark if pressed else white)
    raster.line(x, y, x, y + height - 1, dark if pressed else white)
    raster.line(x, y + height - 1, x + width - 1, y + height - 1, white if pressed else black)
    raster.line(x + width - 1, y, x + width - 1, y + height - 1, white if pressed else black)
    if width > 3 and height > 3:
        raster.line(x + 1, y + height - 2, x + width - 2, y + height - 2, _color(raster.depth, "dark"))
        raster.line(x + width - 2, y + 1, x + width - 2, y + height - 2, _color(raster.depth, "dark"))


def _inset(raster, x, y, width, height, fill="white"):
    raster.fill(x, y, width, height, _color(raster.depth, fill))
    raster.line(x, y, x + width - 1, y, _color(raster.depth, "dark"))
    raster.line(x, y, x, y + height - 1, _color(raster.depth, "dark"))
    raster.line(x, y + height - 1, x + width - 1, y + height - 1, _color(raster.depth, "white"))
    raster.line(x + width - 1, y, x + width - 1, y + height - 1, _color(raster.depth, "white"))
    if width > 3 and height > 3:
        raster.rect(x + 1, y + 1, width - 2, height - 2, _color(raster.depth, "mid"))


def _button(raster, x, y, width, height, text, default=False, disabled=False, platinum=False):
    if default:
        raster.rect(x - 4, y - 4, width + 8, height + 8,
                    _color(raster.depth, "black"), 2)
        raster.rect(x - 2, y - 2, width + 4, height + 4,
                    _color(raster.depth, "black"))
    if platinum and raster.depth > 1:
        _bevel(raster, x, y, width, height)
        background = _color(raster.depth, "light")
        for px, py in ((x, y), (x + width - 1, y), (x, y + height - 1), (x + width - 1, y + height - 1)):
            raster.set(px, py, background)
    else:
        raster.fill(x, y, width, height, _color(raster.depth, "white"))
        raster.rect(x, y, width, height, _color(raster.depth, "black"))
    color = _color(raster.depth, "mid" if disabled else "black")
    tx = x + max(4, (width - raster.text_width(text)) // 2)
    raster.text(tx, y + max(4, (height - 7) // 2), text, color, max_width=width - 8)


def _triangle(raster, x, y, direction, color):
    if direction == "down":
        for offset in range(4):
            raster.line(x + offset, y + offset, x + 6 - offset, y + offset, color)
    elif direction == "up":
        for offset in range(4):
            raster.line(x + 3 - offset, y + offset, x + 3 + offset, y + offset, color)
    else:
        for offset in range(4):
            raster.line(x + offset, y + offset, x + offset, y + 6 - offset, color)


def _popup(raster, x, y, width, height, text, disabled=False, platinum=False):
    _button(raster, x, y, width, height, "", False, disabled, platinum)
    ink = _color(raster.depth, "mid" if disabled else "black")
    arrow_w = min(18, max(12, height - 2))
    raster.line(x + width - arrow_w, y + 2, x + width - arrow_w, y + height - 3, _color(raster.depth, "dark"))
    raster.text(x + 7, y + max(4, (height - 7) // 2), text, ink, max_width=width - arrow_w - 10)
    arrow_x = x + width - arrow_w + max(2, (arrow_w - 7) // 2)
    _triangle(raster, arrow_x, y + 4, "up", ink)
    _triangle(raster, arrow_x, y + max(9, height - 10), "down", ink)


def _slider(raster, x, y, width, height, component, platinum=False):
    minimum = component.get("min", 0)
    maximum = component.get("max", 100)
    value = component.get("value", minimum)
    ink = _color(raster.depth, "mid" if component.get("disabled") else "black")
    track_y = y + max(5, height // 2)
    raster.line(x + 7, track_y, x + width - 8, track_y, _color(raster.depth, "dark"))
    raster.line(x + 7, track_y + 1, x + width - 8, track_y + 1, _color(raster.depth, "white"))
    ticks = component.get("ticks", 0)
    if isinstance(ticks, int) and ticks > 1:
        for index in range(ticks):
            tick_x = x + 7 + (width - 15) * index // (ticks - 1)
            raster.line(tick_x, track_y + 5, tick_x, track_y + 8, ink)
    fraction = (value - minimum) / (maximum - minimum)
    thumb_x = x + 7 + int((width - 15) * fraction) - 5
    if platinum:
        _bevel(raster, thumb_x, y + 2, 11, max(13, height - 6))
    else:
        raster.rect(thumb_x, y + 2, 11, max(13, height - 6), ink)


def _little_arrows(raster, x, y, width, height, disabled=False):
    ink = _color(raster.depth, "mid" if disabled else "black")
    _bevel(raster, x, y, width, height)
    half = height // 2
    raster.line(x + 1, y + half, x + width - 2, y + half, _color(raster.depth, "dark"))
    _triangle(raster, x + max(2, (width - 7) // 2), y + 3, "up", ink)
    _triangle(raster, x + max(2, (width - 7) // 2), y + half + 3, "down", ink)


def _disclosure(raster, x, y, width, text, opened=False, disabled=False):
    ink = _color(raster.depth, "mid" if disabled else "black")
    _triangle(raster, x + 1, y + 3, "down" if opened else "right", ink)
    raster.text(x + 13, y + 3, text, ink, max_width=max(0, width - 13))


def _image_well(raster, x, y, width, height, component):
    _inset(raster, x, y, width, height, "light")
    inner_x, inner_y = x + 5, y + 5
    inner_w, inner_h = max(1, width - 10), max(1, height - 10)
    raster.fill(inner_x, inner_y, inner_w, inner_h, _color(raster.depth, "white"))
    raster.rect(inner_x, inner_y, inner_w, inner_h, _color(raster.depth, "mid"))
    symbol = component.get("symbol", "document")
    _icon(raster, x + max(6, (width - 24) // 2), y + max(6, (height - 28) // 2), symbol)
    caption = component.get("caption")
    if caption:
        raster.text(x + 6, y + height - 14, caption, _color(raster.depth, "black"), max_width=width - 12)


def _text_area(raster, x, y, width, height, component, platinum=False):
    _inset(raster, x, y, width, height)
    scroll_w = 15
    gutter = 28 if component.get("line_numbers") else 0
    content_x = x + 4 + gutter
    content_w = max(1, width - scroll_w - gutter - 8)
    if gutter:
        raster.fill(x + 2, y + 2, gutter, height - 4, _color(raster.depth, "light"))
        raster.line(x + gutter + 1, y + 2, x + gutter + 1, y + height - 3, _color(raster.depth, "mid"))
    row_h = 12
    visible = max(0, (height - 6) // row_h)
    selected = component.get("selected_line")
    for index, line in enumerate(component.get("lines", [])[:visible]):
        row_y = y + 5 + index * row_h
        if index == selected:
            raster.fill(content_x - 2, row_y - 2, content_w + 2, row_h, _color(raster.depth, "accent" if platinum and raster.depth > 1 else "black"))
        ink = _color(raster.depth, "white") if index == selected else _color(raster.depth, "black")
        if gutter:
            number = str(index + 1)
            raster.text(x + gutter - raster.text_width(number) - 3, row_y, number, _color(raster.depth, "dark"))
        raster.text(content_x, row_y, str(line), ink, max_width=content_w)
    _scrollbar(raster, x + width - scroll_w - 1, y + 1, scroll_w, height - 2, component.get("disabled", False), platinum)


def _hatch_rect(raster, x, y, width, height, color):
    raster.rect(x, y, width, height, color, 2)
    for offset in range(-height, width, 7):
        start_x = x + max(0, offset)
        start_y = y + max(0, -offset)
        length = min(width - max(0, offset), height - max(0, -offset))
        if length > 0:
            raster.line(start_x, start_y, start_x + length - 1, start_y + length - 1, color)


def _quickdraw_canvas(raster, x, y, width, height, component):
    _inset(raster, x, y, width, height)
    left, top = x + 4, y + 4
    inner_w, inner_h = max(1, width - 8), max(1, height - 8)
    mode = component.get("mode", "media-frame")
    if mode == "screen-delta":
        raster.fill(left, top, inner_w, inner_h, _color(raster.depth, "mid"))
        wx, wy = left + 28, top + 20
        ww, wh = max(80, inner_w - 56), max(70, inner_h - 40)
        raster.fill(wx, wy, ww, wh, _color(raster.depth, "light"))
        raster.rect(wx, wy, ww, wh, _color(raster.depth, "black"), 2)
        raster.fill(wx + 2, wy + 2, ww - 4, 18, _color(raster.depth, "mid"))
        raster.text(wx + 28, wy + 7, "Guest Screen", _color(raster.depth, "black"), max_width=ww - 56)
        raster.fill(wx + 18, wy + 42, ww // 3, wh - 64, _color(raster.depth, "white"))
        raster.rect(wx + 18, wy + 42, ww // 3, wh - 64, _color(raster.depth, "dark"))
        raster.fill(wx + ww // 3 + 34, wy + 42, ww // 2, 24, _color(raster.depth, "white"))
        raster.fill(wx + ww // 3 + 34, wy + 78, ww // 2, wh - 100, _color(raster.depth, "white"))
        _hatch_rect(raster, wx + ww // 3 + 45, wy + 84, max(30, ww // 3), 28, _color(raster.depth, "danger"))
        _hatch_rect(raster, wx + 26, wy + 78, max(24, ww // 5), 22, _color(raster.depth, "warning"))
        raster.text(left + 8, top + 7, "14.2% changed - 3 regions", _color(raster.depth, "danger"), max_width=inner_w - 16)
    elif mode == "web-document":
        raster.fill(left, top, inner_w, inner_h, _color(raster.depth, "white"))
        raster.fill(left, top, inner_w, 28, _color(raster.depth, "purple"))
        raster.text(left + 10, top + 10, "THE DAILY CIRCUIT", _color(raster.depth, "white"), max_width=inner_w - 20)
        raster.text(left + 12, top + 42, "A modern web page, typeset for 1999", _color(raster.depth, "black"), max_width=inner_w - 24)
        media_w = min(220, max(100, inner_w // 2))
        media_h = min(128, max(70, inner_h // 2))
        media_x, media_y = left + 12, top + 64
        raster.fill(media_x, media_y, media_w, media_h, _color(raster.depth, "light"))
        raster.rect(media_x, media_y, media_w, media_h, _color(raster.depth, "dark"), 2)
        raster.fill(media_x + 8, media_y + 8, media_w - 16, media_h - 38, _color(raster.depth, "accent"))
        _triangle(raster, media_x + media_w // 2 - 2, media_y + media_h // 2 - 12, "right", _color(raster.depth, "white"))
        raster.text(media_x + 8, media_y + media_h - 22, component.get("media_label", "Movie link - opens player"), _color(raster.depth, "black"), max_width=media_w - 16)
        text_x = media_x + media_w + 14
        for row in range(12):
            line_w = max(20, inner_w - (text_x - left) - 10 - (row % 3) * 18)
            raster.fill(text_x, media_y + row * 10, line_w, 2, _color(raster.depth, "dark" if row % 4 else "accent"))
        for row in range(7):
            raster.fill(left + 12, media_y + media_h + 16 + row * 10, inner_w - 24 - (row % 2) * 40, 2, _color(raster.depth, "dark"))
    elif mode == "transfer-route":
        raster.fill(left, top, inner_w, inner_h, _color(raster.depth, "light"))
        _icon(raster, left + 34, top + inner_h // 2 - 12, "disk")
        _icon(raster, left + inner_w - 62, top + inner_h // 2 - 12, "folder")
        route_y = top + inner_h // 2
        for px in range(left + 70, left + inner_w - 70, 8):
            raster.line(px, route_y, min(px + 4, left + inner_w - 70), route_y, _color(raster.depth, "dark"))
        packet_x = left + 70 + int((inner_w - 140) * component.get("value", 50) / 100)
        raster.fill(packet_x - 5, route_y - 5, 11, 11, _color(raster.depth, "accent"))
        raster.rect(packet_x - 5, route_y - 5, 11, 11, _color(raster.depth, "black"))
        raster.text(left + 16, top + 12, component.get("text", "Resource fork preserved"), _color(raster.depth, "black"), max_width=inner_w - 32)
    elif mode == "charts":
        raster.fill(left, top, inner_w, inner_h, _color(raster.depth, "black"))
        colors = ("success", "accent", "warning")
        for band, color_name in enumerate(colors):
            band_top = top + band * inner_h // 3
            band_h = inner_h // 3
            raster.line(left + 4, band_top + band_h - 5, left + inner_w - 5, band_top + band_h - 5, _color(raster.depth, "dark"))
            points = [3, 12, 8, 20, 6, 14, 4, 18, 10, 16]
            last_x, last_y = left + 8, band_top + band_h - 8 - points[0]
            for index, point in enumerate(points[1:], 1):
                next_x = left + 8 + index * max(1, (inner_w - 20) // (len(points) - 1))
                next_y = band_top + band_h - 8 - min(point, band_h - 12)
                raster.line(last_x, last_y, next_x, next_y, _color(raster.depth, color_name))
                last_x, last_y = next_x, next_y
    else:
        raster.fill(left, top, inner_w, inner_h, _color(raster.depth, "dark"))
        raster.fill(left + 8, top + 8, inner_w - 16, inner_h - 16, _color(raster.depth, "accent"))
        _triangle(raster, left + inner_w // 2 - 3, top + inner_h // 2 - 4, "right", _color(raster.depth, "white"))


def _window_widget(raster, x, y, kind):
    _bevel(raster, x, y, 13, 13)
    ink = _color(raster.depth, "dark")
    if kind == "close":
        raster.rect(x + 4, y + 4, 5, 5, ink)
    elif kind == "zoom":
        raster.rect(x + 3, y + 3, 7, 7, ink)
        raster.line(x + 4, y + 4, x + 8, y + 4, _color(raster.depth, "white"))
    else:
        raster.line(x + 3, y + 6, x + 9, y + 6, ink,)
        raster.line(x + 3, y + 7, x + 9, y + 7, ink,)


def _icon(raster, x, y, symbol):
    black = _color(raster.depth, "black")
    light = _color(raster.depth, "light")
    if symbol == "folder":
        raster.fill(x, y + 5, 24, 14, light)
        raster.rect(x, y + 5, 24, 14, black)
        raster.rect(x + 2, y + 2, 10, 5, black)
    elif symbol == "disk":
        raster.fill(x, y, 20, 22, light)
        raster.rect(x, y, 20, 22, black, 2)
        raster.rect(x + 4, y + 3, 12, 7, black)
        raster.rect(x + 5, y + 14, 10, 5, black)
    elif symbol == "warning":
        raster.line(x + 11, y, x, y + 21, black)
        raster.line(x, y + 21, x + 22, y + 21, black)
        raster.line(x + 22, y + 21, x + 11, y, black)
        raster.text(x + 9, y + 8, "!", black)
    else:
        raster.fill(x, y, 18, 23, _color(raster.depth, "white"))
        raster.rect(x, y, 18, 23, black)
        raster.line(x + 12, y, x + 17, y + 5, black)
        raster.line(x + 12, y, x + 12, y + 5, black)
        raster.line(x + 12, y + 5, x + 17, y + 5, black)


def _scrollbar(raster, x, y, width, height, disabled=False, platinum=False):
    ink = _color(raster.depth, "mid" if disabled else "black")
    raster.fill(x, y, width, height, _color(raster.depth, "light"))
    raster.rect(x, y, width, height, ink)
    if height >= width:
        button = min(width, max(8, height // 4))
        if platinum:
            _bevel(raster, x + 1, y + 1, width - 2, button - 1)
            _bevel(raster, x + 1, y + height - button, width - 2, button - 1)
        mid_x = x + width // 2
        raster.line(mid_x, y + 4, x + 3, y + button - 4, ink)
        raster.line(mid_x, y + 4, x + width - 4, y + button - 4, ink)
        raster.line(x + 3, y + height - button + 3, mid_x, y + height - 4, ink)
        raster.line(x + width - 4, y + height - button + 3, mid_x, y + height - 4, ink)
        track_h = max(0, height - 2 * button)
        thumb_h = max(button, track_h // 3)
        thumb_y = y + button + max(1, (track_h - thumb_h) // 2)
        _bevel(raster, x + 2, thumb_y, width - 4, thumb_h)
    else:
        button = min(height, max(8, width // 4))
        thumb_w = max(button, (width - 2 * button) // 3)
        thumb_x = x + button + max(1, (width - 2 * button - thumb_w) // 2)
        _bevel(raster, thumb_x, y + 2, thumb_w, height - 4)


def _tabs(raster, x, y, width, height, items, selected, disabled=False, platinum=False):
    ink = _color(raster.depth, "mid" if disabled else "black")
    tab_h = min(20, max(16, height // 4))
    pane_y = y + tab_h - 1
    if platinum:
        _bevel(raster, x, pane_y, width, height - tab_h + 1)
    else:
        raster.rect(x, pane_y, width, height - tab_h + 1, ink)
    cursor = x
    labels = items or [""]
    available = max(1, width // len(labels))
    for index, label in enumerate(labels):
        tab_w = min(available, max(46, raster.text_width(label) + 18))
        top = y if index == selected else y + 2
        tab_height = tab_h if index == selected else tab_h - 2
        if platinum:
            face = _color(raster.depth, "white" if index == selected else "light")
            raster.fill(cursor + 5, top, max(1, tab_w - 10), tab_height, face)
            raster.fill(cursor + 2, top + 4, max(1, tab_w - 4), max(1, tab_height - 4), face)
            raster.line(cursor, top + tab_height - 1, cursor + 5, top, ink)
            raster.line(cursor + 5, top, cursor + tab_w - 6, top, ink)
            raster.line(cursor + tab_w - 6, top, cursor + tab_w - 1,
                        top + tab_height - 1, ink)
        else:
            raster.fill(cursor, top, tab_w, tab_height, _color(raster.depth, "white"))
            raster.rect(cursor, top, tab_w, tab_height, ink)
        if index == selected:
            raster.line(cursor + 1, pane_y, cursor + tab_w - 2, pane_y, _color(raster.depth, "light" if platinum else "white"))
        raster.text(cursor + max(5, (tab_w - raster.text_width(label)) // 2), top + 6, label, ink, max_width=tab_w - 10)
        cursor += tab_w - 1


def _column_specs(raster, columns, content_width):
    if not columns:
        return []
    unresolved = []
    fixed = 0
    specs = []
    for index, column in enumerate(columns):
        if isinstance(column, dict):
            title = str(column.get("title", ""))
            width = column.get("width")
        else:
            title = str(column)
            width = None
        if not isinstance(width, int) or width <= 0:
            unresolved.append(index)
            width = None
        else:
            fixed += width
        specs.append([title, width])
    share = max(32, (content_width - fixed) // max(1, len(unresolved)))
    for index in unresolved:
        specs[index][1] = share
    total = sum(spec[1] for spec in specs)
    if total > content_width:
        scale = content_width / total
        for spec in specs:
            spec[1] = max(24, int(spec[1] * scale))
    return specs


def _row_values(item, specs):
    if isinstance(item, dict):
        return [str(item.get(title, "")) for title, _ in specs]
    if isinstance(item, list):
        return [str(value) for value in item]
    return [str(item)]


def _list_or_browser(raster, x, y, width, height, component, browser=False, platinum=False):
    ink = _color(raster.depth, "mid" if component.get("disabled") else "black")
    _inset(raster, x, y, width, height)
    scroll_w = 15
    content_x = x + 2
    content_w = max(1, width - scroll_w - 4)
    columns = _column_specs(raster, component.get("columns", []) if browser else [], content_w)
    header_h = 18 if columns else 0
    cursor = content_x
    for title, column_w in columns:
        if platinum:
            _bevel(raster, cursor, y + 2, column_w, header_h)
        else:
            raster.rect(cursor, y + 2, column_w, header_h, ink)
        raster.text(cursor + 4, y + 7, title, ink, max_width=column_w - 8)
        cursor += column_w
    row_h = 14
    rows_y = y + 3 + header_h
    selected_color = _color(raster.depth, "selection" if platinum and raster.depth > 1 else "black")
    visible = max(0, (height - header_h - 6) // row_h)
    for index, item in enumerate(component.get("items", [])[:visible]):
        row_y = rows_y + index * row_h
        selected = index == component.get("selected")
        if selected:
            raster.fill(content_x, row_y, content_w, row_h, selected_color)
        values = _row_values(item, columns)
        if columns:
            cell_x = content_x
            for cell_index, (_, column_w) in enumerate(columns):
                value = values[cell_index] if cell_index < len(values) else ""
                selected_ink = ink if platinum and raster.depth > 1 else _color(raster.depth, "white")
                raster.text(cell_x + 4, row_y + 4, value, selected_ink if selected else ink, max_width=column_w - 8)
                cell_x += column_w
        else:
            selected_ink = ink if platinum and raster.depth > 1 else _color(raster.depth, "white")
            raster.text(content_x + 4, row_y + 4, values[0], selected_ink if selected else ink, max_width=content_w - 8)
    _scrollbar(raster, x + width - scroll_w - 1, y + 1, scroll_w, height - 2, component.get("disabled", False), platinum)


def _progress(raster, x, y, width, height, value, platinum=False):
    if platinum:
        _inset(raster, x, y, width, height, "light")
    else:
        raster.fill(x, y, width, height, _color(raster.depth, "white"))
        raster.rect(x, y, width, height, _color(raster.depth, "black"))
    amount = max(0, min(100, value))
    fill_width = max(0, (width - 4) * amount // 100)
    if raster.depth == 1:
        raster.dither(x + 2, y + 2, fill_width, max(0, height - 4), _color(raster.depth, "black"))
    else:
        raster.fill(x + 2, y + 2, fill_width, max(0, height - 4), _color(raster.depth, "accent"))
        if fill_width > 0 and height > 4:
            raster.line(x + 2, y + 2, x + 1 + fill_width, y + 2,
                        _color(raster.depth, "white"))


def render_scene(scene, report):
    screen = scene["screen"]
    raster = Raster(screen["width"], screen["height"], screen["depth"])
    platinum = report["presentation"]["resolved_chrome"] == "appearance-manager-platinum"
    desktop = _color(raster.depth, "mid" if platinum else "white")
    raster.fill(0, 0, raster.width, raster.height, desktop)
    if raster.depth == 1 and not platinum:
        raster.dither(0, 20, raster.width, raster.height - 20, _color(raster.depth, "black"))

    raster.fill(0, 0, raster.width, 20, _color(raster.depth, "white"))
    if platinum and raster.depth > 1:
        raster.line(0, 18, raster.width - 1, 18, _color(raster.depth, "mid"))
    raster.line(0, 19, raster.width - 1, 19, _color(raster.depth, "black"))
    raster.rect(8, 5, 9, 9, _color(raster.depth, "black"))
    raster.rect(10, 7, 5, 5, _color(raster.depth, "white"))
    raster.text(28, 6, "File  Edit  View", _color(raster.depth, "black"))
    app_name = scene.get("application", "Application")
    raster.text(max(8, raster.width - raster.text_width(app_name) - 10), 6, app_name, _color(raster.depth, "black"))

    window = scene["window"]
    wx, wy, ww, wh = window["x"], window["y"], window["width"], window["height"]
    shadow_offset = 5 if platinum else 4
    raster.fill(wx + shadow_offset, wy + shadow_offset, ww, wh, _color(raster.depth, "dark"))
    content_fill = "light" if platinum else "white"
    raster.fill(wx, wy, ww, wh, _color(raster.depth, content_fill))
    raster.rect(wx, wy, ww, wh, _color(raster.depth, "black"), 2 if platinum else 1)
    title_h = 21 if platinum else 19
    if platinum:
        raster.fill(wx + 2, wy + 2, ww - 4, title_h - 2, _color(raster.depth, "light"))
        for yy in range(wy + 4, wy + title_h - 3, 3):
            raster.line(wx + 23, yy, wx + ww - 45, yy, _color(raster.depth, "mid"))
        _window_widget(raster, wx + 6, wy + 4, "close")
        _window_widget(raster, wx + ww - 36, wy + 4, "collapse")
        _window_widget(raster, wx + ww - 20, wy + 4, "zoom")
    else:
        for yy in range(wy + 4, wy + title_h - 3, 3):
            raster.line(wx + 24, yy, wx + ww - 25, yy, _color(raster.depth, "black"))
        raster.rect(wx + 6, wy + 5, 10, 10, _color(raster.depth, "black"))
    title = window.get("title", "")
    title_width = raster.text_width(title)
    title_x = wx + max(28, (ww - title_width) // 2)
    raster.fill(title_x - 4, wy + 3, title_width + 8, 11, _color(raster.depth, content_fill))
    raster.text(title_x, wy + 5, title, _color(raster.depth, "black"), max_width=ww - 70)
    raster.line(wx, wy + title_h, wx + ww - 1, wy + title_h, _color(raster.depth, "dark" if platinum else "black"))

    origin_x, origin_y = wx + 1, wy + title_h + 1
    statuses = {item["id"]: item["status"] for item in report["components"]}
    for component in scene.get("components", []):
        kind = component["type"]
        if statuses.get(component.get("id")) == "fallback-used":
            kind = component["fallback"]
        x, y = origin_x + component["x"], origin_y + component["y"]
        width, height = component.get("width", 100), component.get("height", 18)
        label = component.get("text", "")
        disabled = component.get("disabled", False)
        ink = _color(raster.depth, "mid" if disabled else "black")
        if kind == "label":
            raster.text(x, y, label, ink, max_width=width)
        elif kind == "separator":
            raster.line(x, y, x + width - 1, y, _color(raster.depth, "dark" if platinum else "mid"))
            if platinum:
                raster.line(x, y + 1, x + width - 1, y + 1, _color(raster.depth, "white"))
        elif kind in {"button", "bevel_button"}:
            _button(raster, x, y, width, height, label, component.get("default", False), disabled, platinum)
        elif kind == "popup":
            items = component.get("items", [])
            selected = component.get("selected", 0)
            popup_text = label or (str(items[selected]) if isinstance(selected, int) and 0 <= selected < len(items) else "")
            _popup(raster, x, y, width, height, popup_text, disabled, platinum)
        elif kind == "slider":
            _slider(raster, x, y, width, height, component, platinum)
        elif kind == "little_arrows":
            _little_arrows(raster, x, y, width, height, disabled)
        elif kind == "disclosure":
            _disclosure(raster, x, y, width, label, component.get("open", False), disabled)
        elif kind in {"checkbox", "radio"}:
            if kind == "checkbox":
                if platinum:
                    _inset(raster, x, y, 12, 12)
                else:
                    raster.fill(x, y, 12, 12, _color(raster.depth, "white"))
                    raster.rect(x, y, 12, 12, ink)
            else:
                raster.fill(x + 2, y + 1, 8, 10, _color(raster.depth, "white"))
                raster.line(x + 3, y, x + 8, y, ink)
                raster.line(x + 1, y + 3, x + 1, y + 8, ink)
                raster.line(x + 10, y + 3, x + 10, y + 8, ink)
                raster.line(x + 3, y + 11, x + 8, y + 11, ink)
            if component.get("checked"):
                raster.line(x + 2, y + 6, x + 5, y + 9, ink)
                raster.line(x + 5, y + 9, x + 10, y + 2, ink)
            raster.text(x + 17, y + 2, label, ink, max_width=max(0, width - 17))
        elif kind == "field":
            if platinum:
                _inset(raster, x, y, width, height)
            else:
                raster.fill(x, y, width, height, _color(raster.depth, "white"))
                raster.rect(x, y, width, height, ink)
            raster.text(x + 4, y + max(3, (height - 7) // 2), label, ink, max_width=width - 8)
        elif kind == "group":
            if platinum:
                raster.rect(x, y + 5, width, height - 5,
                            _color(raster.depth, "mid"))
                raster.line(x + 1, y + 6, x + width - 2, y + 6,
                            _color(raster.depth, "white"))
            else:
                raster.rect(x, y + 5, width, height - 5, ink)
            if label:
                raster.fill(x + 8, y, raster.text_width(label) + 8, 11, _color(raster.depth, content_fill))
                raster.text(x + 12, y + 2, label, ink)
        elif kind == "tabs":
            _tabs(raster, x, y, width, height, component.get("items", []), component.get("selected", 0), disabled, platinum)
        elif kind in {"list", "databrowser"}:
            _list_or_browser(raster, x, y, width, height, component, kind == "databrowser", platinum)
        elif kind in {"progress", "thermometer"}:
            _progress(raster, x, y, width, height, component.get("value", 0), platinum)
        elif kind == "scrollbar":
            _scrollbar(raster, x, y, width, height, disabled, platinum)
        elif kind == "placard":
            _inset(raster, x, y, width, height, "light")
            status_color = component.get("status_color")
            text_x = x + 8
            if status_color in {"accent", "success", "warning", "danger", "purple"} and raster.depth > 1:
                indicator_x = x + 8
                raster.fill(indicator_x, y + max(4, (height - 8) // 2), 8, 8, _color(raster.depth, status_color))
                raster.rect(indicator_x, y + max(4, (height - 8) // 2), 8, 8, _color(raster.depth, "dark"))
                text_x = x + 22
            raster.text(text_x, y + max(3, (height - 7) // 2), label, ink, max_width=width - (text_x - x) - 6)
        elif kind == "image_well":
            _image_well(raster, x, y, width, height, component)
        elif kind == "text_area":
            _text_area(raster, x, y, width, height, component, platinum)
        elif kind == "quickdraw_canvas":
            _quickdraw_canvas(raster, x, y, width, height, component)
        elif kind in {"icon", "system_icon"}:
            _icon(raster, x, y, component.get("symbol", "document"))
            if label:
                raster.text(x, y + 28, label, ink, max_width=width)
    return raster
