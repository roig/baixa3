const std = @import("std");

pub const max_resources = 64;
pub const max_seasons = 16;
pub const max_episodes = 512;
pub const max_catalog_items = 2048;

pub fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity + 1]u8 = [_]u8{0} ** (capacity + 1),
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) void {
            self.len = @min(value.len, capacity);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
            self.bytes[self.len] = 0;
        }

        pub fn setFmt(self: *Self, comptime format: []const u8, args: anytype) void {
            const value = std.fmt.bufPrint(self.bytes[0..capacity], format, args) catch {
                self.len = capacity;
                self.bytes[capacity] = 0;
                return;
            };
            self.len = value.len;
            self.bytes[self.len] = 0;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn c(self: *const Self) [*:0]const u8 {
            return @ptrCast(&self.bytes);
        }
    };
}

pub const ResourceKind = enum {
    direct_video,
    dash_video,
    dash_audio,
    subtitle,
};

pub const Resource = struct {
    kind: ResourceKind = .direct_video,
    label: FixedText(160) = .{},
    url: FixedText(2048) = .{},
    language: FixedText(32) = .{},
    width: u32 = 0,
    height: u32 = 0,
    bandwidth: u64 = 0,
    stream_index: usize = 0,
    selected_individual: bool = false,
    selected_mux: bool = false,
    default_audio: bool = false,
    initialization_url: FixedText(2048) = .{},
    segment_url_template: FixedText(2048) = .{},
    segment_start: u64 = 0,
    segment_count: u64 = 0,

    pub fn isDash(self: *const Resource) bool {
        return self.kind == .dash_video or self.kind == .dash_audio;
    }
};

pub const Episode = struct {
    id: FixedText(32) = .{},
    title: FixedText(256) = .{},
    manifest_url: FixedText(2048) = .{},
    resources: [max_resources]Resource = [_]Resource{.{}} ** max_resources,
    resource_count: usize = 0,
    include_subtitles_mux: bool = true,

    pub fn clear(self: *Episode) void {
        self.* = .{};
    }

    pub fn addResource(self: *Episode, kind: ResourceKind, label: []const u8, url: []const u8) !*Resource {
        if (self.resource_count >= self.resources.len) return error.TooManyResources;
        const resource = &self.resources[self.resource_count];
        resource.* = .{ .kind = kind };
        resource.label.set(label);
        resource.url.set(url);
        self.resource_count += 1;
        return resource;
    }
};

pub const EpisodeSummary = struct {
    id: FixedText(32) = .{},
    title: FixedText(256) = .{},
    url: FixedText(2048) = .{},
    season: u16 = 0,
    number: u16 = 0,
    selected: bool = false,
};

pub const Season = struct {
    number: u16 = 0,
    url: FixedText(2048) = .{},
    first_episode: usize = 0,
    episode_count: usize = 0,
    is_virtual: bool = false,
};

pub const Series = struct {
    title: FixedText(256) = .{},
    seasons: [max_seasons]Season = [_]Season{.{}} ** max_seasons,
    season_count: usize = 0,
    episodes: [max_episodes]EpisodeSummary = [_]EpisodeSummary{.{}} ** max_episodes,
    episode_count: usize = 0,

    pub fn clear(self: *Series) void {
        self.* = .{};
    }
};

pub const CatalogItem = struct {
    title: FixedText(256) = .{},
    url: FixedText(512) = .{},
};

pub const Catalog = struct {
    items: [max_catalog_items]CatalogItem = [_]CatalogItem{.{}} ** max_catalog_items,
    item_count: usize = 0,

    pub fn clear(self: *Catalog) void {
        self.* = .{};
    }
};

pub const PageKind = enum { none, episode, series };

pub const SeriesUrlKind = enum {
    sx3_legacy,
    threecat,
};

pub const SeriesLocation = struct {
    kind: SeriesUrlKind = .sx3_legacy,
    root_url: FixedText(2048) = .{},
};

pub fn extractEpisodeId(url: []const u8) ?[]const u8 {
    const marker = "/video/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const tail = url[start + marker.len ..];
    var end: usize = 0;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    return if (end > 0) tail[0..end] else null;
}

