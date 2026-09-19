#if defined(_WIN32)
    #define SOKOL_D3D11
#elif defined(__APPLE__)
    #define SOKOL_METAL
#else
    #define SOKOL_GLCORE
#endif

#define SOKOL_NO_ENTRY
#define SOKOL_IMPL

#include "ui_bridge.h"
#include "imgui.h"
#include "imgui_internal.h"
#include "util/sokol_imgui.h"

#include <float.h>

static void sx3_make_window_fixed_size(void) {
    #if defined(_WIN32)
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (hwnd) {
        LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        style &= ~((LONG_PTR)(WS_THICKFRAME | WS_MAXIMIZEBOX));
        SetWindowLongPtrW(hwnd, GWL_STYLE, style);
        SetWindowPos(
            hwnd,
            NULL,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
        );
    }
    #elif defined(__APPLE__)
    NSWindow* window = (__bridge NSWindow*)sapp_macos_get_window();
    if (window) {
        [window setStyleMask:([window styleMask] & ~NSWindowStyleMaskResizable)];
    }
    #elif defined(__linux__)
    Display* display = (Display*)sapp_x11_get_display();
    const Window window = (Window)(uintptr_t)sapp_x11_get_window();
    if (display && window) {
        XSizeHints hints = {};
        hints.flags = PMinSize | PMaxSize;
        hints.min_width = hints.max_width = sapp_width();
        hints.min_height = hints.max_height = sapp_height();
        XSetWMNormalHints(display, window, &hints);
        XFlush(display);
    }
    #endif
}

extern "C" void sx3_ui_setup(void) {
    sg_desc gfx_desc = {};
    gfx_desc.environment = sglue_environment();
    gfx_desc.logger.func = slog_func;
    sg_setup(&gfx_desc);

    simgui_desc_t imgui_desc = {};
    imgui_desc.logger.func = slog_func;
    simgui_setup(&imgui_desc);

    ImGui::StyleColorsDark();
    sx3_make_window_fixed_size();
}

extern "C" void sx3_ui_shutdown(void) {
    simgui_shutdown();
    sg_shutdown();
}

extern "C" void sx3_ui_frame_begin(void) {
    simgui_frame_desc_t frame_desc = {};
    frame_desc.width = sapp_width();
    frame_desc.height = sapp_height();
    frame_desc.delta_time = sapp_frame_duration();
    frame_desc.dpi_scale = sapp_dpi_scale();
    simgui_new_frame(&frame_desc);
}

extern "C" void sx3_ui_frame_end(void) {
    sg_pass pass = {};
    pass.action.colors[0].load_action = SG_LOADACTION_CLEAR;
    pass.action.colors[0].clear_value = (sg_color){0.035f, 0.042f, 0.055f, 1.0f};
    pass.swapchain = sglue_swapchain();
    sg_begin_pass(&pass);
    simgui_render();
    sg_end_pass();
    sg_commit();
}

extern "C" bool sx3_ui_handle_event(const sapp_event* event) {
    return simgui_handle_event(event);
}

extern "C" bool sx3_ui_window_begin(void) {
    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->WorkPos);
    ImGui::SetNextWindowSize(viewport->WorkSize);
    const ImGuiWindowFlags flags =
        ImGuiWindowFlags_NoTitleBar |
        ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoCollapse |
        ImGuiWindowFlags_NoSavedSettings |
        ImGuiWindowFlags_NoScrollbar |
        ImGuiWindowFlags_NoScrollWithMouse |
        ImGuiWindowFlags_NoBringToFrontOnFocus;
    return ImGui::Begin("Baixa3##main", nullptr, flags);
}

extern "C" void sx3_ui_window_end(void) {
    ImGui::End();
}

extern "C" bool sx3_ui_content_begin(const char* id) {
    return ImGui::BeginChild(
        id,
        ImVec2(0.0f, 0.0f),
        ImGuiChildFlags_None,
        ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse
    );
}

extern "C" void sx3_ui_content_end(void) {
    ImGui::EndChild();
}

extern "C" bool sx3_ui_panel_begin(const char* id, float height) {
    return ImGui::BeginChild(
        id,
        ImVec2(0.0f, height),
        ImGuiChildFlags_Borders,
        ImGuiWindowFlags_AlwaysVerticalScrollbar
    );
}

