const std = @import("std");
const core = @import("core.zig");

pub const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0";

pub const Progress = struct {
    current: *std.atomic.Value(u64),
    total: *std.atomic.Value(u64),
    range_start: u64 = 0,
    range_size: u64 = 0,
    operation_current: ?*std.atomic.Value(u64) = null,
    operation_total: ?*std.atomic.Value(u64) = null,

    fn reset(self: Progress, total: u64) void {
        if (self.range_size > 0 and self.operation_current != null and self.operation_total != null) {
            self.operation_current.?.store(0, .release);
            self.operation_total.?.store(@max(total, 1), .release);
            self.current.store(self.range_start, .release);
            return;
        }
        self.current.store(0, .release);
        self.total.store(@max(total, 1), .release);
    }

    fn advance(self: Progress) void {
        if (self.range_size > 0 and self.operation_current != null and self.operation_total != null) {
            const completed = self.operation_current.?.fetchAdd(1, .acq_rel) + 1;
            const operation_total = @max(self.operation_total.?.load(.acquire), 1);
            const scaled = @min(self.range_size, completed * self.range_size / operation_total);
            self.current.store(self.range_start + scaled, .release);
            return;
        }
        _ = self.current.fetchAdd(1, .acq_rel);
    }
};

test "progress maps an operation into one batch range" {
    var current = std.atomic.Value(u64).init(0);
    var total = std.atomic.Value(u64).init(2000);
    var operation_current = std.atomic.Value(u64).init(0);
    var operation_total = std.atomic.Value(u64).init(1);
    const progress: Progress = .{
        .current = &current,
        .total = &total,
        .range_start = 1000,
        .range_size = 1000,
        .operation_current = &operation_current,
        .operation_total = &operation_total,
    };

    progress.reset(4);
    try std.testing.expectEqual(@as(u64, 1000), current.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2000), total.load(.acquire));
    progress.advance();
    try std.testing.expectEqual(@as(u64, 1250), current.load(.acquire));
    progress.advance();
    progress.advance();
    progress.advance();
    try std.testing.expectEqual(@as(u64, 2000), current.load(.acquire));
}

test "single-step mux progress completes one batch episode" {
    var current = std.atomic.Value(u64).init(0);
    var total = std.atomic.Value(u64).init(3000);
    var operation_current = std.atomic.Value(u64).init(0);
    var operation_total = std.atomic.Value(u64).init(1);
    const progress: Progress = .{
        .current = &current,
        .total = &total,
        .range_start = 1000,
        .range_size = 1000,
        .operation_current = &operation_current,
        .operation_total = &operation_total,
    };

    progress.reset(1);
    try std.testing.expectEqual(@as(u64, 1000), current.load(.acquire));
    progress.advance();
    try std.testing.expectEqual(@as(u64, 2000), current.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3000), total.load(.acquire));
}

pub fn getAlloc(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    });
    if (result.status.class() != .success) return error.HttpStatus;
    var list = body.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn fetchEpisode(
    allocator: std.mem.Allocator,
    io: std.Io,
    episode_id: []const u8,
    episode: *core.Episode,
) !void {
    var api_url_buffer: [1024]u8 = undefined;
    const api_url = try std.fmt.bufPrint(
        &api_url_buffer,
        "https://api-media.3cat.cat/pvideo/media.jsp?media=video&versio=vast&idint={s}&profile=pc_3cat&format=dm",
        .{episode_id},
    );
    const json = try getAlloc(allocator, io, api_url);
    defer allocator.free(json);
    try core.parseEpisodeJson(allocator, json, episode);
    if (episode.id.len == 0) episode.id.set(episode_id);

    if (episode.manifest_url.len > 0) {
        const manifest = try getAlloc(allocator, io, episode.manifest_url.slice());
        defer allocator.free(manifest);
        try core.parseDashManifest(manifest, episode);
    }
}