pub fn classifySeriesUrl(input: []const u8, location: *SeriesLocation) !void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "https://www.3cat.cat/") and
        !std.mem.startsWith(u8, trimmed, "http://www.3cat.cat/"))
    {
        return error.InvalidSeriesUrl;
    }

    const suffix_start = std.mem.indexOfAny(u8, trimmed, "?#") orelse trimmed.len;
    const clean = trimmed[0..suffix_start];
    const kind: SeriesUrlKind = if (std.mem.indexOf(u8, clean, "/tv3/sx3/") != null)
        .sx3_legacy
    else if (std.mem.indexOf(u8, clean, "/3cat/") != null)
        .threecat
    else
        return error.InvalidSeriesUrl;

    location.* = .{ .kind = kind };
    const section_marker = switch (kind) {
        .sx3_legacy => "/videos/",
        .threecat => "/capitols/",
    };
    if (std.mem.indexOf(u8, clean, section_marker)) |section_start| {
        location.root_url.set(clean[0 .. section_start + 1]);
    } else if (std.mem.endsWith(u8, clean, "/")) {
        location.root_url.set(clean);
    } else {
        location.root_url.setFmt("{s}/", .{clean});
    }
}

pub fn normalizeSeriesUrl(input: []const u8, target: *FixedText(2048)) !void {
    var location: SeriesLocation = .{};
    try classifySeriesUrl(input, &location);
    target.set(location.root_url.slice());
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => |string| string,
        else => null,
    };
}

fn catalogContains(catalog: *const Catalog, slug: []const u8) bool {
    var expected_url: FixedText(512) = .{};
    expected_url.setFmt("https://www.3cat.cat/3cat/{s}/", .{slug});
    for (catalog.items[0..catalog.item_count]) |item| {
        if (std.mem.eql(u8, item.url.slice(), expected_url.slice())) return true;
    }
    return false;
}

fn collectCatalogItems(value: std.json.Value, catalog: *Catalog) !void {
    switch (value) {
        .object => |object| {
            const content_type = jsonString(object.get("tipologia"));
            const slug = jsonString(object.get("nombonic"));
            const title = jsonString(object.get("titol"));
            if (content_type != null and slug != null and title != null and
                std.mem.eql(u8, content_type.?, "PTVC_PROGRAMA") and
                slug.?.len > 0 and title.?.len > 0 and
                !catalogContains(catalog, slug.?))
            {
                if (catalog.item_count >= catalog.items.len) return error.TooManyCatalogItems;
                const item = &catalog.items[catalog.item_count];
                item.* = .{};
                item.title.set(title.?);
                item.url.setFmt("https://www.3cat.cat/3cat/{s}/", .{slug.?});
                catalog.item_count += 1;
            }

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try collectCatalogItems(entry.value_ptr.*, catalog);
            }
        },
        .array => |array| {
            for (array.items) |item| try collectCatalogItems(item, catalog);
        },
        else => {},
    }
}

pub fn parseCatalogPage(allocator: std.mem.Allocator, html: []const u8, catalog: *Catalog) !void {
    catalog.clear();
    const id_position = std.mem.indexOf(u8, html, "id=\"__NEXT_DATA__\"") orelse
        return error.CatalogDataNotFound;
    const script_start = std.mem.lastIndexOf(u8, html[0..id_position], "<script") orelse
        return error.CatalogDataNotFound;
    const json_start_marker = std.mem.indexOfPos(u8, html, script_start, ">") orelse
        return error.CatalogDataNotFound;
    const json_start = json_start_marker + 1;
    const json_end = std.mem.indexOfPos(u8, html, json_start, "</script>") orelse
        return error.CatalogDataNotFound;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, html[json_start..json_end], .{});
    defer parsed.deinit();
    try collectCatalogItems(parsed.value, catalog);
    if (catalog.item_count == 0) return error.EmptyCatalog;

    std.mem.sort(CatalogItem, catalog.items[0..catalog.item_count], {}, struct {
        fn lessThan(_: void, left: CatalogItem, right: CatalogItem) bool {
            return std.mem.lessThan(u8, left.title.slice(), right.title.slice());
        }
    }.lessThan);
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var needle_buffer: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "{s}=\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, tag, needle) orelse return null;
    const value_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, tag, value_start, "\"") orelse return null;
    return tag[value_start..end];
}

fn parseUnsigned(value: ?[]const u8) u64 {
    return std.fmt.parseUnsigned(u64, value orelse return 0, 10) catch 0;
}

