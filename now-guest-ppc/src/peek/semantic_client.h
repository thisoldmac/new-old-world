#ifndef NOW_SEMANTIC_CLIENT_H
#define NOW_SEMANTIC_CLIENT_H

#include "scene.h"

void now_semantic_client_begin(unsigned long scene_generation);
void now_semantic_client_aim(unsigned long a5, int requestable);
void now_semantic_client_end(void);
void now_semantic_client_join_control(NowScene *scene, int window, int index,
                                      unsigned long window_ptr,
                                      unsigned long control);
void now_semantic_client_join_menu(NowScene *scene, int menu_row,
                                   unsigned long menu, short menu_id);

#endif /* NOW_SEMANTIC_CLIENT_H */
