#pragma once

#include <stdbool.h>
#include <stddef.h>
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_log.h"

#ifdef __cplusplus
extern "C" {
#endif

void sx3_ui_setup(void);
void sx3_ui_shutdown(void);
void sx3_ui_frame_begin(void);
void sx3_ui_frame_end(void);
bool sx3_ui_handle_event(const sapp_event* event);

bool sx3_ui_window_begin(void);
void sx3_ui_window_end(void);
bool sx3_ui_content_begin(const char* id);
void sx3_ui_content_end(void);
bool sx3_ui_panel_begin(const char* id, float height);
void sx3_ui_panel_end(void);
bool sx3_ui_tree_begin(const char* label, bool default_open);
void sx3_ui_tree_end(void);
void sx3_ui_same_line(void);
void sx3_ui_spacing(void);
void sx3_ui_separator(void);
void sx3_ui_set_next_item_width(float width);
bool sx3_ui_input_text(char* buffer, size_t capacity, bool read_only);
bool sx3_ui_button(const char* label);
bool sx3_ui_button_full_width(const char* label);
void sx3_ui_label(const char* text);
void sx3_ui_heading(const char* text);
bool sx3_ui_checkbox(const char* label, bool active);
bool sx3_ui_checkbox_mixed(const char* label, bool active, bool mixed);
bool sx3_ui_option(const char* label, bool active);
void sx3_ui_progress(unsigned long long current, unsigned long long maximum);
void sx3_ui_disable_begin(bool disabled);
void sx3_ui_disable_end(bool disabled);
bool sx3_ui_tab_bar_begin(const char* id);
void sx3_ui_tab_bar_end(void);
bool sx3_ui_tab_begin(const char* label);
void sx3_ui_tab_end(void);
void sx3_ui_push_id(int id);
void sx3_ui_pop_id(void);

#ifdef __cplusplus
}
#endif
