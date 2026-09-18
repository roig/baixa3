#if defined(_WIN32)
    #define SOKOL_D3D11
#elif defined(__APPLE__)
    #define SOKOL_METAL
#else
    #define SOKOL_GLCORE
#endif

#define SOKOL_NO_ENTRY
#define SOKOL_IMPL

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION

#include "ui_bridge.h"

void sx3_ui_setup(void) {
    sg_desc gfx_desc = {0};
    gfx_desc.environment = sglue_environment();
    gfx_desc.logger.func = slog_func;
    sg_setup(&gfx_desc);

    snk_desc_t nuklear_desc = {0};
    nuklear_desc.dpi_scale = sapp_dpi_scale();
    nuklear_desc.enable_set_mouse_cursor = true;
    nuklear_desc.logger.func = slog_func;
    snk_setup(&nuklear_desc);
}

void sx3_ui_shutdown(void) {
    snk_shutdown();
    sg_shutdown();
}

struct nk_context* sx3_ui_frame_begin(void) {
    return snk_new_frame();
}

void sx3_ui_frame_end(void) {
    sg_pass pass = {0};
    pass.action.colors[0].load_action = SG_LOADACTION_CLEAR;
    pass.action.colors[0].clear_value = (sg_color){0.055f, 0.065f, 0.085f, 1.0f};
    pass.swapchain = sglue_swapchain();
    sg_begin_pass(&pass);
    snk_render(sapp_width(), sapp_height());
    sg_end_pass();
    sg_commit();
}

bool sx3_ui_window_begin(struct nk_context* ctx, float width, float height, bool read_only) {
    nk_flags flags = NK_WINDOW_BORDER | NK_WINDOW_TITLE;
    if (read_only) flags |= NK_WINDOW_ROM;
    return nk_begin(ctx, "SX3Downloader", nk_rect(8, 8, width - 16, height - 16), flags);
}

void sx3_ui_window_end(struct nk_context* ctx) {
    nk_end(ctx);
}

void sx3_ui_row(struct nk_context* ctx, float height, int columns) {
    nk_layout_row_dynamic(ctx, height, columns);
}

void sx3_ui_row_ratio_begin(struct nk_context* ctx, float height, int columns) {
    nk_layout_row_begin(ctx, NK_DYNAMIC, height, columns);
}

void sx3_ui_row_ratio_push(struct nk_context* ctx, float ratio) {
    nk_layout_row_push(ctx, ratio);
}

void sx3_ui_row_ratio_end(struct nk_context* ctx) {
    nk_layout_row_end(ctx);
}

int sx3_ui_edit(struct nk_context* ctx, char* buffer, int* length, int capacity, bool read_only) {
    nk_flags flags = NK_EDIT_FIELD | NK_EDIT_SIG_ENTER;
    if (read_only) flags |= NK_EDIT_READ_ONLY;
    return (int)snk_edit_string(ctx, flags, buffer, length, capacity, nk_filter_default);
}

bool sx3_ui_button(struct nk_context* ctx, const char* label) {
    return nk_button_label(ctx, label) != 0;
}

void sx3_ui_label(struct nk_context* ctx, const char* text) {
    nk_label(ctx, text, NK_TEXT_LEFT);
}

void sx3_ui_heading(struct nk_context* ctx, const char* text) {
    nk_label(ctx, text, NK_TEXT_LEFT);
}

bool sx3_ui_checkbox(struct nk_context* ctx, const char* label, bool active) {
    nk_bool value = active ? nk_true : nk_false;
    nk_checkbox_label(ctx, label, &value);
    return value != 0;
}

bool sx3_ui_option(struct nk_context* ctx, const char* label, bool active) {
    return nk_option_label(ctx, label, active ? nk_true : nk_false) != 0;
}

void sx3_ui_progress(struct nk_context* ctx, unsigned long long current, unsigned long long maximum) {
    nk_size value = (nk_size)current;
    nk_progress(ctx, &value, (nk_size)(maximum > 0 ? maximum : 1), nk_false);
}

void sx3_ui_disable_begin(struct nk_context* ctx) {
    nk_widget_disable_begin(ctx);
}

void sx3_ui_disable_end(struct nk_context* ctx) {
    nk_widget_disable_end(ctx);
}
