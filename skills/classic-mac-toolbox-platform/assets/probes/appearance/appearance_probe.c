#include <Appearance.h>
#include <Dialogs.h>
#include <Fonts.h>
#include <Gestalt.h>
#include <Menus.h>
#include <Quickdraw.h>
#include <Windows.h>

int main(void)
{
    long attributes = 0;

#if !TARGET_API_MAC_CARBON
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);
#endif

    if (Gestalt(gestaltAppearanceAttr, &attributes) == noErr &&
        (attributes & (1L << gestaltAppearanceExists)) != 0) {
        Rect bounds = { 0, 0, 20, 100 };
        if (RegisterAppearanceClient() == noErr) {
            DrawThemePlacard(&bounds, kThemeStateActive);
            UnregisterAppearanceClient();
        }
    }
    return 0;
}
