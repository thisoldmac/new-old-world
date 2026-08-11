"""Optional MLX adapter for the preserved NOW Web layout model.

The helper invokes this as a command contract: one JSON document on stdin,
one validated reorder plan on stdout. The model never receives URLs to write
and never writes HTML. Unknown or omitted IDs cannot remove content because
the adapter deduplicates its choices and appends every original block it did
not name.

`mlx-lm` and the model are deliberately optional. Neither is installed or
downloaded here; the host module accepts an explicit local model directory.
"""

from __future__ import annotations

import argparse
import json
import re
import sys


PROMPT = """You are the layout editor recreating a modern page for a classic
Macintosh browser with no CSS. The page is represented by blocks B1, B2, and
so on. Output only a compact layout plan. Use NAV: for short navigation runs,
# headings for sections, and rows of block IDs. A | may divide columns. Put
main content first and housekeeping last. Never invent a block ID.

PAGE TITLE: {title}

BLOCKS:
{blocks}
"""


def order_from_output(raw: str, identifiers: list[str]) -> list[str]:
    """Model DSL to the strict NOW order schema, preserving every block."""
    by_number = {index + 1: value for index, value in enumerate(identifiers)}
    order: list[str] = []
    seen: set[str] = set()
    for match in re.finditer(r"\bB(\d+)\b", raw, flags=re.IGNORECASE):
        identifier = by_number.get(int(match.group(1)))
        if identifier is not None and identifier not in seen:
            seen.add(identifier)
            order.append(identifier)
    for identifier in identifiers:
        if identifier not in seen:
            order.append(identifier)
    return order


def generate(model_path: str, prompt: str, max_tokens: int) -> str:
    try:
        from mlx_lm import generate as mlx_generate, load
    except ImportError as exc:
        raise RuntimeError("mlx-lm is not installed in this Python environment") from exc
    model, tokenizer = load(model_path)
    messages = [{"role": "user", "content": prompt}]
    try:
        encoded = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False)
    except (TypeError, ValueError):
        encoded = tokenizer.apply_chat_template(messages,
                                                 add_generation_prompt=True)
    return mlx_generate(model, tokenizer, prompt=encoded,
                        max_tokens=max_tokens)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="NOW Web MLX layout planner")
    parser.add_argument("--model", required=True)
    parser.add_argument("--max-tokens", type=int, default=1200)
    args = parser.parse_args(argv)
    payload = json.load(sys.stdin)
    if payload.get("version") != "now-web-layout-plan/1":
        raise ValueError("unsupported planner input version")
    blocks = payload.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        raise ValueError("planner input needs blocks")
    identifiers = [item["id"] for item in blocks]
    previews = "\n".join("B%d: %s" % (index + 1, item.get("text", "")[:512])
                         for index, item in enumerate(blocks))
    raw = generate(args.model,
                   PROMPT.format(title=payload.get("title", ""),
                                 blocks=previews),
                   max(64, min(args.max_tokens, 2500)))
    json.dump({"version": "now-web-layout-plan/1",
               "order": order_from_output(raw, identifiers)}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