fn parseDurationSeconds(value: []const u8) f64 {
    const time_start = std.mem.indexOfScalar(u8, value, 'T') orelse 0;
    var cursor = time_start + @intFromBool(time_start < value.len);
    var total: f64 = 0;
    while (cursor < value.len) {
        const start = cursor;
        while (cursor < value.len and (std.ascii.isDigit(value[cursor]) or value[cursor] == '.')) : (cursor += 1) {}
        if (cursor == start or cursor >= value.len) break;
        const number = std.fmt.parseFloat(f64, value[start..cursor]) catch 0;
        switch (value[cursor]) {
            'H' => total += number * 3600,
            'M' => total += number * 60,
            'S' => total += number,
            else => {},
        }
        cursor += 1;
    }
    return total;
}

fn resolveRelative(target: *FixedText(2048), base_url: []const u8, relative: []const u8) void {
    if (std.mem.startsWith(u8, relative, "http://") or std.mem.startsWith(u8, relative, "https://")) {
        target.set(relative);
        return;
    }
    const slash = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse {
        target.set(relative);
        return;
    };
    target.setFmt("{s}/{s}", .{ base_url[0..slash], relative });
}

fn resolvePageUrl(target: *FixedText(2048), base_url: []const u8, relative: []const u8) void {
    if (std.mem.startsWith(u8, relative, "http://") or std.mem.startsWith(u8, relative, "https://")) {
        target.set(relative);
        return;
    }
    if (std.mem.startsWith(u8, relative, "/")) {
        const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse {
            target.set(relative);
            return;
        };
        const host_start = scheme_end + 3;
        const host_end = std.mem.indexOfPos(u8, base_url, host_start, "/") orelse base_url.len;
        target.setFmt("{s}{s}", .{ base_url[0..host_end], relative });
        return;
    }
    const slash = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse {
        target.set(relative);
        return;
    };
    target.setFmt("{s}/{s}", .{ base_url[0..slash], relative });
}

fn seasonNumberFromUrl(url: []const u8) ?u16 {
    for ([_][]const u8{ "/temporada-", "/temporada/" }) |marker| {
        const start = std.mem.indexOf(u8, url, marker) orelse continue;
        const tail = url[start + marker.len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end > 0) return std.fmt.parseUnsigned(u16, tail[0..end], 10) catch null;
    }
    return null;
}

fn findHtmlAttribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var double_buffer: [96]u8 = undefined;
    const double_needle = std.fmt.bufPrint(&double_buffer, "{s}=\"", .{name}) catch return null;
    if (std.mem.indexOf(u8, tag, double_needle)) |start| {
        const value_start = start + double_needle.len;
        const end = std.mem.indexOfPos(u8, tag, value_start, "\"") orelse return null;
        return tag[value_start..end];
    }
    var single_buffer: [96]u8 = undefined;
    const single_needle = std.fmt.bufPrint(&single_buffer, "{s}='", .{name}) catch return null;
    const start = std.mem.indexOf(u8, tag, single_needle) orelse return null;
    const value_start = start + single_needle.len;
    const end = std.mem.indexOfPos(u8, tag, value_start, "'") orelse return null;
    return tag[value_start..end];
}

fn stripTags(target: []u8, html: []const u8) []const u8 {
    var output: usize = 0;
    var inside_tag = false;
    var previous_space = true;
    for (html) |byte| {
        if (byte == '<') {
            inside_tag = true;
            continue;
        }
        if (byte == '>') {
            inside_tag = false;
            continue;
        }
        if (inside_tag) continue;
        const normalized = if (std.ascii.isWhitespace(byte)) ' ' else byte;
        if (normalized == ' ' and previous_space) continue;
        if (output >= target.len) break;
        target[output] = normalized;
        output += 1;
        previous_space = normalized == ' ';
    }
    while (output > 0 and target[output - 1] == ' ') output -= 1;
    return target[0..output];
}

fn hasSeason(series: *const Series, number: u16) bool {
    for (series.seasons[0..series.season_count]) |season| {
        if (season.number == number) return true;
    }
    return false;
}

fn addLinkedSeason(series: *Series, number: u16, base_url: []const u8, href: []const u8) void {
    if (hasSeason(series, number) or series.season_count >= series.seasons.len) return;
    const season = &series.seasons[series.season_count];
    season.* = .{ .number = number };
    resolvePageUrl(&season.url, base_url, href);
    series.season_count += 1;
}

