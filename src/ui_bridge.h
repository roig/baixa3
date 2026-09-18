#pragma once

#include <stdbool.h>
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_log.h"
#include "nuklear.h"
#include "util/sokol_nuklear.h"

void sx3_ui_setup(void);
void sx3_ui_shutdown(void);
struct nk_context* sx3_ui_frame_begin(void);
void sx3_ui_frame_end(void);
bool sx3_ui_window_begin(struct nk_context* ctx, float width, float height, bool read_only);
void sx3_ui_window_end(struct nk_context* ctx);
void sx3_ui_row(struct nk_context* ctx, float height, int columns);
void sx3_ui_row_ratio_begin(struct nk_context* ctx, float height, int columns);
void sx3_ui_row_ratio_push(struct nk_context* ctx, float ratio);
void sx3_ui_row_ratio_end(struct nk_context* ctx);
int sx3_ui_edit(struct nk_context* ctx, char* buffer, int* length, int capacity, bool read_only);
bool sx3_ui_button(struct nk_context* ctx, const char* label);
void sx3_ui_label(struct nk_context* ctx, const char* text);
void sx3_ui_heading(struct nk_context* ctx, const char* text);
bool sx3_ui_checkbox(struct nk_context* ctx, const char* label, bool active);
bool sx3_ui_option(struct nk_context* ctx, const char* label, bool active);
void sx3_ui_progress(struct nk_context* ctx, unsigned long long current, unsigned long long maximum);
void sx3_ui_disable_begin(struct nk_context* ctx);
void sx3_ui_disable_end(struct nk_context* ctx);
