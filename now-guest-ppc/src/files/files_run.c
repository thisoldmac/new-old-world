#include "files_run.h"

#include "files_layout.h"

void files_run(const WorkshopSceneWriter *writer, const Rect *where,
               Boolean right_align, Boolean emphasized, short trunc,
               const char *line)
{
    Str255 text;
    short room;

    if (where == NULL || line == NULL) {
        return;
    }
    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, line, where,
                           true);
        return;
    }
    UseThemeFont(emphasized ? kThemeSmallEmphasizedSystemFont
                            : kThemeSmallSystemFont,
                 smSystemScript);
    CopyCStringToPascal(line, text);
    room = (short)(where->right - where->left);
    if (room > 0) {
        TruncString(room, text, (TruncCode)trunc);
    }
    MoveTo(right_align ? (short)(where->right - StringWidth(text))
                       : where->left,
           files_layout_baseline(where));
    DrawString(text);
}