extern "C" void sx3_ui_panel_end(void) {
    ImGui::EndChild();
}

extern "C" bool sx3_ui_tree_begin(const char* label, bool default_open) {
    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_None;
    if (default_open) {
        flags |= ImGuiTreeNodeFlags_DefaultOpen;
    }
    return ImGui::TreeNodeEx(label, flags);
}

extern "C" void sx3_ui_tree_end(void) {
    ImGui::TreePop();
}

extern "C" void sx3_ui_same_line(void) {
    ImGui::SameLine();
}

extern "C" void sx3_ui_spacing(void) {
    ImGui::Spacing();
}

extern "C" void sx3_ui_separator(void) {
    ImGui::Separator();
}

extern "C" void sx3_ui_set_next_item_width(float width) {
    ImGui::SetNextItemWidth(width);
}

extern "C" bool sx3_ui_input_text(char* buffer, size_t capacity, bool read_only) {
    ImGuiInputTextFlags flags = ImGuiInputTextFlags_EnterReturnsTrue;
    if (read_only) {
        flags |= ImGuiInputTextFlags_ReadOnly;
    }
    return ImGui::InputText("##url", buffer, capacity, flags);
}

extern "C" bool sx3_ui_button(const char* label) {
    return ImGui::Button(label);
}

extern "C" bool sx3_ui_button_full_width(const char* label) {
    return ImGui::Button(label, ImVec2(-FLT_MIN, 0.0f));
}

extern "C" void sx3_ui_label(const char* text) {
    ImGui::TextWrapped("%s", text);
}

extern "C" void sx3_ui_heading(const char* text) {
    ImGui::SeparatorText(text);
}

extern "C" bool sx3_ui_checkbox(const char* label, bool active) {
    bool value = active;
    ImGui::Checkbox(label, &value);
    return value;
}

extern "C" bool sx3_ui_checkbox_mixed(const char* label, bool active, bool mixed) {
    bool value = active;
    if (mixed) {
        ImGui::PushItemFlag(ImGuiItemFlags_MixedValue, true);
    }
    ImGui::Checkbox(label, &value);
    if (mixed) {
        ImGui::PopItemFlag();
    }
    return value;
}

extern "C" bool sx3_ui_option(const char* label, bool active) {
    return ImGui::RadioButton(label, active);
}

extern "C" void sx3_ui_progress(unsigned long long current, unsigned long long maximum) {
    const float fraction = maximum > 0 ? (float)((double)current / (double)maximum) : 0.0f;
    ImGui::ProgressBar(fraction, ImVec2(-FLT_MIN, 0.0f));
}

extern "C" void sx3_ui_disable_begin(bool disabled) {
    ImGui::BeginDisabled(disabled);
}

extern "C" void sx3_ui_disable_end(bool disabled) {
    ImGui::EndDisabled();
    (void)disabled;
}

extern "C" bool sx3_ui_tab_bar_begin(const char* id) {
    return ImGui::BeginTabBar(id, ImGuiTabBarFlags_None);
}

extern "C" void sx3_ui_tab_bar_end(void) {
    ImGui::EndTabBar();
}

extern "C" bool sx3_ui_tab_begin(const char* label) {
    return ImGui::BeginTabItem(label);
}

extern "C" void sx3_ui_tab_end(void) {
    ImGui::EndTabItem();
}

extern "C" bool sx3_ui_combo_begin(const char* label, const char* preview) {
    const ImGuiStyle& style = ImGui::GetStyle();
    const float max_height =
        ImGui::GetTextLineHeightWithSpacing() * 24.0f + style.WindowPadding.y * 2.0f;
    ImGui::SetNextWindowSizeConstraints(
        ImVec2(0.0f, 0.0f),
        ImVec2(FLT_MAX, max_height)
    );
    return ImGui::BeginCombo(label, preview);
}

extern "C" void sx3_ui_combo_end(void) {
    ImGui::EndCombo();
}

extern "C" bool sx3_ui_selectable(const char* label, bool selected) {
    return ImGui::Selectable(label, selected);
}

extern "C" void sx3_ui_push_id(int id) {
    ImGui::PushID(id);
}

extern "C" void sx3_ui_pop_id(void) {
    ImGui::PopID();
}
