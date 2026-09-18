const std = @import("std");
const core = @import("core.zig");
const net = @import("net.zig");

const c = @cImport({
    @cInclude("ui_bridge.h");
});

const JobKind = enum { search, individual_download, mux };

const Job = struct {
    kind: JobKind,
    url: core.FixedText(2048) = .{},
};

var app_io: std.Io = undefined;
const allocator = std.heap.smp_allocator;
var url_buffer: [2048]u8 = [_]u8{0} ** 2048;
var url_length: c_int = 0;
var status_buffer: [512]u8 = [_]u8{0} ** 512;
var status_length: usize = 0;
var ffmpeg_detected = false;
var busy = std.atomic.Value(bool).init(false);
var progress_current = std.atomic.Value(u64).init(0);
var progress_total = std.atomic.Value(u64).init(1);
var page_kind: core.PageKind = .none;
var episode: core.Episode = .{};
var series: core.Series = .{};

fn setStatus(message: []const u8) void {
    status_length = @min(message.len, status_buffer.len - 1);
    @memcpy(status_buffer[0..status_length], message[0..status_length]);
    status_buffer[status_length] = 0;
}

fn setErrorStatus(err: anyerror) void {
    var buffer: [400]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Error: {s}", .{@errorName(err)}) catch "Error desconegut";
    setStatus(message);
}

fn startJob(kind: JobKind, url: []const u8) void {
    if (busy.swap(true, .acq_rel)) return;
    progress_current.store(0, .release);
    progress_total.store(1, .release);
    const job = allocator.create(Job) catch {
        busy.store(false, .release);
        setStatus("No hi ha prou memòria per iniciar la tasca.");
        return;
    };
    job.* = .{ .kind = kind };
    job.url.set(url);
    if (kind == .search) page_kind = .none;
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        allocator.destroy(job);
        busy.store(false, .release);
        setStatus("No s'ha pogut iniciar el fil de treball.");
        return;
    };
    thread.detach();
}

fn worker(job: *Job) void {
    defer allocator.destroy(job);
    defer busy.store(false, .release);
    switch (job.kind) {
        .search => {
            if (core.extractEpisodeId(job.url.slice())) |id| {
                net.fetchEpisode(allocator, app_io, id, &episode) catch |err| {
                    setErrorStatus(err);
                    return;
                };
                page_kind = .episode;
                setStatus("Episodi carregat correctament.");
            } else {
                net.fetchSeries(allocator, app_io, job.url.slice(), &series) catch |err| {
                    setErrorStatus(err);
                    return;
                };
                page_kind = .series;
                var message_buffer: [160]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &message_buffer,
                    "Sèrie carregada: {d} temporades i {d} episodis.",
                    .{ series.season_count, series.episode_count },
                ) catch "Sèrie carregada correctament.";
                setStatus(message);
            }
        },
        .individual_download => {
            net.downloadSelectedResources(
                allocator,
                app_io,
                &episode,
                .{ .current = &progress_current, .total = &progress_total },
            ) catch |err| {
                setErrorStatus(err);
                return;
            };
            setStatus("Descàrrega individual completada.");
        },
        .mux => {
            if (!ffmpeg_detected) {
                setStatus("FFmpeg no està disponible.");
                return;
            }
            net.muxSelected(
                allocator,
                app_io,
                &episode,
                .{ .current = &progress_current, .total = &progress_total },
            ) catch |err| {
                setErrorStatus(err);
                return;
            };
            setStatus("Muxing completat.");
        },
    }
}

fn init() callconv(.c) void {
    c.sx3_ui_setup();
    ffmpeg_detected = net.ffmpegAvailable(allocator, app_io);
    setStatus(if (ffmpeg_detected)
        "Introdueix una URL de 3Cat. FFmpeg detectat."
    else
        "Introdueix una URL de 3Cat. FFmpeg no detectat.");
}

fn resourceDescription(resource: *const core.Resource, buffer: []u8) [*:0]const u8 {
    const kind = switch (resource.kind) {
        .direct_video => "Vídeo complet",
        .dash_video => "Vídeo DASH",
        .dash_audio => "Àudio DASH",
        .subtitle => "Subtítols",
    };
    const result = std.fmt.bufPrintZ(buffer, "{s} · {s}", .{ kind, resource.label.slice() }) catch return "Recurs";
    return result.ptr;
}