pub fn fetchSeries(
    allocator: std.mem.Allocator,
    io: std.Io,
    series_url: []const u8,
    series: *core.Series,
) !void {
    var normalized_url: core.FixedText(2048) = .{};
    try core.normalizeSeriesUrl(series_url, &normalized_url);
    const index_html = try getAlloc(allocator, io, normalized_url.slice());
    defer allocator.free(index_html);
    try core.parseSeriesIndex(index_html, normalized_url.slice(), series);

    var season_index: usize = 0;
    while (season_index < series.season_count) : (season_index += 1) {
        const season_html = try getAlloc(allocator, io, series.seasons[season_index].url.slice());
        defer allocator.free(season_html);
        try core.parseSeasonPage(season_html, season_index, series);
    }
    if (series.episode_count == 0) return error.NoEpisodes;
}

pub fn fetchCatalog(
    allocator: std.mem.Allocator,
    io: std.Io,
    catalog: *core.Catalog,
) !void {
    const html = try getAlloc(allocator, io, "https://www.3cat.cat/3cat/tot-cataleg/tot/");
    defer allocator.free(html);
    try core.parseCatalogPage(allocator, html, catalog);
}

pub fn ffmpegAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "ffmpeg", "-version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn fetchToWriter(client: *std.http.Client, url: []const u8, writer: *std.Io.Writer) !void {
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    });
    if (result.status.class() != .success) return error.HttpStatus;
}

fn sanitize(target: []u8, value: []const u8) []const u8 {
    var length: usize = 0;
    for (value) |byte| {
        if (length >= target.len) break;
        target[length] = switch (byte) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*', 0...31 => '_',
            else => byte,
        };
        length += 1;
    }
    while (length > 0 and (target[length - 1] == ' ' or target[length - 1] == '.')) length -= 1;
    return if (length > 0) target[0..length] else "recurs";
}

pub fn seriesOutputDirectory(
    series_title: []const u8,
    season_number: u16,
    is_virtual_season: bool,
    buffer: []u8,
) ![]const u8 {
    var title_buffer: [280]u8 = undefined;
    const title = sanitize(&title_buffer, series_title);
    return if (is_virtual_season)
        std.fmt.bufPrint(buffer, "downloads/{s}/Capítols", .{title})
    else
        std.fmt.bufPrint(buffer, "downloads/{s}/Temporada {d}", .{ title, season_number });
}

fn normalizedWebVttAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const timing_marker = std.mem.indexOf(u8, input, "-->") orelse return error.InvalidWebVtt;
    const timing_line_start = if (std.mem.lastIndexOfScalar(u8, input[0..timing_marker], '\n')) |index|
        index + 1
    else
        0;

    var previous_end = timing_line_start;
    while (previous_end > 0 and (input[previous_end - 1] == '\r' or input[previous_end - 1] == '\n')) {
        previous_end -= 1;
    }
    const previous_start = if (previous_end > 0)
        if (std.mem.lastIndexOfScalar(u8, input[0..previous_end], '\n')) |index| index + 1 else 0
    else
        timing_line_start;
    const previous_line = std.mem.trim(u8, input[previous_start..previous_end], " \t\r\n");
    const content_start = if (previous_line.len > 0) previous_start else timing_line_start;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("WEBVTT\n\n");
    var cursor = content_start;
    while (cursor < input.len) : (cursor += 1) {
        if (input[cursor] == '\r') {
            try output.writer.writeByte('\n');
            if (cursor + 1 < input.len and input[cursor + 1] == '\n') cursor += 1;
        } else {
            try output.writer.writeByte(input[cursor]);
        }
    }
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

fn prepareSubtitleForMux(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: *const core.Resource,
    path: []const u8,
) !void {
    const original = try getAlloc(allocator, io, resource.url.slice());
    defer allocator.free(original);
    const normalized = if (std.mem.startsWith(u8, original, "WEBVTT"))
        try normalizedWebVttAlloc(allocator, original)
    else
        try allocator.dupe(u8, original);
    defer allocator.free(normalized);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &write_buffer);
    try file_writer.interface.writeAll(normalized);
    try file_writer.interface.flush();
}

test "series output directories separate seasons and unseasoned programs" {
    var buffer: [1024]u8 = undefined;
    const season = try seriesOutputDirectory("Sèrie: prova", 2, false, &buffer);
    try std.testing.expectEqualStrings("downloads/Sèrie_ prova/Temporada 2", season);

    const chapters = try seriesOutputDirectory("Programa", 1, true, &buffer);
    try std.testing.expectEqualStrings("downloads/Programa/Capítols", chapters);
}

