const std = @import("std");
const core = @import("core.zig");
const net = @import("net.zig");

const c = @cImport({
    @cInclude("ui_bridge.h");
});

const app_version = "0.2.1";
const app_display_name = "Baixa3 · v" ++ app_version;

const JobKind = enum {
    catalog,
    search,
    individual_download,
    mux,
    series_individual_download,
    series_mux,
};

const Job = struct {
    kind: JobKind,
    url: core.FixedText(2048) = .{},
};

var app_io: std.Io = undefined;
const allocator = std.heap.smp_allocator;
var url_buffer: [2048]u8 = [_]u8{0} ** 2048;
var url_length: usize = 0;
var status_buffer: [512]u8 = [_]u8{0} ** 512;
var status_length: usize = 0;
var ffmpeg_detected = false;
var busy = std.atomic.Value(bool).init(false);
var progress_current = std.atomic.Value(u64).init(0);
var progress_total = std.atomic.Value(u64).init(1);
var page_kind: core.PageKind = .none;
var catalog: core.Catalog = .{};
var catalog_ready = std.atomic.Value(bool).init(false);
var catalog_selected_index: ?usize = null;
var episode: core.Episode = .{};
var series: core.Series = .{};
var series_profile: core.Episode = .{};
var batch_download_complete_video = true;
var batch_download_extra_files = false;
const batch_progress_units_per_episode: u64 = 1000;

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
    switch (kind) {
        .catalog => {
            catalog_ready.store(false, .release);
            setStatus("Carregant tots els títols de 3Cat...");
        },
        .search => {
            page_kind = .none;
            setStatus("Cercant contingut...");
        },
        .individual_download => setStatus("Descarregant els fitxers seleccionats..."),
        .mux => setStatus("Descarregant i fent muxing..."),
        .series_individual_download => setStatus("Preparant la descàrrega dels episodis seleccionats..."),
        .series_mux => setStatus("Preparant el muxing dels episodis seleccionats..."),
    }
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        allocator.destroy(job);
        busy.store(false, .release);
        setStatus("No s'ha pogut iniciar el fil de treball.");
        return;
    };
    thread.detach();
}

fn selectedSeriesEpisodeCount() usize {
    var count: usize = 0;
    for (series.episodes[0..series.episode_count]) |item| {
        if (item.selected) count += 1;
    }
    return count;
}

fn selectedEpisodeCount(first: usize, end: usize) usize {
    var count: usize = 0;
    for (series.episodes[first..end]) |item| {
        if (item.selected) count += 1;
    }
    return count;
}

fn setEpisodeSelection(first: usize, end: usize, selected: bool) void {
    for (series.episodes[first..end]) |*item| item.selected = selected;
}

fn batchOutputDirectory(item: *const core.EpisodeSummary, buffer: []u8) ![]const u8 {
    for (series.seasons[0..series.season_count]) |season| {
        if (season.number == item.season) {
            return net.seriesOutputDirectory(
                series.title.slice(),
                season.number,
                season.is_virtual,
                buffer,
            );
        }
    }
    return error.SeasonNotFound;
}

fn unsignedDifference(left: u64, right: u64) u64 {
    return if (left >= right) left - right else right - left;
}

fn applyIndividualBatchSettings(target: *core.Episode) void {
    for (target.resources[0..target.resource_count]) |*resource| {
        if (resource.kind == .direct_video) {
            resource.selected_individual = batch_download_complete_video and resource.selected_individual;
        } else {
            resource.selected_individual = batch_download_extra_files;
        }
    }
}