fn addThreecatSeason(series: *Series, number: u16, root_url: []const u8) void {
    if (hasSeason(series, number) or series.season_count >= series.seasons.len) return;
    const season = &series.seasons[series.season_count];
    season.* = .{ .number = number };
    season.url.setFmt("{s}capitols/temporada/{d}/", .{ root_url, number });
    series.season_count += 1;
}

pub fn parseSeriesIndex(html: []const u8, base_url: []const u8, series: *Series) !void {
    series.clear();
    var location: SeriesLocation = .{};
    try classifySeriesUrl(base_url, &location);
    var unseasoned_chapters_url: FixedText(2048) = .{};

    if (std.mem.indexOf(u8, html, "<title")) |title_start| {
        if (std.mem.indexOfPos(u8, html, title_start, ">")) |title_open_end| {
            const value_start = title_open_end + 1;
            const title_end = std.mem.indexOfPos(u8, html, value_start, "</title>") orelse value_start;
            var title_buffer: [256]u8 = undefined;
            series.title.set(stripTags(&title_buffer, html[value_start..title_end]));
        }
    }

    var cursor: usize = 0;
    while (cursor < html.len) {
        const href_start = std.mem.indexOfPos(u8, html, cursor, "href=") orelse break;
        const tag_start = std.mem.lastIndexOfScalar(u8, html[0..href_start], '<') orelse {
            cursor = href_start + 5;
            continue;
        };
        const tag_end = std.mem.indexOfPos(u8, html, href_start, ">") orelse break;
        const tag = html[tag_start .. tag_end + 1];
        const href = findHtmlAttribute(tag, "href") orelse {
            cursor = tag_end + 1;
            continue;
        };
        if (location.kind == .threecat and
            std.mem.indexOf(u8, href, "/capitols/") != null and
            std.mem.indexOf(u8, href, "/capitols/temporada/") == null)
        {
            resolvePageUrl(&unseasoned_chapters_url, location.root_url.slice(), href);
        }
        const number = seasonNumberFromUrl(href) orelse {
            cursor = tag_end + 1;
            continue;
        };
        addLinkedSeason(series, number, location.root_url.slice(), href);
        cursor = tag_end + 1;
    }

    var option_cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html, option_cursor, "<option")) |option_start| {
        const option_end = std.mem.indexOfPos(u8, html, option_start, ">") orelse break;
        const tag = html[option_start .. option_end + 1];
        if (findHtmlAttribute(tag, "value")) |href| {
            if (seasonNumberFromUrl(href)) |number| {
                addLinkedSeason(series, number, location.root_url.slice(), href);
            }
        }
        option_cursor = option_end + 1;
    }

    if (location.kind == .threecat) {
        var season_cursor: usize = 0;
        const marker = "Temporada ";
        while (std.mem.indexOfPos(u8, html, season_cursor, marker)) |season_start| {
            const number_start = season_start + marker.len;
            var number_end = number_start;
            while (number_end < html.len and std.ascii.isDigit(html[number_end])) : (number_end += 1) {}
            if (number_end > number_start) {
                if (std.fmt.parseUnsigned(u16, html[number_start..number_end], 10)) |number| {
                    addThreecatSeason(series, number, location.root_url.slice());
                } else |_| {}
            }
            season_cursor = @max(number_end, number_start + 1);
        }
    }

    if (series.season_count == 0 and unseasoned_chapters_url.len > 0) {
        series.seasons[0] = .{ .number = 1, .is_virtual = true };
        series.seasons[0].url.set(unseasoned_chapters_url.slice());
        series.season_count = 1;
    }

    if (series.season_count == 0) return error.NoSeasons;
    std.mem.sort(Season, series.seasons[0..series.season_count], {}, struct {
        fn lessThan(_: void, left: Season, right: Season) bool {
            return left.number < right.number;
        }
    }.lessThan);
}

fn episodeNumberFromTitle(title: []const u8, season_number: u16) u16 {
    var marker_buffer: [32]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "T{d}xC", .{season_number}) catch return 0;
    const start = std.mem.indexOf(u8, title, marker) orelse return 0;
    const tail = title[start + marker.len ..];
    var end: usize = 0;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    return if (end > 0) std.fmt.parseUnsigned(u16, tail[0..end], 10) catch 0 else 0;
}

fn episodeSeasonFromTitle(title: []const u8) ?u16 {
    const start = std.mem.indexOfScalar(u8, title, 'T') orelse return null;
    const tail = title[start + 1 ..];
    var end: usize = 0;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    if (end == 0 or end + 1 >= tail.len or tail[end] != 'x' or tail[end + 1] != 'C') return null;
    return std.fmt.parseUnsigned(u16, tail[0..end], 10) catch null;
}