test "normalize 3cat webvtt headers before muxing" {
    const original =
        "WEBVTT\r\n\r\n" ++
        "Region: id=r1 width=100%\r\n\r\n\r\n" ++
        "1\r\n" ++
        "00:00:02.320 --> 00:00:05.160 region:r1 line:88% align:center\r\n" ++
        "<c.white>Primer subtítol</c>\r\n\r\n";
    const normalized = try normalizedWebVttAlloc(std.testing.allocator, original);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "WEBVTT\n\n" ++
            "1\n" ++
            "00:00:02.320 --> 00:00:05.160 region:r1 line:88% align:center\n" ++
            "<c.white>Primer subtítol</c>\n\n",
        normalized,
    );
}

fn urlExtension(url: []const u8, fallback: []const u8) []const u8 {
    const path = (std.Uri.parse(url) catch return fallback).path.percent_encoded;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return fallback;
    const extension = path[dot..];
    return if (extension.len <= 8) extension else fallback;
}

fn resourcePath(
    resource: *const core.Resource,
    episode: *const core.Episode,
    output_directory: []const u8,
    buffer: []u8,
) ![]const u8 {
    var title_buffer: [280]u8 = undefined;
    var label_buffer: [180]u8 = undefined;
    const title = sanitize(&title_buffer, episode.title.slice());
    const label = sanitize(&label_buffer, resource.label.slice());
    const extension = switch (resource.kind) {
        .direct_video => urlExtension(resource.url.slice(), ".mp4"),
        .dash_video => ".mp4",
        .dash_audio => ".m4a",
        .subtitle => urlExtension(resource.url.slice(), ".vtt"),
    };
    return std.fmt.bufPrint(buffer, "{s}/{s} - {s}{s}", .{ output_directory, title, label, extension });
}

fn segmentUrl(template: []const u8, number: u64, buffer: []u8) ![]const u8 {
    const marker = "$Number$";
    const marker_start = std.mem.indexOf(u8, template, marker) orelse return error.InvalidSegmentTemplate;
    return std.fmt.bufPrint(
        buffer,
        "{s}{d}{s}",
        .{ template[0..marker_start], number, template[marker_start + marker.len ..] },
    );
}

fn downloadResource(
    client: *std.http.Client,
    io: std.Io,
    resource: *const core.Resource,
    episode: *const core.Episode,
    output_directory: []const u8,
    progress: Progress,
) !void {
    var final_path_buffer: [2048]u8 = undefined;
    const final_path = try resourcePath(resource, episode, output_directory, &final_path_buffer);
    var temporary_path_buffer: [2056]u8 = undefined;
    const temporary_path = try std.fmt.bufPrint(&temporary_path_buffer, "{s}.part", .{final_path});
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, temporary_path) catch {};

    {
        const file = try cwd.createFile(io, temporary_path, .{});
        defer file.close(io);
        var write_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writerStreaming(io, &write_buffer);
        if (resource.isDash()) {
            try fetchToWriter(client, resource.initialization_url.slice(), &file_writer.interface);
            progress.advance();
            var number = resource.segment_start;
            const end = resource.segment_start + resource.segment_count;
            while (number < end) : (number += 1) {
                var segment_url_buffer: [2048]u8 = undefined;
                const url = try segmentUrl(resource.segment_url_template.slice(), number, &segment_url_buffer);
                try fetchToWriter(client, url, &file_writer.interface);
                progress.advance();
            }
        } else {
            try fetchToWriter(client, resource.url.slice(), &file_writer.interface);
            progress.advance();
        }
        try file_writer.interface.flush();
    }
    try cwd.rename(temporary_path, cwd, final_path, io);
}

pub fn downloadSelectedResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    episode: *const core.Episode,
    output_directory: []const u8,
    progress: Progress,
) !void {
    var total: u64 = 0;
    for (episode.resources[0..episode.resource_count]) |*resource| {
        if (!resource.selected_individual) continue;
        total += if (resource.isDash()) resource.segment_count + 1 else 1;
    }
    if (total == 0) return error.NothingSelected;
    progress.reset(total);
    try std.Io.Dir.cwd().createDirPath(io, output_directory);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    for (episode.resources[0..episode.resource_count]) |*resource| {
        if (resource.selected_individual) {
            try downloadResource(&client, io, resource, episode, output_directory, progress);
        }
    }
}