fn applyMuxProfile(profile: *const core.Episode, target: *core.Episode) void {
    for (target.resources[0..target.resource_count]) |*resource| {
        resource.selected_mux = false;
        resource.default_audio = false;
    }

    var wanted_video: ?*const core.Resource = null;
    for (profile.resources[0..profile.resource_count]) |*resource| {
        if (resource.kind == .dash_video and resource.selected_mux) {
            wanted_video = resource;
            break;
        }
    }
    if (wanted_video) |wanted| {
        var best_index: ?usize = null;
        var best_height_difference: u64 = std.math.maxInt(u64);
        var best_bandwidth_difference: u64 = std.math.maxInt(u64);
        for (target.resources[0..target.resource_count], 0..) |*candidate, index| {
            if (candidate.kind != .dash_video) continue;
            const height_difference = unsignedDifference(candidate.height, wanted.height);
            const bandwidth_difference = unsignedDifference(candidate.bandwidth, wanted.bandwidth);
            if (best_index == null or
                height_difference < best_height_difference or
                (height_difference == best_height_difference and bandwidth_difference < best_bandwidth_difference))
            {
                best_index = index;
                best_height_difference = height_difference;
                best_bandwidth_difference = bandwidth_difference;
            }
        }
        if (best_index) |index| target.resources[index].selected_mux = true;
    }

    for (profile.resources[0..profile.resource_count]) |*wanted| {
        if (wanted.kind != .dash_audio or !wanted.selected_mux) continue;
        var best_index: ?usize = null;
        var best_language_match = false;
        var best_bandwidth_difference: u64 = std.math.maxInt(u64);
        for (target.resources[0..target.resource_count], 0..) |*candidate, index| {
            if (candidate.kind != .dash_audio or candidate.selected_mux) continue;
            const language_match = std.mem.eql(u8, candidate.language.slice(), wanted.language.slice());
            const bandwidth_difference = unsignedDifference(candidate.bandwidth, wanted.bandwidth);
            if (best_index == null or
                (language_match and !best_language_match) or
                (language_match == best_language_match and bandwidth_difference < best_bandwidth_difference))
            {
                best_index = index;
                best_language_match = language_match;
                best_bandwidth_difference = bandwidth_difference;
            }
        }
        if (best_index) |index| target.resources[index].selected_mux = true;
    }

    var wanted_default: ?*const core.Resource = null;
    for (profile.resources[0..profile.resource_count]) |*resource| {
        if (resource.kind == .dash_audio and resource.default_audio) {
            wanted_default = resource;
            break;
        }
    }
    if (wanted_default) |wanted| {
        var best_index: ?usize = null;
        var best_language_match = false;
        var best_bandwidth_difference: u64 = std.math.maxInt(u64);
        for (target.resources[0..target.resource_count], 0..) |*candidate, index| {
            if (candidate.kind != .dash_audio or !candidate.selected_mux) continue;
            const language_match = std.mem.eql(u8, candidate.language.slice(), wanted.language.slice());
            const bandwidth_difference = unsignedDifference(candidate.bandwidth, wanted.bandwidth);
            if (best_index == null or
                (language_match and !best_language_match) or
                (language_match == best_language_match and bandwidth_difference < best_bandwidth_difference))
            {
                best_index = index;
                best_language_match = language_match;
                best_bandwidth_difference = bandwidth_difference;
            }
        }
        if (best_index) |index| target.resources[index].default_audio = true;
    }
    target.include_subtitles_mux = profile.include_subtitles_mux;
}

fn setBatchItemStatus(action: []const u8, current: usize, total: usize, title: []const u8) void {
    var buffer: [500]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s} {d}/{d}: {s}",
        .{ action, current, total, title },
    ) catch action;
    setStatus(message);
}

fn setBatchResultStatus(action: []const u8, completed: usize, failed: usize) void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s}: {d} episodis completats, {d} amb error.",
        .{ action, completed, failed },
    ) catch action;
    setStatus(message);
}

fn resetBatchProgress(total_episodes: usize) void {
    progress_current.store(0, .release);
    progress_total.store(
        @as(u64, @intCast(total_episodes)) * batch_progress_units_per_episode,
        .release,
    );
}

fn finishBatchEpisode(position: usize) void {
    progress_current.store(
        @as(u64, @intCast(position)) * batch_progress_units_per_episode,
        .release,
    );
}

fn runSeriesIndividualDownload() void {
    const total = selectedSeriesEpisodeCount();
    if (total == 0) {
        setStatus("Selecciona almenys un episodi.");
        return;
    }
    if (!batch_download_complete_video and !batch_download_extra_files) {
        setStatus("Selecciona almenys un tipus de fitxer per descarregar.");
        return;
    }
    resetBatchProgress(total);

    var position: usize = 0;
    var completed: usize = 0;
    var failed: usize = 0;
    for (series.episodes[0..series.episode_count]) |*item| {
        if (!item.selected) continue;
        position += 1;
        setBatchItemStatus("Descarregant", position, total, item.title.slice());
        var current_episode: core.Episode = .{};
        net.fetchEpisode(allocator, app_io, item.id.slice(), &current_episode) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        applyIndividualBatchSettings(&current_episode);
        var output_directory_buffer: [1024]u8 = undefined;
        const output_directory = batchOutputDirectory(item, &output_directory_buffer) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        var operation_current = std.atomic.Value(u64).init(0);
        var operation_total = std.atomic.Value(u64).init(1);
        net.downloadSelectedResources(
            allocator,
            app_io,
            &current_episode,
            output_directory,
            .{
                .current = &progress_current,
                .total = &progress_total,
                .range_start = @as(u64, @intCast(position - 1)) * batch_progress_units_per_episode,
                .range_size = batch_progress_units_per_episode,
                .operation_current = &operation_current,
                .operation_total = &operation_total,
            },
        ) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        completed += 1;
        finishBatchEpisode(position);
    }
    setBatchResultStatus("Descàrrega per lots completada", completed, failed);
}