pub fn parseSeasonPage(html: []const u8, season_index: usize, series: *Series) !void {
    if (season_index >= series.season_count) return error.InvalidSeason;
    const season = &series.seasons[season_index];
    season.first_episode = series.episode_count;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html, cursor, "<a")) |anchor_start| {
        const anchor_open_end = std.mem.indexOfPos(u8, html, anchor_start, ">") orelse break;
        const anchor_close = std.mem.indexOfPos(u8, html, anchor_open_end, "</a>") orelse break;
        const tag = html[anchor_start .. anchor_open_end + 1];
        const href = findHtmlAttribute(tag, "href") orelse {
            cursor = anchor_close + 4;
            continue;
        };
        const id = extractEpisodeId(href) orelse {
            cursor = anchor_close + 4;
            continue;
        };
        var duplicate = false;
        for (series.episodes[0..series.episode_count]) |existing| {
            if (std.mem.eql(u8, existing.id.slice(), id)) duplicate = true;
        }
        if (duplicate or series.episode_count >= series.episodes.len) {
            cursor = anchor_close + 4;
            continue;
        }

        var title_buffer: [512]u8 = undefined;
        const anchor_body = html[anchor_open_end + 1 .. anchor_close];
        const title = findHtmlAttribute(tag, "title") orelse
            findHtmlAttribute(tag, "aria-label") orelse
            findHtmlAttribute(anchor_body, "alt") orelse
            stripTags(&title_buffer, anchor_body);
        if (episodeSeasonFromTitle(title)) |detected_season| {
            if (!season.is_virtual and detected_season != season.number) {
                cursor = anchor_close + 4;
                continue;
            }
        }
        const item = &series.episodes[series.episode_count];
        item.* = .{ .season = season.number };
        item.id.set(id);
        item.title.set(if (title.len > 0) title else id);
        item.number = episodeNumberFromTitle(title, season.number);
        resolvePageUrl(&item.url, season.url.slice(), href);
        series.episode_count += 1;
        season.episode_count += 1;
        cursor = anchor_close + 4;
    }

    const first = season.first_episode;
    const end = first + season.episode_count;
    std.mem.sort(EpisodeSummary, series.episodes[first..end], {}, struct {
        fn lessThan(_: void, left: EpisodeSummary, right: EpisodeSummary) bool {
            if (left.number == 0 and right.number != 0) return false;
            if (left.number != 0 and right.number == 0) return true;
            if (left.number != right.number) return left.number < right.number;
            return std.mem.lessThan(u8, left.title.slice(), right.title.slice());
        }
    }.lessThan);
}

pub fn parseEpisodeJson(allocator: std.mem.Allocator, json: []const u8, episode: *Episode) !void {
    episode.clear();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    if (root.get("informacio")) |information_value| {
        if (information_value == .object) {
            const information = information_value.object;
            if (jsonString(information.get("id"))) |id| episode.id.set(id);
            if (information.get("id")) |id_value| switch (id_value) {
                .integer => |id| episode.id.setFmt("{d}", .{id}),
                else => {},
            };
            if (jsonString(information.get("titol"))) |title| episode.title.set(title);
        }
    }

    const media_value = root.get("media") orelse return error.NoMedia;
    if (media_value != .object) return error.NoMedia;
    const urls_value = media_value.object.get("url") orelse return error.NoMedia;
    var selected_complete_video = false;
    if (urls_value == .array) {
        for (urls_value.array.items) |entry_value| {
            if (entry_value != .object) continue;
            const entry = entry_value.object;
            const url = jsonString(entry.get("file")) orelse continue;
            const label = jsonString(entry.get("label")) orelse "Fitxer directe";
            const path = std.Uri.parse(url) catch continue;
            const path_value = path.path.percent_encoded;
            if (std.mem.endsWith(u8, path_value, ".mpd")) {
                episode.manifest_url.set(url);
            } else if (std.mem.endsWith(u8, path_value, ".mp4") or
                std.mem.endsWith(u8, path_value, ".m4v") or
                std.mem.endsWith(u8, path_value, ".mov") or
                std.mem.endsWith(u8, path_value, ".mkv") or
                std.mem.endsWith(u8, path_value, ".webm"))
            {
                const resource = try episode.addResource(.direct_video, label, url);
                resource.selected_individual = !selected_complete_video;
                selected_complete_video = true;
            }
        }
    }

    if (root.get("subtitols")) |subtitles_value| {
        if (subtitles_value == .array) {
            for (subtitles_value.array.items) |subtitle_value| {
                if (subtitle_value != .object) continue;
                const subtitle = subtitle_value.object;
                const url = jsonString(subtitle.get("url")) orelse continue;
                const label = jsonString(subtitle.get("text")) orelse "Subtítols";
                const resource = try episode.addResource(.subtitle, label, url);
                if (jsonString(subtitle.get("iso"))) |language| resource.language.set(language);
            }
        }
    }
}

