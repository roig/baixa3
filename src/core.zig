const std = @import("std");

pub const max_resources = 64;
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
    program: FixedText(256) = .{},
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

pub const SeasonPagination = struct {
    url: FixedText(4096) = .{},
    total_pages: u32 = 0,
};

pub const Series = struct {
    title: FixedText(256) = .{},
    seasons: std.ArrayList(Season) = .empty,
    episodes: std.ArrayList(EpisodeSummary) = .empty,

    pub fn clear(self: *Series) void {
        self.title = .{};
        self.seasons.clearRetainingCapacity();
        self.episodes.clearRetainingCapacity();
    }

    pub fn deinit(self: *Series, allocator: std.mem.Allocator) void {
        self.seasons.deinit(allocator);
        self.episodes.deinit(allocator);
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

fn jsonUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .string => |text| std.fmt.parseUnsigned(u64, text, 10) catch null,
        else => null,
    };
}

fn findSeasonPagination(value: std.json.Value, pagination: *SeasonPagination) bool {
    switch (value) {
        .object => |object| {
            if (object.get("paginacio")) |pagination_value| {
                if (pagination_value == .object) {
                    const total_pages = jsonUnsigned(pagination_value.object.get("total_pagines")) orelse 0;
                    const url = jsonString(object.get("url")) orelse "";
                    if (total_pages > 0 and std.mem.indexOf(u8, url, "/videos?") != null) {
                        const placeholder = "%%dataResources.apiCCMA%%";
                        if (std.mem.startsWith(u8, url, placeholder)) {
                            pagination.url.setFmt("https://api.3cat.cat{s}", .{url[placeholder.len..]});
                        } else {
                            pagination.url.set(url);
                        }
                        pagination.total_pages = @intCast(total_pages);
                        return true;
                    }
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (findSeasonPagination(entry.value_ptr.*, pagination)) return true;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findSeasonPagination(item, pagination)) return true;
            }
        },
        else => {},
    }
    return false;
}

pub fn parseSeasonPagination(
    allocator: std.mem.Allocator,
    html: []const u8,
    pagination: *SeasonPagination,
) !bool {
    pagination.* = .{};
    const id_position = std.mem.indexOf(u8, html, "id=\"__NEXT_DATA__\"") orelse return false;
    const script_start = std.mem.lastIndexOf(u8, html[0..id_position], "<script") orelse return false;
    const json_start_marker = std.mem.indexOfPos(u8, html, script_start, ">") orelse return false;
    const json_start = json_start_marker + 1;
    const json_end = std.mem.indexOfPos(u8, html, json_start, "</script>") orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, html[json_start..json_end], .{});
    defer parsed.deinit();
    return findSeasonPagination(parsed.value, pagination);
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

fn htmlEntityCodepoint(entity: []const u8) ?u21 {
    if (std.mem.eql(u8, entity, "amp")) return '&';
    if (std.mem.eql(u8, entity, "quot")) return '"';
    if (std.mem.eql(u8, entity, "apos")) return '\'';
    if (std.mem.eql(u8, entity, "lt")) return '<';
    if (std.mem.eql(u8, entity, "gt")) return '>';
    if (std.mem.eql(u8, entity, "nbsp")) return ' ';
    if (entity.len > 2 and entity[0] == '#' and (entity[1] == 'x' or entity[1] == 'X')) {
        return std.fmt.parseUnsigned(u21, entity[2..], 16) catch null;
    }
    if (entity.len > 1 and entity[0] == '#') {
        return std.fmt.parseUnsigned(u21, entity[1..], 10) catch null;
    }
    return null;
}