fn drawIndividual(ctx: *c.nk_context) void {
    c.sx3_ui_row(ctx, 32, 1);
    c.sx3_ui_heading(ctx, "Descàrrega individual");
    c.sx3_ui_row(ctx, 22, 1);
    c.sx3_ui_label(ctx, "Baixa cada pista seleccionada directament. FFmpeg no intervé mai.");

    for (episode.resources[0..episode.resource_count]) |*resource| {
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_row(ctx, 25, 1);
        resource.selected_individual = c.sx3_ui_checkbox(ctx, label, resource.selected_individual);
    }

    c.sx3_ui_row(ctx, 34, 1);
    if (c.sx3_ui_button(ctx, "Descarrega els fitxers seleccionats")) {
        startJob(.individual_download, "");
    }
}

fn drawMuxing(ctx: *c.nk_context) void {
    if (!ffmpeg_detected) return;

    c.sx3_ui_row(ctx, 32, 1);
    c.sx3_ui_heading(ctx, "Muxing amb FFmpeg");
    c.sx3_ui_row(ctx, 25, 1);
    c.sx3_ui_label(ctx, "Vídeo (selecció exclusiva)");
    for (episode.resources[0..episode.resource_count], 0..) |*resource, index| {
        if (resource.kind != .dash_video) continue;
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_row(ctx, 25, 1);
        if (c.sx3_ui_option(ctx, label, resource.selected_mux)) {
            for (episode.resources[0..episode.resource_count]) |*candidate| {
                if (candidate.kind == .dash_video) candidate.selected_mux = false;
            }
            episode.resources[index].selected_mux = true;
        }
    }

    c.sx3_ui_row(ctx, 25, 1);
    c.sx3_ui_label(ctx, "Àudios (multiselecció i una pista per defecte)");
    for (episode.resources[0..episode.resource_count], 0..) |*resource, index| {
        if (resource.kind != .dash_audio) continue;
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_row_ratio_begin(ctx, 25, 2);
        c.sx3_ui_row_ratio_push(ctx, 0.72);
        resource.selected_mux = c.sx3_ui_checkbox(ctx, label, resource.selected_mux);
        if (!resource.selected_mux) resource.default_audio = false;
        c.sx3_ui_row_ratio_push(ctx, 0.28);
        if (c.sx3_ui_option(ctx, "Àudio per defecte", resource.default_audio)) {
            for (episode.resources[0..episode.resource_count]) |*candidate| {
                if (candidate.kind == .dash_audio) candidate.default_audio = false;
            }
            episode.resources[index].selected_mux = true;
            episode.resources[index].default_audio = true;
        }
        c.sx3_ui_row_ratio_end(ctx);
    }

    var subtitle_count: usize = 0;
    for (episode.resources[0..episode.resource_count]) |*resource| {
        if (resource.kind == .subtitle) subtitle_count += 1;
    }
    var subtitle_label_buffer: [128]u8 = undefined;
    const subtitle_label = std.fmt.bufPrintZ(
        &subtitle_label_buffer,
        "Incloure subtítols ({d} pista/es)",
        .{subtitle_count},
    ) catch "Incloure subtítols";
    c.sx3_ui_row(ctx, 25, 1);
    episode.include_subtitles_mux = c.sx3_ui_checkbox(
        ctx,
        subtitle_label.ptr,
        episode.include_subtitles_mux and subtitle_count > 0,
    );

    c.sx3_ui_row(ctx, 34, 1);
    if (c.sx3_ui_button(ctx, "Descarrega i fes muxing")) {
        startJob(.mux, "");
    }
}

fn drawEpisode(ctx: *c.nk_context) void {
    c.sx3_ui_row(ctx, 30, 1);
    c.sx3_ui_heading(ctx, episode.title.c());
    drawIndividual(ctx);
    drawMuxing(ctx);
}