pub fn parseDashManifest(xml: []const u8, episode: *Episode) !void {
    if (episode.manifest_url.len == 0) return;
    const mpd_start = std.mem.indexOf(u8, xml, "<MPD") orelse return error.InvalidManifest;
    const mpd_end = std.mem.indexOfPos(u8, xml, mpd_start, ">") orelse return error.InvalidManifest;
    const mpd_tag = xml[mpd_start .. mpd_end + 1];
    const duration_seconds = parseDurationSeconds(attribute(mpd_tag, "mediaPresentationDuration") orelse "PT0S");

    var adaptation_cursor: usize = 0;
    var first_audio = true;
    var video_stream_index: usize = 0;
    var audio_stream_index: usize = 0;
    while (std.mem.indexOfPos(u8, xml, adaptation_cursor, "<AdaptationSet")) |adaptation_start| {
        const adaptation_open_end = std.mem.indexOfPos(u8, xml, adaptation_start, ">") orelse break;
        const adaptation_close = std.mem.indexOfPos(u8, xml, adaptation_open_end, "</AdaptationSet>") orelse break;
        const adaptation_tag = xml[adaptation_start .. adaptation_open_end + 1];
        const mime_type = attribute(adaptation_tag, "mimeType") orelse "";
        const language = attribute(adaptation_tag, "lang") orelse "";
        const kind: ResourceKind = if (std.mem.startsWith(u8, mime_type, "video/"))
            .dash_video
        else if (std.mem.startsWith(u8, mime_type, "audio/"))
            .dash_audio
        else {
            adaptation_cursor = adaptation_close + "</AdaptationSet>".len;
            continue;
        };

        var representation_cursor = adaptation_open_end + 1;
        while (std.mem.indexOfPos(u8, xml, representation_cursor, "<Representation")) |representation_start| {
            if (representation_start >= adaptation_close) break;
            const representation_open_end = std.mem.indexOfPos(u8, xml, representation_start, ">") orelse break;
            const representation_close = std.mem.indexOfPos(u8, xml, representation_open_end, "</Representation>") orelse break;
            if (representation_close > adaptation_close) break;
            const representation_tag = xml[representation_start .. representation_open_end + 1];
            const template_start = std.mem.indexOfPos(u8, xml, representation_open_end, "<SegmentTemplate") orelse break;
            if (template_start >= representation_close) break;
            const template_end = std.mem.indexOfPos(u8, xml, template_start, "/>") orelse break;
            const template_tag = xml[template_start .. template_end + 2];

            const bandwidth = parseUnsigned(attribute(representation_tag, "bandwidth"));
            const width = parseUnsigned(attribute(representation_tag, "width"));
            const height = parseUnsigned(attribute(representation_tag, "height"));
            const media = attribute(template_tag, "media") orelse return error.InvalidManifest;
            const initialization = attribute(template_tag, "initialization") orelse return error.InvalidManifest;
            const segment_duration = parseUnsigned(attribute(template_tag, "duration"));
            const timescale = parseUnsigned(attribute(template_tag, "timescale"));
            const start_number = parseUnsigned(attribute(template_tag, "startNumber"));

            var label_buffer: [160]u8 = undefined;
            const label = if (kind == .dash_video)
                std.fmt.bufPrint(&label_buffer, "{d}p · {d:.1} Mbit/s", .{ height, @as(f64, @floatFromInt(bandwidth)) / 1_000_000.0 }) catch "Vídeo DASH"
            else
                std.fmt.bufPrint(&label_buffer, "{s} · {d} kbit/s", .{ if (language.len > 0) language else "Àudio", bandwidth / 1000 }) catch "Àudio DASH";

            const resource = try episode.addResource(kind, label, episode.manifest_url.slice());
            resource.bandwidth = bandwidth;
            resource.width = @intCast(width);
            resource.height = @intCast(height);
            resource.stream_index = if (kind == .dash_video) video_stream_index else audio_stream_index;
            resource.language.set(language);
            resource.segment_start = start_number;
            if (segment_duration > 0 and timescale > 0) {
                const raw_count = duration_seconds * @as(f64, @floatFromInt(timescale)) / @as(f64, @floatFromInt(segment_duration));
                resource.segment_count = @intFromFloat(@ceil(raw_count));
            }
            resolveRelative(&resource.initialization_url, episode.manifest_url.slice(), initialization);
            resolveRelative(&resource.segment_url_template, episode.manifest_url.slice(), media);
            if (kind == .dash_video) {
                video_stream_index += 1;
            } else {
                resource.selected_mux = true;
                resource.default_audio = first_audio;
                first_audio = false;
                audio_stream_index += 1;
            }

            representation_cursor = representation_close + "</Representation>".len;
        }
        adaptation_cursor = adaptation_close + "</AdaptationSet>".len;
    }

    var best_video_index: ?usize = null;
    for (episode.resources[0..episode.resource_count], 0..) |*resource, index| {
        if (resource.kind != .dash_video) continue;
        const current_best = if (best_video_index) |best| &episode.resources[best] else null;
        if (current_best == null or
            resource.height > current_best.?.height or
            (resource.height == current_best.?.height and resource.bandwidth > current_best.?.bandwidth))
        {
            best_video_index = index;
        }
    }
    if (best_video_index) |index| episode.resources[index].selected_mux = true;
}