fn decodeHtmlEntities(target: []u8, value: []const u8) []const u8 {
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < value.len and output_index < target.len) {
        if (value[input_index] == '&') {
            if (std.mem.indexOfScalar(u8, value[input_index..], ';')) |relative_end| {
                if (relative_end <= 16) {
                    const entity = value[input_index + 1 .. input_index + relative_end];
                    if (htmlEntityCodepoint(entity)) |codepoint| {
                        var encoded: [4]u8 = undefined;
                        const encoded_length = std.unicode.utf8Encode(codepoint, &encoded) catch 0;
                        if (encoded_length > 0 and output_index + encoded_length <= target.len) {
                            @memcpy(target[output_index .. output_index + encoded_length], encoded[0..encoded_length]);
                            output_index += encoded_length;
                            input_index += relative_end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        target[output_index] = value[input_index];
        output_index += 1;
        input_index += 1;
    }
    return target[0..output_index];
}

fn elementText(target: []u8, html: []const u8, tag_name: []const u8) ?[]const u8 {
    var opening_buffer: [32]u8 = undefined;
    const opening = std.fmt.bufPrint(&opening_buffer, "<{s}", .{tag_name}) catch return null;
    const element_start = std.mem.indexOf(u8, html, opening) orelse return null;
    const content_marker = std.mem.indexOfPos(u8, html, element_start, ">") orelse return null;
    const content_start = content_marker + 1;
    var closing_buffer: [32]u8 = undefined;
    const closing = std.fmt.bufPrint(&closing_buffer, "</{s}>", .{tag_name}) catch return null;
    const content_end = std.mem.indexOfPos(u8, html, content_start, closing) orelse return null;
    const text = stripTags(target, html[content_start..content_end]);
    return if (text.len > 0) text else null;
}

fn hasSeason(series: *const Series, number: u16) bool {
    for (series.seasons.items) |season| {
        if (season.number == number) return true;
    }
    return false;
}

fn addLinkedSeason(
    allocator: std.mem.Allocator,
    series: *Series,
    number: u16,
    base_url: []const u8,
    href: []const u8,
) !void {
    if (hasSeason(series, number)) return;
    var season: Season = .{ .number = number };
    resolvePageUrl(&season.url, base_url, href);
    try series.seasons.append(allocator, season);
}

fn addThreecatSeason(
    allocator: std.mem.Allocator,
    series: *Series,
    number: u16,
    root_url: []const u8,
) !void {
    if (hasSeason(series, number)) return;
    var season: Season = .{ .number = number };
    season.url.setFmt("{s}capitols/temporada/{d}/", .{ root_url, number });
    try series.seasons.append(allocator, season);
}

pub fn parseSeriesIndex(
    allocator: std.mem.Allocator,
    html: []const u8,
    base_url: []const u8,
    series: *Series,
) !void {
    series.clear();
    var location: SeriesLocation = .{};
    try classifySeriesUrl(base_url, &location);
    var unseasoned_chapters_url: FixedText(2048) = .{};

    if (std.mem.indexOf(u8, html, "<title")) |title_start| {
        if (std.mem.indexOfPos(u8, html, title_start, ">")) |title_open_end| {
            const value_start = title_open_end + 1;
            const title_end = std.mem.indexOfPos(u8, html, value_start, "</title>") orelse value_start;
            var title_buffer: [256]u8 = undefined;
            var decoded_title_buffer: [256]u8 = undefined;
            const raw_title = stripTags(&title_buffer, html[value_start..title_end]);
            series.title.set(decodeHtmlEntities(&decoded_title_buffer, raw_title));
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
        try addLinkedSeason(allocator, series, number, location.root_url.slice(), href);
        cursor = tag_end + 1;
    }

    var option_cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html, option_cursor, "<option")) |option_start| {
        const option_end = std.mem.indexOfPos(u8, html, option_start, ">") orelse break;
        const tag = html[option_start .. option_end + 1];
        if (findHtmlAttribute(tag, "value")) |href| {
            if (seasonNumberFromUrl(href)) |number| {
                try addLinkedSeason(allocator, series, number, location.root_url.slice(), href);
            }
        }
        option_cursor = option_end + 1;
    }

    if (location.kind == .threecat) {
        var dropdown_cursor: usize = 0;
        const dropdown_marker = "data-testid=\"dropdown\"";
        while (std.mem.indexOfPos(u8, html, dropdown_cursor, dropdown_marker)) |dropdown_start| {
            const list_end = std.mem.indexOfPos(u8, html, dropdown_start, "</ul>") orelse break;
            const dropdown = html[dropdown_start .. list_end + "</ul>".len];
            var season_cursor: usize = 0;
            const season_marker = "Temporada ";
            while (std.mem.indexOfPos(u8, dropdown, season_cursor, season_marker)) |season_start| {
                const number_start = season_start + season_marker.len;
                var number_end = number_start;
                while (number_end < dropdown.len and std.ascii.isDigit(dropdown[number_end])) : (number_end += 1) {}
                if (number_end > number_start) {
                    if (std.fmt.parseUnsigned(u16, dropdown[number_start..number_end], 10)) |number| {
                        try addThreecatSeason(allocator, series, number, location.root_url.slice());
                    } else |_| {}
                }
                season_cursor = @max(number_end, number_start + 1);
            }
            dropdown_cursor = list_end + "</ul>".len;
        }
    }

    if (series.seasons.items.len == 0 and unseasoned_chapters_url.len > 0) {
        var season: Season = .{ .number = 1, .is_virtual = true };
        season.url.set(unseasoned_chapters_url.slice());
        try series.seasons.append(allocator, season);
    }

    if (series.seasons.items.len == 0) return error.NoSeasons;
    std.mem.sort(Season, series.seasons.items, {}, struct {
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

fn sortSeasonEpisodes(series: *Series, season: *const Season) void {
    const first = season.first_episode;
    const end = first + season.episode_count;
    std.mem.sort(EpisodeSummary, series.episodes.items[first..end], {}, struct {
        fn lessThan(_: void, left: EpisodeSummary, right: EpisodeSummary) bool {
            if (left.number == 0 and right.number != 0) return false;
            if (left.number != 0 and right.number == 0) return true;
            if (left.number != right.number) return left.number < right.number;
            return std.mem.lessThan(u8, left.title.slice(), right.title.slice());
        }
    }.lessThan);
}

pub fn parseSeasonPage(
    allocator: std.mem.Allocator,
    html: []const u8,
    season_index: usize,
    series: *Series,
) !void {
    if (season_index >= series.seasons.items.len) return error.InvalidSeason;
    const season = &series.seasons.items[season_index];
    season.first_episode = series.episodes.items.len;
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
        for (series.episodes.items) |existing| {
            if (std.mem.eql(u8, existing.id.slice(), id)) duplicate = true;
        }
        if (duplicate) {
            cursor = anchor_close + 4;
            continue;
        }

        var title_buffer: [512]u8 = undefined;
        var heading_buffer: [512]u8 = undefined;
        const anchor_body = html[anchor_open_end + 1 .. anchor_close];
        const title = findHtmlAttribute(tag, "title") orelse
            findHtmlAttribute(tag, "aria-label") orelse
            elementText(&heading_buffer, anchor_body, "h2") orelse
            elementText(&heading_buffer, anchor_body, "h3") orelse
            findHtmlAttribute(anchor_body, "alt") orelse
            stripTags(&title_buffer, anchor_body);
        var decoded_title_buffer: [512]u8 = undefined;
        const decoded_title = decodeHtmlEntities(&decoded_title_buffer, title);
        if (episodeSeasonFromTitle(decoded_title)) |detected_season| {
            if (!season.is_virtual and detected_season != season.number) {
                cursor = anchor_close + 4;
                continue;
            }
        }
        var item: EpisodeSummary = .{ .season = season.number };
        item.id.set(id);
        item.title.set(if (decoded_title.len > 0) decoded_title else id);
        item.number = episodeNumberFromTitle(decoded_title, season.number);
        resolvePageUrl(&item.url, season.url.slice(), href);
        try series.episodes.append(allocator, item);
        season.episode_count += 1;
        cursor = anchor_close + 4;
    }

    sortSeasonEpisodes(series, season);
}

pub fn parseSeasonApiPage(
    allocator: std.mem.Allocator,
    json: []const u8,
    season_index: usize,
    series: *Series,
) !void {
    if (season_index >= series.seasons.items.len) return error.InvalidSeason;
    const season = &series.seasons.items[season_index];
    if (season.episode_count == 0) season.first_episode = series.episodes.items.len;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApiResponse;
    const response_value = parsed.value.object.get("resposta") orelse return error.InvalidApiResponse;
    if (response_value != .object) return error.InvalidApiResponse;
    const items_value = response_value.object.get("items") orelse return error.InvalidApiResponse;
    if (items_value != .object) return error.InvalidApiResponse;
    const item_value = items_value.object.get("item") orelse return error.InvalidApiResponse;
    if (item_value != .array) return error.InvalidApiResponse;

    for (item_value.array.items) |value| {
        if (value != .object) continue;
        const object = value.object;
        const id_number = jsonUnsigned(object.get("id")) orelse continue;
        const slug = jsonString(object.get("nom_friendly")) orelse continue;
        if (slug.len == 0) continue;

        var id: FixedText(32) = .{};
        id.setFmt("{d}", .{id_number});
        var duplicate = false;
        for (series.episodes.items) |existing| {
            if (std.mem.eql(u8, existing.id.slice(), id.slice())) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        const code = jsonString(object.get("titol")) orelse "";
        const descriptive_title = jsonString(object.get("permatitle")) orelse "";
        var item: EpisodeSummary = .{ .season = season.number };
        item.id = id;
        if (code.len > 0 and descriptive_title.len > 0 and !std.mem.eql(u8, code, descriptive_title)) {
            item.title.setFmt("{s} - {s}", .{ code, descriptive_title });
        } else if (descriptive_title.len > 0) {
            item.title.set(descriptive_title);
        } else if (code.len > 0) {
            item.title.set(code);
        } else {
            item.title.set(id.slice());
        }
        const episode_number = jsonUnsigned(object.get("capitol_temporada")) orelse
            jsonUnsigned(object.get("capitol")) orelse 0;
        item.number = @intCast(@min(episode_number, std.math.maxInt(u16)));
        item.url.setFmt("https://www.3cat.cat/3cat/{s}/video/{s}/", .{ slug, id.slice() });
        try series.episodes.append(allocator, item);
        season.episode_count += 1;
    }
    sortSeasonEpisodes(series, season);
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
            if (jsonString(information.get("programa"))) |program| {
                const permalink = jsonString(information.get("permalink")) orelse "";
                if (std.mem.indexOf(u8, permalink, "/3cat/") != null) {
                    episode.program.setFmt("{s} - 3Cat", .{program});
                } else if (std.mem.indexOf(u8, permalink, "/tv3/sx3/") != null) {
                    episode.program.setFmt("{s} - SX3", .{program});
                } else {
                    episode.program.set(program);
                }
            }
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

test "parse episode program metadata" {
    const json =
        \\{
        \\  "informacio": {"id": 6077759, "titol": "Aitana", "programa": "Adolescents XL", "permalink": "https://www.3cat.cat/3cat/aitana/video/6077759/"},
        \\  "media": {"url": []}
        \\}
    ;
    var episode: Episode = .{};
    try parseEpisodeJson(std.testing.allocator, json, &episode);
    try std.testing.expectEqualStrings("6077759", episode.id.slice());
    try std.testing.expectEqualStrings("Aitana", episode.title.slice());
    try std.testing.expectEqualStrings("Adolescents XL - 3Cat", episode.program.slice());
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
    defer series.deinit(std.testing.allocator);
    try parseSeriesIndex(std.testing.allocator, index_html, "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/", &series);
    try std.testing.expectEqual(@as(usize, 2), series.seasons.items.len);
    try std.testing.expectEqual(@as(u16, 1), series.seasons.items[0].number);

    const season_html =
        \\<a title="T1xC2 - Segon episodi" href="/tv3/sx3/segon/video/123/">Segon</a>
        \\<a title="T1xC1 - Primer episodi" href="/tv3/sx3/primer/video/122/">Primer</a>
        \\<a title="T2xC1 - Altra temporada" href="/tv3/sx3/altre/video/999/">Altre</a>
    ;
    try parseSeasonPage(std.testing.allocator, season_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episodes.items.len);
    try std.testing.expectEqualStrings("122", series.episodes.items[0].id.slice());
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/tv3/sx3/primer/video/122/",
        series.episodes.items[0].url.slice(),
    );
}

test "parse new 3cat series and nested episode title" {
    const index_html =
        \\<title data-next-head="">La Patrulla Peluda - 3Cat</title>
        \\<button aria-label="Obrir desplegable temporades">Temporada 3</button>
        \\<ul data-testid="dropdown"><li>Temporada 3</li><li>Temporada 2</li><li>Temporada 1</li></ul>
        \\<a href="/3cat/la-patrulla-peluda/capitols/temporada/3/">Tots</a>
    ;
    var series: Series = .{};
    defer series.deinit(std.testing.allocator);
    try parseSeriesIndex(std.testing.allocator, index_html, "https://www.3cat.cat/3cat/la-patrulla-peluda/", &series);
    try std.testing.expectEqual(@as(usize, 3), series.seasons.items.len);
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/la-patrulla-peluda/capitols/temporada/1/",
        series.seasons.items[0].url.slice(),
    );

    const season_html =
        \\<a href="/3cat/t1xc1-primer/video/6314970/"><img alt="T1xC1 - Primer episodi"/></a>
        \\<a href="/3cat/t1xc1-primer/video/6314970/"><h2>T1xC1 - Primer episodi</h2></a>
        \\<a href="/3cat/t1xc2-segon/video/6314971/"><img alt="T1xC2 - Segon episodi"/></a>
    ;
    try parseSeasonPage(std.testing.allocator, season_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episodes.items.len);
    try std.testing.expectEqualStrings("T1xC1 - Primer episodi", series.episodes.items[0].title.slice());
    try std.testing.expectEqualStrings("6314970", series.episodes.items[0].id.slice());
}

test "parse new 3cat program without seasons" {
    const index_html =
        \\<title>&quot;Lo Cartanyà&quot;, especial 20 anys - 3Cat</title>
        \\<a href="/3cat/lo-cartanya-especial-20-anys/capitols/">Capítols</a>
        \\<script>{"info_distribucio":"Temporada 5 disponible"}</script>
    ;
    var series: Series = .{};
    defer series.deinit(std.testing.allocator);
    try parseSeriesIndex(
        std.testing.allocator,
        index_html,
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/",
        &series,
    );
    try std.testing.expectEqual(@as(usize, 1), series.seasons.items.len);
    try std.testing.expect(series.seasons.items[0].is_virtual);
    try std.testing.expectEqualStrings(
        "\"Lo Cartanyà\", especial 20 anys - 3Cat",
        series.title.slice(),
    );
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/lo-cartanya-especial-20-anys/capitols/",
        series.seasons.items[0].url.slice(),
    );

    const chapters_html =
        \\<a href="/3cat/t1xc1-primer/video/6385177/"><img alt="T1xC1 - Primer"/></a>
        \\<a href="/3cat/t2xc1-segon/video/6385178/"><img alt="T2xC1 - L&#x27;Albert"/></a>
        \\<a href="/3cat/t1xc1-primer/video/6385177/"><h2>T1xC1 - Primer</h2><img alt="Icona rellotge"/></a>
    ;
    try parseSeasonPage(std.testing.allocator, chapters_html, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episodes.items.len);
    try std.testing.expectEqualStrings("T1xC1 - Primer", series.episodes.items[0].title.slice());
    try std.testing.expectEqualStrings("T2xC1 - L'Albert", series.episodes.items[1].title.slice());
}

test "series grows beyond the previous season and episode limits" {
    var index_html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer index_html.deinit();
    try index_html.writer.writeAll("<title>Sèrie llarga</title><ul data-testid=\"dropdown\">");
    for (1..21) |number| try index_html.writer.print("<li>Temporada {d}</li>", .{number});
    try index_html.writer.writeAll("</ul>");

    var series: Series = .{};
    defer series.deinit(std.testing.allocator);
    try parseSeriesIndex(
        std.testing.allocator,
        index_html.written(),
        "https://www.3cat.cat/3cat/serie-llarga/",
        &series,
    );
    try std.testing.expectEqual(@as(usize, 20), series.seasons.items.len);

    var season_html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer season_html.deinit();
    for (1..601) |number| {
        try season_html.writer.print(
            "<a title=\"T1xC{d} - Episodi {d}\" href=\"/3cat/episodi-{d}/video/{d}/\">Episodi</a>",
            .{ number, number, number, 6_000_000 + number },
        );
    }
    try parseSeasonPage(std.testing.allocator, season_html.written(), 0, &series);
    try std.testing.expectEqual(@as(usize, 600), series.episodes.items.len);
}

test "parse paginated season metadata and API episodes" {
    const html =
        \\<script id="__NEXT_DATA__" type="application/json">
        \\{"props":{"module":{"paginacio":{"total_items":44,"items_pagina":18,"pagina_actual":1,"total_pagines":3},"url":"%%dataResources.apiCCMA%%/videos?_format=json&items_pagina=18&pagina=1&temporada=PUTEMP_1"}}}
        \\</script>
    ;
    var pagination: SeasonPagination = .{};
    try std.testing.expect(try parseSeasonPagination(std.testing.allocator, html, &pagination));
    try std.testing.expectEqual(@as(u32, 3), pagination.total_pages);
    try std.testing.expectEqualStrings(
        "https://api.3cat.cat/videos?_format=json&items_pagina=18&pagina=1&temporada=PUTEMP_1",
        pagination.url.slice(),
    );

    const page_json =
        \\{"resposta":{"items":{"num":2,"item":[
        \\{"id":181390691,"titol":"T1xC19","permatitle":"Teresa i Julià","nom_friendly":"teresa-i-julia-cap-19","capitol_temporada":19},
        \\{"id":425,"titol":"T1xC20","permatitle":"L'Alfons torna","nom_friendly":"alfons-torna-cap-20","capitol_temporada":20}
        \\]},"paginacio":{"total_pagines":3}}}
    ;
    var series: Series = .{};
    defer series.deinit(std.testing.allocator);
    try series.seasons.append(std.testing.allocator, .{ .number = 1 });
    try parseSeasonApiPage(std.testing.allocator, page_json, 0, &series);
    try std.testing.expectEqual(@as(usize, 2), series.episodes.items.len);
    try std.testing.expectEqualStrings("T1xC19 - Teresa i Julià", series.episodes.items[0].title.slice());
    try std.testing.expectEqualStrings(
        "https://www.3cat.cat/3cat/alfons-torna-cap-20/video/425/",
        series.episodes.items[1].url.slice(),
    );
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