fn setUrlInput(value: []const u8) void {
    const length = @min(value.len, url_buffer.len - 1);
    @memcpy(url_buffer[0..length], value[0..length]);
    url_buffer[length] = 0;
    url_length = @intCast(length);
}

fn drawSeries(ctx: *c.nk_context) void {
    c.sx3_ui_row(ctx, 30, 1);
    c.sx3_ui_heading(ctx, if (series.title.len > 0) series.title.c() else "Sèrie");
    c.sx3_ui_row(ctx, 24, 1);
    c.sx3_ui_label(ctx, "Selecciona un episodi per veure'n les pistes i les opcions de descàrrega.");

    for (series.seasons[0..series.season_count]) |*season| {
        var season_buffer: [128]u8 = undefined;
        const season_label = std.fmt.bufPrintZ(
            &season_buffer,
            "Temporada {d} · {d} episodis",
            .{ season.number, season.episode_count },
        ) catch "Temporada";
        c.sx3_ui_row(ctx, 30, 1);
        c.sx3_ui_heading(ctx, season_label.ptr);

        const end = season.first_episode + season.episode_count;
        for (series.episodes[season.first_episode..end]) |*item| {
            var episode_buffer: [320]u8 = undefined;
            const episode_label = if (item.number > 0)
                std.fmt.bufPrintZ(&episode_buffer, "Capítol {d} · {s}", .{ item.number, item.title.slice() }) catch "Obre l'episodi"
            else
                std.fmt.bufPrintZ(&episode_buffer, "{s}", .{item.title.slice()}) catch "Obre l'episodi";
            c.sx3_ui_row(ctx, 30, 1);
            if (c.sx3_ui_button(ctx, episode_label.ptr)) {
                setUrlInput(item.url.slice());
                startJob(.search, item.url.slice());
                return;
            }
        }
    }
}

fn frame() callconv(.c) void {
    const is_busy = busy.load(.acquire);
    const ctx = c.sx3_ui_frame_begin();
    const width: f32 = @floatFromInt(c.sapp_width());
    const height: f32 = @floatFromInt(c.sapp_height());
    if (c.sx3_ui_window_begin(ctx, width, height, is_busy)) {
        c.sx3_ui_row_ratio_begin(ctx, 34, 2);
        c.sx3_ui_row_ratio_push(ctx, 0.82);
        _ = c.sx3_ui_edit(ctx, &url_buffer, &url_length, url_buffer.len, is_busy);
        c.sx3_ui_row_ratio_push(ctx, 0.18);
        if (c.sx3_ui_button(ctx, "Cerca") and !is_busy) {
            startJob(.search, url_buffer[0..@intCast(url_length)]);
        }
        c.sx3_ui_row_ratio_end(ctx);

        c.sx3_ui_row(ctx, 28, 1);
        c.sx3_ui_label(ctx, if (is_busy) "Processant... La interfície és temporalment de només lectura." else @ptrCast(&status_buffer));
        if (is_busy) {
            c.sx3_ui_row(ctx, 22, 1);
            c.sx3_ui_progress(
                ctx,
                progress_current.load(.acquire),
                progress_total.load(.acquire),
            );
        }

        if (!is_busy) switch (page_kind) {
            .episode => drawEpisode(ctx),
            .series => drawSeries(ctx),
            .none => {},
        };
    }
    c.sx3_ui_window_end(ctx);
    c.sx3_ui_frame_end();
}

fn cleanup() callconv(.c) void {
    c.sx3_ui_shutdown();
}

fn event(ev: [*c]const c.sapp_event) callconv(.c) void {
    _ = c.snk_handle_event(ev);
}

pub fn main(init_data: std.process.Init) void {
    app_io = init_data.io;
    var desc: c.sapp_desc = std.mem.zeroes(c.sapp_desc);
    desc.init_cb = init;
    desc.frame_cb = frame;
    desc.cleanup_cb = cleanup;
    desc.event_cb = event;
    desc.width = 1100;
    desc.height = 760;
    desc.high_dpi = true;
    desc.enable_clipboard = true;
    desc.window_title = "SX3Downloader";
    desc.logger.func = c.slog_func;
    c.sapp_run(&desc);
}