test "extract episode id" {
    try std.testing.expectEqualStrings(
        "6314970",
        extractEpisodeId("https://www.3cat.cat/foo/video/6314970/").?,
    );
    try std.testing.expect(extractEpisodeId("https://www.3cat.cat/serie/") == null);
}

test "normalize season url to series root" {
    var normalized: FixedText(2048) = .{};
    try normalizeSeriesUrl(
        "https://www.3cat.cat/tv3/sx3/bola-de-drac-super/videos/temporada-1/",
        &normalized,
    );
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/tv3/sx3/bola-de-drac-super/",
        normalized.slice(),
    );

    try normalizeSeriesUrl(
        "https://www.3cat.cat/tv3/sx3/bola-de-drac-super?foo=bar",
        &normalized,
    );
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/tv3/sx3/bola-de-drac-super/",
        normalized.slice(),
    );

    var location: SeriesLocation = .{};
    try classifySeriesUrl(
        "https://www.3cat.cat/3cat/la-patrulla-peluda/capitols/temporada/1/",
        &location,
    );
    try std.testing.expectEqual(SeriesUrlKind.threecat, location.kind);
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/la-patrulla-peluda/",
        location.root_url.slice(),
    );

    try normalizeSeriesUrl(
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/capitols/",
        &normalized,
    );
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/",
        normalized.slice(),
    );
}

test "parse manifest resources" {
    const xml =
        \\<?xml version="1.0"?><MPD mediaPresentationDuration="P0Y0M0DT0H0M8.0S">
        \\<Period><AdaptationSet mimeType="video/mp4"><Representation bandwidth="1000000" width="1280" height="720">
        \\<SegmentTemplate media="video/720/segment_$Number$.m4s" initialization="video/720/init.mp4" duration="100000" startNumber="0" timescale="25000"/>
        \\</Representation><Representation bandwidth="4000000" width="1920" height="1080">
        \\<SegmentTemplate media="video/segment_$Number$.m4s" initialization="video/init.mp4" duration="100000" startNumber="0" timescale="25000"/>
        \\</Representation></AdaptationSet></Period></MPD>
    ;
    var episode: Episode = .{};
    episode.manifest_url.set("https://example.test/path/stream.mpd");
    try parseDashManifest(xml, &episode);
    try std.testing.expectEqual(@as(usize, 2), episode.resource_count);
    try std.testing.expectEqual(@as(u64, 2), episode.resources[0].segment_count);
    try std.testing.expect(!episode.resources[0].selected_mux);
    try std.testing.expect(episode.resources[1].selected_mux);
    try std.testing.expectEqualStrings(
        "https://example.test/path/video/720/init.mp4",
        episode.resources[0].initialization_url.slice(),
    );
}

