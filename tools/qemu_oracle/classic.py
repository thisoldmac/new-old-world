"""Bounded decoders for public classic Mac Window/Dialog/Control records."""

from __future__ import annotations

from .qmp import OracleError


def u16(data: bytes, offset: int = 0) -> int:
    return int.from_bytes(data[offset:offset + 2], "big")


def s16(data: bytes, offset: int = 0) -> int:
    value = u16(data, offset)
    return value - 0x10000 if value & 0x8000 else value


def u32(data: bytes, offset: int = 0) -> int:
    return int.from_bytes(data[offset:offset + 4], "big")


def address(value: int) -> str:
    return f"0x{value:08x}"


def read_handle(memory, handle: int) -> int:
    if not handle or handle & 1:
        raise OracleError(f"invalid handle {address(handle)}")
    pointer = u32(memory.read(handle, 4))
    if not pointer or pointer & 1:
        raise OracleError(
            f"handle {address(handle)} has invalid master pointer "
            f"{address(pointer)}")
    return pointer


def read_pstring_handle(memory, handle: int) -> str:
    if not handle:
        return ""
    pointer = read_handle(memory, handle)
    raw = memory.read(pointer, 256)
    length = raw[0]
    return raw[1:1 + length].decode("mac_roman", errors="replace")


def _rect(raw: bytes, offset: int) -> dict:
    return {
        "top": s16(raw, offset),
        "left": s16(raw, offset + 2),
        "bottom": s16(raw, offset + 4),
        "right": s16(raw, offset + 6),
    }


def decode_control(memory, handle: int) -> dict:
    record_address = read_handle(memory, handle)
    raw = memory.read(record_address, 296)
    title_length = raw[40]
    data_handle = u32(raw, 28)
    value = {
        "handle": address(handle),
        "record": address(record_address),
        "next": address(u32(raw, 0)) if u32(raw, 0) else None,
        "owner": address(u32(raw, 4)),
        "rect": _rect(raw, 8),
        "visible": raw[16] != 0,
        "enabled": raw[17] != 255,
        "value": s16(raw, 18),
        "minimum": s16(raw, 20),
        "maximum": s16(raw, 22),
        "definition": address(u32(raw, 24)),
        "dataHandle": address(data_handle) if data_handle else None,
        "action": address(u32(raw, 32)) if u32(raw, 32) else None,
        "refCon": u32(raw, 36),
        "title": raw[41:41 + title_length].decode(
            "mac_roman", errors="replace"),
    }
    if data_handle:
        try:
            data_pointer = read_handle(memory, data_handle)
            value["dataPointer"] = address(data_pointer)
            value["dataPrefixHex"] = memory.read(data_pointer, 48).hex()
        except OracleError as exc:
            value["dataError"] = str(exc)
    return value


def decode_controls(memory, first: int, limit: int = 128) -> tuple[list, bool]:
    controls = []
    seen = set()
    handle = first
    while handle and len(controls) < limit and handle not in seen:
        seen.add(handle)
        try:
            control = decode_control(memory, handle)
        except OracleError as exc:
            controls.append({"handle": address(handle), "error": str(exc)})
            return controls, False
        controls.append(control)
        next_value = control["next"]
        handle = int(next_value, 16) if next_value else 0
    return controls, handle == 0


def _dialog_kind(raw_type: int) -> str:
    item_type = raw_type & 0x7F
    base = item_type & ~3
    if base == 4:
        return ("pushButton", "checkBox", "radioButton", "resourceControl")[
            item_type & 3]
    return {
        8: "staticText",
        16: "editText",
        32: "icon",
        64: "picture",
    }.get(item_type, "userItem")


def decode_dialog(memory, raw: bytes) -> dict:
    items_handle = u32(raw, 156)
    result = {
        "itemsHandle": address(items_handle) if items_handle else None,
        "textHandle": address(u32(raw, 160)) if u32(raw, 160) else None,
        "editItem": s16(raw, 164) + 1,
        "defaultItem": s16(raw, 168),
        "items": [],
    }
    if not items_handle:
        return result
    try:
        cursor = read_handle(memory, items_handle)
        count = s16(memory.read(cursor, 2)) + 1
        if count < 0 or count > 128:
            raise OracleError(f"invalid DITL item count {count}")
        cursor += 2
        for number in range(1, count + 1):
            fixed = memory.read(cursor, 14)
            length = fixed[13]
            payload = memory.read(cursor + 14, length)
            raw_type = fixed[12]
            item = {
                "number": number,
                "handle": address(u32(fixed, 0)) if u32(fixed, 0) else None,
                "rect": _rect(fixed, 4),
                "rawType": raw_type,
                "kind": _dialog_kind(raw_type),
                "enabled": (raw_type & 0x80) == 0,
            }
            if item["kind"] == "resourceControl" and length >= 2:
                item["resourceID"] = s16(payload)
            elif item["kind"] in ("pushButton", "checkBox", "radioButton",
                                   "staticText", "editText"):
                item["text"] = payload.decode("mac_roman", errors="replace")
            elif payload:
                item["payloadHex"] = payload.hex()
            result["items"].append(item)
            size = 14 + length
            cursor += size + (size & 1)
    except OracleError as exc:
        result["error"] = str(exc)
    return result


def decode_window(memory, pointer: int) -> dict:
    raw = memory.read(pointer, 170)
    kind = s16(raw, 108)
    title_handle = u32(raw, 134)
    control_list = u32(raw, 140)
    result = {
        "address": address(pointer),
        "kind": kind,
        "visible": raw[110] != 0,
        "titleHandle": address(title_handle) if title_handle else None,
        "title": read_pstring_handle(memory, title_handle),
        "controlList": address(control_list) if control_list else None,
        "next": address(u32(raw, 144)) if u32(raw, 144) else None,
    }
    controls, complete = decode_controls(memory, control_list)
    result["controls"] = controls
    result["controlsComplete"] = complete
    if kind == 2:
        result["dialog"] = decode_dialog(memory, raw)
    return result


def build_snapshot(memory, expected_app: str) -> dict:
    low = memory.read(0x900, 0x200)
    name_length = min(low[0x10], 31)
    actual = low[0x11:0x11 + name_length].decode(
        "mac_roman", errors="replace")
    if actual.casefold() != expected_app.casefold():
        raise OracleError(
            f"context changed while stopped: expected {expected_app!r}, "
            f"got {actual!r}")
    head = u32(low, 0xD6)
    result = {
        "currentApp": actual,
        "currentA5": address(u32(low, 4)),
        "currentStackBase": address(u32(low, 8)),
        "windowList": address(head) if head else None,
        "windows": [],
        "windowsComplete": True,
    }
    seen = set()
    pointer = head
    while pointer and len(result["windows"]) < 64 and pointer not in seen:
        seen.add(pointer)
        try:
            window = decode_window(memory, pointer)
        except OracleError as exc:
            result["windows"].append(
                {"address": address(pointer), "error": str(exc)})
            result["windowsComplete"] = False
            break
        result["windows"].append(window)
        next_value = window["next"]
        pointer = int(next_value, 16) if next_value else 0
    if pointer:
        result["windowsComplete"] = False
    return result