fn runSeriesMux() void {
    if (!ffmpeg_detected) {
        setStatus("FFmpeg no està disponible.");
        return;
    }
    const total = selectedSeriesEpisodeCount();
    if (total == 0) {
        setStatus("Selecciona almenys un episodi.");
        return;
    }
    if (series_profile.resource_count == 0) {
        setStatus("No s'ha pogut carregar el perfil de muxing de la sèrie.");
        return;
    }
    resetBatchProgress(total);

    var position: usize = 0;
    var completed: usize = 0;
    var failed: usize = 0;
    for (series.episodes[0..series.episode_count]) |*item| {
        if (!item.selected) continue;
        position += 1;
        setBatchItemStatus("Fent muxing", position, total, item.title.slice());
        var current_episode: core.Episode = .{};
        net.fetchEpisode(allocator, app_io, item.id.slice(), &current_episode) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        applyMuxProfile(&series_profile, &current_episode);
        var output_directory_buffer: [1024]u8 = undefined;
        const output_directory = batchOutputDirectory(item, &output_directory_buffer) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        var operation_current = std.atomic.Value(u64).init(0);
        var operation_total = std.atomic.Value(u64).init(1);
        net.muxSelected(
            allocator,
            app_io,
            &current_episode,
            output_directory,
            .{
                .current = &progress_current,
                .total = &progress_total,
                .range_start = @as(u64, @intCast(position - 1)) * batch_progress_units_per_episode,
                .range_size = batch_progress_units_per_episode,
                .operation_current = &operation_current,
                .operation_total = &operation_total,
            },
        ) catch {
            failed += 1;
            finishBatchEpisode(position);
            continue;
        };
        completed += 1;
        finishBatchEpisode(position);
    }
    setBatchResultStatus("Muxing per lots completat", completed, failed);
}

fn worker(job: *Job) void {
    defer allocator.destroy(job);
    defer busy.store(false, .release);
    switch (job.kind) {
        .catalog => {
            net.fetchCatalog(allocator, app_io, &catalog) catch |err| {
                setErrorStatus(err);
                return;
            };
            catalog_ready.store(true, .release);
            var message_buffer: [192]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "Base de dades carregada: {d} títols. FFmpeg {s}.",
                .{ catalog.item_count, if (ffmpeg_detected) "detectat" else "no detectat" },
            ) catch "Base de dades carregada.";
            setStatus(message);
        },
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
                series_profile.clear();
                if (ffmpeg_detected and series.episode_count > 0) {
                    net.fetchEpisode(
                        allocator,
                        app_io,
                        series.episodes[0].id.slice(),
                        &series_profile,
                    ) catch {};
                }
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
                "downloads",
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
                "downloads",
                .{ .current = &progress_current, .total = &progress_total },
            ) catch |err| {
                setErrorStatus(err);
                return;
            };
            setStatus("Muxing completat.");
        },
        .series_individual_download => runSeriesIndividualDownload(),
        .series_mux => runSeriesMux(),
    }
}