fn addArgument(arguments: *[512][]const u8, count: *usize, value: []const u8) !void {
    if (count.* >= arguments.len) return error.TooManyArguments;
    arguments[count.*] = value;
    count.* += 1;
}

fn mp4LanguageCode(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "ca")) return "cat";
    if (std.mem.eql(u8, language, "es")) return "spa";
    if (std.mem.eql(u8, language, "en")) return "eng";
    return if (language.len == 3) language else "und";
}

pub fn muxSelected(
    allocator: std.mem.Allocator,
    io: std.Io,
    episode: *const core.Episode,
    output_directory: []const u8,
    progress: Progress,
) !void {
    var selected_video: ?*const core.Resource = null;
    var audio_count: usize = 0;
    var subtitle_count: usize = 0;
    for (episode.resources[0..episode.resource_count]) |*resource| {
        if (resource.kind == .dash_video and resource.selected_mux) selected_video = resource;
        if (resource.kind == .dash_audio and resource.selected_mux) audio_count += 1;
        if (resource.kind == .subtitle and episode.include_subtitles_mux) subtitle_count += 1;
    }
    const video = selected_video orelse return error.NoVideoSelected;
    progress.reset(1);
    try std.Io.Dir.cwd().createDirPath(io, output_directory);

    var title_buffer: [280]u8 = undefined;
    const title = sanitize(&title_buffer, episode.title.slice());
    var final_path_buffer: [2048]u8 = undefined;
    const final_path = try std.fmt.bufPrint(&final_path_buffer, "{s}/{s}.mp4", .{ output_directory, title });
    var temporary_path_buffer: [2056]u8 = undefined;
    const temporary_path = try std.fmt.bufPrint(&temporary_path_buffer, "{s}.part", .{final_path});

    var subtitle_path_buffers: [core.max_resources][2048]u8 = undefined;
    var subtitle_paths: [core.max_resources][]const u8 = undefined;
    var subtitle_resources: [core.max_resources]*const core.Resource = undefined;
    var prepared_subtitle_count: usize = 0;
    defer {
        for (subtitle_paths[0..prepared_subtitle_count]) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
        }
    }
    if (episode.include_subtitles_mux) {
        for (episode.resources[0..episode.resource_count], 0..) |*resource, resource_index| {
            if (resource.kind != .subtitle) continue;
            const path = try std.fmt.bufPrint(
                &subtitle_path_buffers[prepared_subtitle_count],
                "{s}/.baixa3-subtitle-{d}.vtt",
                .{ output_directory, resource_index },
            );
            try prepareSubtitleForMux(allocator, io, resource, path);
            subtitle_paths[prepared_subtitle_count] = path;
            subtitle_resources[prepared_subtitle_count] = resource;
            prepared_subtitle_count += 1;
        }
    }
    if (prepared_subtitle_count != subtitle_count) return error.SubtitlePreparationFailed;

    var arguments: [512][]const u8 = undefined;
    var argument_count: usize = 0;
    try addArgument(&arguments, &argument_count, "ffmpeg");
    try addArgument(&arguments, &argument_count, "-hide_banner");
    try addArgument(&arguments, &argument_count, "-loglevel");
    try addArgument(&arguments, &argument_count, "error");
    try addArgument(&arguments, &argument_count, "-y");
    try addArgument(&arguments, &argument_count, "-i");
    try addArgument(&arguments, &argument_count, episode.manifest_url.slice());
    for (subtitle_paths[0..prepared_subtitle_count]) |path| {
        try addArgument(&arguments, &argument_count, "-i");
        try addArgument(&arguments, &argument_count, path);
    }

    var dynamic_arguments: [core.max_resources * 6][64]u8 = undefined;
    var dynamic_count: usize = 0;
    var metadata_values: [core.max_resources * 2][256]u8 = undefined;
    var metadata_value_count: usize = 0;
    try addArgument(&arguments, &argument_count, "-map");
    const video_map = try std.fmt.bufPrint(&dynamic_arguments[dynamic_count], "0:v:{d}", .{video.stream_index});
    dynamic_count += 1;
    try addArgument(&arguments, &argument_count, video_map);

    var selected_audio_index: usize = 0;
    for (episode.resources[0..episode.resource_count]) |*resource| {
        if (resource.kind != .dash_audio or !resource.selected_mux) continue;
        try addArgument(&arguments, &argument_count, "-map");
        const audio_map = try std.fmt.bufPrint(&dynamic_arguments[dynamic_count], "0:a:{d}", .{resource.stream_index});
        dynamic_count += 1;
        try addArgument(&arguments, &argument_count, audio_map);
        const disposition_key = try std.fmt.bufPrint(&dynamic_arguments[dynamic_count], "-disposition:a:{d}", .{selected_audio_index});
        dynamic_count += 1;
        try addArgument(&arguments, &argument_count, disposition_key);
        try addArgument(&arguments, &argument_count, if (resource.default_audio) "default" else "0");
        selected_audio_index += 1;
    }
    var subtitle_input_index: usize = 1;
    var selected_subtitle_index: usize = 0;
    while (selected_subtitle_index < subtitle_count) : (selected_subtitle_index += 1) {
        const resource = subtitle_resources[selected_subtitle_index];
        try addArgument(&arguments, &argument_count, "-map");
        const subtitle_map = try std.fmt.bufPrint(&dynamic_arguments[dynamic_count], "{d}:s:0", .{subtitle_input_index});
        dynamic_count += 1;
        try addArgument(&arguments, &argument_count, subtitle_map);

        const language_key = try std.fmt.bufPrint(
            &dynamic_arguments[dynamic_count],
            "-metadata:s:s:{d}",
            .{selected_subtitle_index},
        );
        dynamic_count += 1;
        const language_value = try std.fmt.bufPrint(
            &metadata_values[metadata_value_count],
            "language={s}",
            .{mp4LanguageCode(resource.language.slice())},
        );
        metadata_value_count += 1;
        try addArgument(&arguments, &argument_count, language_key);
        try addArgument(&arguments, &argument_count, language_value);

        const handler_key = try std.fmt.bufPrint(
            &dynamic_arguments[dynamic_count],
            "-metadata:s:s:{d}",
            .{selected_subtitle_index},
        );
        dynamic_count += 1;
        const handler_value = try std.fmt.bufPrint(
            &metadata_values[metadata_value_count],
            "handler_name={s}",
            .{resource.label.slice()},
        );
        metadata_value_count += 1;
        try addArgument(&arguments, &argument_count, handler_key);
        try addArgument(&arguments, &argument_count, handler_value);

        const disposition_key = try std.fmt.bufPrint(
            &dynamic_arguments[dynamic_count],
            "-disposition:s:{d}",
            .{selected_subtitle_index},
        );
        dynamic_count += 1;
        try addArgument(&arguments, &argument_count, disposition_key);
        try addArgument(
            &arguments,
            &argument_count,
            if (selected_subtitle_index == 0) "default" else "0",
        );
        subtitle_input_index += 1;
    }
    try addArgument(&arguments, &argument_count, "-c:v");
    try addArgument(&arguments, &argument_count, "copy");
    if (audio_count > 0) {
        try addArgument(&arguments, &argument_count, "-c:a");
        try addArgument(&arguments, &argument_count, "copy");
    }
    if (subtitle_count > 0) {
        try addArgument(&arguments, &argument_count, "-c:s");
        try addArgument(&arguments, &argument_count, "mov_text");
    }
    try addArgument(&arguments, &argument_count, "-movflags");
    try addArgument(&arguments, &argument_count, "+faststart");
    try addArgument(&arguments, &argument_count, "-f");
    try addArgument(&arguments, &argument_count, "mp4");
    try addArgument(&arguments, &argument_count, temporary_path);

    const result = try std.process.run(allocator, io, .{
        .argv = arguments[0..argument_count],
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};
        return error.FfmpegFailed;
    }
    try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, io);
    progress.advance();
}