test "parse series seasons and episodes" {
    const index_html =
        \\<title>La patrulla peluda</title>
        \\<a href="/tv3/sx3/la-patrulla-peluda/videos/temporada-2/">Temporada 2</a>
        \\<option value="/tv3/sx3/la-patrulla-peluda/videos/temporada-1/">Temporada 1</option>
    ;
    var series: Series = .{};
    try parseSeriesIndex(index_html, "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/", &series);
    try std.testing.expectEqual(@as(usize, 2), series.season_count);
    try std.testing.expectEqual(@as(u16, 1), series.seasons[0].number);

    const season_html =
        \\<a title="T1xC2 - Segon episodi" href="/tv3/sx3/segon/video/123/">Segon</a>
        \\<a title="T1xC1 - Primer episodi" href="/tv3/sx3/primer/video/122/">Primer</a>
        \\<a title="T2xC1 - Altra temporada" href="/tv3/sx3/altre/video/999/">Altre</a>
    ;
    try parseSeasonPage(season_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episode_count);
    try std.testing.expectEqualStrings("122", series.episodes[0].id.slice());
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/tv3/sx3/primer/video/122/",
        series.episodes[0].url.slice(),
    );
}

test "parse new 3cat series and nested episode title" {
    const index_html =
        \\<title data-next-head="">La Patrulla Peluda - 3Cat</title>
        \\<button aria-label="Obrir desplegable temporades">Temporada 3</button>
        \\<ul><li>Temporada 3</li><li>Temporada 2</li><li>Temporada 1</li></ul>
        \\<a href="/3cat/la-patrulla-peluda/capitols/temporada/3/">Tots</a>
    ;
    var series: Series = .{};
    try parseSeriesIndex(index_html, "https://www.3cat.cat/3cat/la-patrulla-peluda/", &series);
    try std.testing.expectEqual(@as(usize, 3), series.season_count);
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/la-patrulla-peluda/capitols/temporada/1/",
        series.seasons[0].url.slice(),
    );

    const season_html =
        \\<a href="/3cat/t1xc1-primer/video/6314970/"><img alt="T1xC1 - Primer episodi"/></a>
        \\<a href="/3cat/t1xc1-primer/video/6314970/"><h2>T1xC1 - Primer episodi</h2></a>
        \\<a href="/3cat/t1xc2-segon/video/6314971/"><img alt="T1xC2 - Segon episodi"/></a>
    ;
    try parseSeasonPage(season_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episode_count);
    try std.testing.expectEqualStrings("T1xC1 - Primer episodi", series.episodes[0].title.slice());
    try std.testing.expectEqualStrings("6314970", series.episodes[0].id.slice());
}

test "parse new 3cat program without seasons" {
    const index_html =
        \\<title>&quot;Lo Cartanyà&quot;, especial 20 anys - 3Cat</title>
        \\<a href="/3cat/lo-cartanya-especial-20-anys/capitols/">Capítols</a>
    ;
    var series: Series = .{};
    try parseSeriesIndex(
        index_html,
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/",
        &series,
    );
    try std.testing.expectEqual(@as(usize, 1), series.season_count);
    try std.testing.expect(series.seasons[0].is_virtual);
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/capitols/",
        series.seasons[0].url.slice(),
    );

    const chapters_html =
        \\<a href="/3cat/t1xc1-primer/video/6385177/"><img alt="T1xC1 - Primer"/></a>
        \\<a href="/3cat/t2xc1-segon/video/6385178/"><img alt="T2xC1 - Segon"/></a>
    ;
    try parseSeasonPage(chapters_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episode_count);
}

test "parse catalog embedded in next data" {
    const html =
        \\<html><body><script id="__NEXT_DATA__" type="application/json">
        \\{"props":{"items":[
        \\{"tipologia":"PTVC_PROGRAMA","nombonic":"zeta","titol":"Zeta"},
        \\{"tipologia":"PTVC_VIDEO","nombonic":"ignorat","titol":"Ignorat"},
        \\{"tipologia":"PTVC_PROGRAMA","nombonic":"alfa","titol":"Alfa"},
        \\{"tipologia":"PTVC_PROGRAMA","nombonic":"alfa","titol":"Alfa duplicat"}
        \\]}}</script></body></html>
    ;
    var catalog: Catalog = .{};
    try parseCatalogPage(std.testing.allocator, html, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.item_count);
    try std.testing.expectEqualStrings("Alfa", catalog.items[0].title.slice());
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/alfa/",
        catalog.items[0].url.slice(),
    );
}