fn init() callconv(.c) void {
    c.sx3_ui_setup();
    ffmpeg_detected = net.ffmpegAvailable(allocator, app_io);
    startJob(.catalog, "");
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

fn drawIndividual() void {
    c.sx3_ui_label("Baixa cada pista seleccionada directament. FFmpeg no intervé mai.");
    c.sx3_ui_spacing();

    for (episode.resources[0..episode.resource_count], 0..) |*resource, index| {
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_push_id(@intCast(index));
        resource.selected_individual = c.sx3_ui_checkbox(label, resource.selected_individual);
        c.sx3_ui_pop_id();
    }

    c.sx3_ui_spacing();
    if (c.sx3_ui_button_full_width("Descarrega els fitxers seleccionats")) {
        startJob(.individual_download, "");
    }
    if (!ffmpeg_detected) {
        c.sx3_ui_spacing();
        c.sx3_ui_label("FFmpeg no s'ha detectat: el muxing no està disponible, però aquestes descàrregues funcionen igualment.");
    }
}

fn drawMuxing(target: *core.Episode, button_label: [*:0]const u8, job_kind: JobKind) void {
    c.sx3_ui_heading("Vídeo · selecció exclusiva");
    for (target.resources[0..target.resource_count], 0..) |*resource, index| {
        if (resource.kind != .dash_video) continue;
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_push_id(@intCast(index));
        if (c.sx3_ui_option(label, resource.selected_mux)) {
            for (target.resources[0..target.resource_count]) |*candidate| {
                if (candidate.kind == .dash_video) candidate.selected_mux = false;
            }
            target.resources[index].selected_mux = true;
        }
        c.sx3_ui_pop_id();
    }

    c.sx3_ui_heading("Àudios · multiselecció i pista per defecte");
    for (target.resources[0..target.resource_count], 0..) |*resource, index| {
        if (resource.kind != .dash_audio) continue;
        var label_buffer: [384]u8 = undefined;
        const label = resourceDescription(resource, &label_buffer);
        c.sx3_ui_push_id(@intCast(index));
        resource.selected_mux = c.sx3_ui_checkbox(label, resource.selected_mux);
        if (!resource.selected_mux) resource.default_audio = false;
        c.sx3_ui_same_line();
        if (c.sx3_ui_option("Àudio per defecte", resource.default_audio)) {
            for (target.resources[0..target.resource_count]) |*candidate| {
                if (candidate.kind == .dash_audio) candidate.default_audio = false;
            }
            target.resources[index].selected_mux = true;
            target.resources[index].default_audio = true;
        }
        c.sx3_ui_pop_id();
    }

    var subtitle_count: usize = 0;
    for (target.resources[0..target.resource_count]) |*resource| {
        if (resource.kind == .subtitle) subtitle_count += 1;
    }
    var subtitle_label_buffer: [128]u8 = undefined;
    const subtitle_label = std.fmt.bufPrintZ(
        &subtitle_label_buffer,
        "Incloure subtítols ({d} pista/es)",
        .{subtitle_count},
    ) catch "Incloure subtítols";
    target.include_subtitles_mux = c.sx3_ui_checkbox(
        subtitle_label.ptr,
        target.include_subtitles_mux and subtitle_count > 0,
    );

    c.sx3_ui_spacing();
    if (c.sx3_ui_button_full_width(button_label)) {
        startJob(job_kind, "");
    }
}

fn drawEpisode() void {
    c.sx3_ui_heading(episode.title.c());
    if (c.sx3_ui_tab_bar_begin("download_modes")) {
        if (c.sx3_ui_tab_begin("Descàrrega individual")) {
            if (c.sx3_ui_panel_begin("episode_individual_options", 540.0)) {
                drawIndividual();
            }
            c.sx3_ui_panel_end();
            c.sx3_ui_tab_end();
        }
        if (ffmpeg_detected and c.sx3_ui_tab_begin("Muxing")) {
            if (c.sx3_ui_panel_begin("episode_mux_options", 540.0)) {
                drawMuxing(&episode, "Descarrega i fes muxing", .mux);
            }
            c.sx3_ui_panel_end();
            c.sx3_ui_tab_end();
        }
        c.sx3_ui_tab_bar_end();
    }
}

fn drawSeries() void {
    c.sx3_ui_heading(if (series.title.len > 0) series.title.c() else "Sèrie");
    c.sx3_ui_label("Selecciona els episodis i aplica les opcions de descàrrega a tot el lot.");

    if (c.sx3_ui_panel_begin("episode_selection", 300.0)) {
        const total_selected = selectedSeriesEpisodeCount();
        const all_selected = series.episode_count > 0 and total_selected == series.episode_count;
        var root_buffer: [128]u8 = undefined;
        const root_label = std.fmt.bufPrintZ(
            &root_buffer,
            "Tota la sèrie · {d}/{d} episodis###arrel_serie",
            .{ total_selected, series.episode_count },
        ) catch "Tota la sèrie";
        c.sx3_ui_push_id(-1);
        const root_selection = c.sx3_ui_checkbox_mixed(
            "##seleccio_serie",
            all_selected,
            total_selected > 0 and !all_selected,
        );
        c.sx3_ui_same_line();
        const root_open = c.sx3_ui_tree_begin(root_label.ptr, true);
        if (root_selection != all_selected) {
            setEpisodeSelection(0, series.episode_count, root_selection);
        }

        if (root_open) {
            for (series.seasons[0..series.season_count], 0..) |*season, season_index| {
                const end = season.first_episode + season.episode_count;
                const season_selected = selectedEpisodeCount(season.first_episode, end);
                const season_all_selected = season.episode_count > 0 and season_selected == season.episode_count;
                var season_buffer: [128]u8 = undefined;
                const season_label = if (season.is_virtual)
                    std.fmt.bufPrintZ(
                        &season_buffer,
                        "Capítols · {d}/{d} episodis###temporada",
                        .{ season_selected, season.episode_count },
                    ) catch "Capítols"
                else
                    std.fmt.bufPrintZ(
                        &season_buffer,
                        "Temporada {d} · {d}/{d} episodis###temporada",
                        .{ season.number, season_selected, season.episode_count },
                    ) catch "Temporada";

                c.sx3_ui_push_id(@intCast(season_index));
                const new_selection = c.sx3_ui_checkbox_mixed(
                    "##seleccio_temporada",
                    season_all_selected,
                    season_selected > 0 and !season_all_selected,
                );
                c.sx3_ui_same_line();
                const open = c.sx3_ui_tree_begin(season_label.ptr, season_index == 0);
                if (new_selection != season_all_selected) {
                    setEpisodeSelection(season.first_episode, end, new_selection);
                }
                if (open) {
                    for (series.episodes[season.first_episode..end], 0..) |*item, item_index| {
                        var episode_buffer: [320]u8 = undefined;
                        const episode_label = if (item.number > 0)
                            std.fmt.bufPrintZ(&episode_buffer, "Capítol {d} · {s}", .{ item.number, item.title.slice() }) catch "Episodi"
                        else
                            std.fmt.bufPrintZ(&episode_buffer, "{s}", .{item.title.slice()}) catch "Episodi";
                        c.sx3_ui_push_id(@intCast(item_index));
                        item.selected = c.sx3_ui_checkbox(episode_label.ptr, item.selected);
                        c.sx3_ui_pop_id();
                    }
                    c.sx3_ui_tree_end();
                }
                c.sx3_ui_pop_id();
            }
            c.sx3_ui_tree_end();
        }
        c.sx3_ui_pop_id();
    }
    c.sx3_ui_panel_end();

    c.sx3_ui_spacing();
    if (c.sx3_ui_tab_bar_begin("series_download_modes")) {
        if (c.sx3_ui_tab_begin("Descàrrega individual")) {
            if (c.sx3_ui_panel_begin("series_individual_options", 220.0)) {
                batch_download_complete_video = c.sx3_ui_checkbox(
                    "Descarrega el vídeo complet MP4/MKV de cada episodi",
                    batch_download_complete_video,
                );
                batch_download_extra_files = c.sx3_ui_checkbox(
                    "Descarrega també totes les pistes separades",
                    batch_download_extra_files,
                );
                c.sx3_ui_label("Aquest procés és una descàrrega HTTP directa i no utilitza FFmpeg.");
                c.sx3_ui_spacing();
                if (c.sx3_ui_button_full_width("Descarrega els episodis seleccionats")) {
                    startJob(.series_individual_download, "");
                }
            }
            c.sx3_ui_panel_end();
            c.sx3_ui_tab_end();
        }
        if (ffmpeg_detected and c.sx3_ui_tab_begin("Muxing")) {
            if (c.sx3_ui_panel_begin("series_mux_options", 220.0)) {
                if (series_profile.resource_count > 0) {
                    c.sx3_ui_label("Aquest perfil s'intentarà aplicar a tots els episodis seleccionats.");
                    drawMuxing(&series_profile, "Descarrega i fes muxing dels episodis seleccionats", .series_mux);
                } else {
                    c.sx3_ui_label("No s'ha pogut obtenir un episodi de referència per configurar el muxing.");
                }
            }
            c.sx3_ui_panel_end();
            c.sx3_ui_tab_end();
        }
        c.sx3_ui_tab_bar_end();
    }
}

fn updateUrlLength() void {
    url_length = std.mem.indexOfScalar(u8, &url_buffer, 0) orelse url_buffer.len - 1;
}

fn drawSearchTabs(is_busy: bool) void {
    if (!c.sx3_ui_tab_bar_begin("search_modes")) return;

    if (c.sx3_ui_tab_begin("Base de dades")) {
        const is_ready = catalog_ready.load(.acquire);
        if (is_ready) {
            var count_buffer: [96]u8 = undefined;
            const count_label = std.fmt.bufPrintZ(
                &count_buffer,
                "Catàleg de 3Cat · {d} títols",
                .{catalog.item_count},
            ) catch "Catàleg de 3Cat";
            c.sx3_ui_label(count_label.ptr);

            const preview: [*:0]const u8 = if (catalog_selected_index) |index|
                catalog.items[index].title.c()
            else
                "Selecciona un títol...";
            c.sx3_ui_set_next_item_width(-112.0);
            var requested_index: ?usize = null;
            if (c.sx3_ui_combo_begin("##catalog", preview)) {
                for (catalog.items[0..catalog.item_count], 0..) |*item, index| {
                    c.sx3_ui_push_id(@intCast(index));
                    const selected = catalog_selected_index != null and catalog_selected_index.? == index;
                    if (c.sx3_ui_selectable(item.title.c(), selected)) requested_index = index;
                    c.sx3_ui_pop_id();
                }
                c.sx3_ui_combo_end();
            }
            c.sx3_ui_same_line();
            if (c.sx3_ui_button("Actualitza")) startJob(.catalog, "");

            if (requested_index) |index| {
                catalog_selected_index = index;
                startJob(.search, catalog.items[index].url.slice());
            }
        } else if (is_busy) {
            c.sx3_ui_label("S'està carregant el catàleg complet...");
        } else {
            c.sx3_ui_label("No s'ha pogut carregar el catàleg.");
            if (c.sx3_ui_button("Torna-ho a provar")) startJob(.catalog, "");
        }
        c.sx3_ui_tab_end();
    }

    if (c.sx3_ui_tab_begin("Descàrrega directa")) {
        c.sx3_ui_set_next_item_width(-112.0);
        const submitted = c.sx3_ui_input_text(&url_buffer, url_buffer.len, is_busy);
        updateUrlLength();
        c.sx3_ui_same_line();
        const search_clicked = c.sx3_ui_button("Cerca");
        if ((submitted or search_clicked) and !is_busy) {
            startJob(.search, url_buffer[0..url_length]);
        }
        c.sx3_ui_tab_end();
    }

    c.sx3_ui_tab_bar_end();
}

fn frame() callconv(.c) void {
    const is_busy = busy.load(.acquire);
    c.sx3_ui_frame_begin();
    if (c.sx3_ui_window_begin()) {
        c.sx3_ui_heading(app_display_name);
        c.sx3_ui_disable_begin(is_busy);
        drawSearchTabs(is_busy);
        c.sx3_ui_disable_end(is_busy);

        c.sx3_ui_label(@ptrCast(&status_buffer));
        if (is_busy) {
            c.sx3_ui_label("La interfície és temporalment de només lectura.");
        }
        if (is_busy) {
            c.sx3_ui_progress(
                progress_current.load(.acquire),
                progress_total.load(.acquire),
            );
        }

        if (c.sx3_ui_content_begin("##content")) {
            c.sx3_ui_disable_begin(is_busy);
            switch (page_kind) {
                .episode => drawEpisode(),
                .series => drawSeries(),
                .none => {},
            }
            c.sx3_ui_disable_end(is_busy);
        }
        c.sx3_ui_content_end();
    }
    c.sx3_ui_window_end();
    c.sx3_ui_frame_end();
}

fn cleanup() callconv(.c) void {
    c.sx3_ui_shutdown();
}

fn event(ev: [*c]const c.sapp_event) callconv(.c) void {
    _ = c.sx3_ui_handle_event(ev);
}

pub fn main(init_data: std.process.Init) void {
    app_io = init_data.io;
    var desc: c.sapp_desc = std.mem.zeroes(c.sapp_desc);
    desc.init_cb = init;
    desc.frame_cb = frame;
    desc.cleanup_cb = cleanup;
    desc.event_cb = event;
    desc.width = 1100;
    desc.height = 750;
    desc.high_dpi = true;
    desc.enable_clipboard = true;
    desc.window_title = app_display_name;
    desc.logger.func = c.slog_func;
    c.sapp_run(&desc);
}
