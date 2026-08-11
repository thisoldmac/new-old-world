#!/usr/bin/env python3
"""Pin failure-atomic AppleEvent document descriptor construction."""

from pathlib import Path


source = (Path(__file__).parents[1] / "src/input/input_cmds.c").read_text()

assert "AEDescList  list = { typeNull, NULL };" in source, (
    "the document list must be disposable even when AECreateList fails"
)
assert "AEDesc      file_desc = { typeNull, NULL };" in source, (
    "the alias descriptor must start as a null descriptor"
)
assert "err = AECreateList(NULL, 0, false, &list);" in source, (
    "AECreateList failure must participate in the construction result"
)
assert "err = AEPutDesc(&list, 1, &file_desc);" in source, (
    "a failed list insertion must not be reported as a sent document event"
)
assert "err = AEPutParamDesc(&ae, keyDirectObject, &list);" in source, (
    "a failed direct-object attachment must not be reported as success"
)
