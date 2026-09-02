//! Per-language lexical skip-rules (2026-09-01, extracted from
//! `Parser.zig`'s own `scanUntilMatchingBrace`): string/rune/raw-string
//! literal and comment skipping, generic over any cursor-shaped type
//! (`anytype`, needs `pub fn peek`/`peekAt`/`advance`/`fail` -- exactly
//! `Parser`'s own shape) rather than tied to `Parser` specifically.
//!
//! Why this exists as its own file rather than staying inline in
//! `Parser.zig`: the upcoming `<%...%>` raw-code escape (natyv's `.ntx`
//! dynamic-content work) needs the identical string/comment-aware
//! scanning to find its own closing `%>` without a `}`/`%`-containing Go
//! string or comment ending the block early -- the exact same problem
//! `scanUntilMatchingBrace` already solved for `{`/`}`. Sharing this one
//! implementation (via `Parser.zig` delegating to it, see
//! `scanUntilMatchingBrace`'s own body) instead of a second hand-rolled
//! copy is the whole point.
//!
//! Deliberately scoped to `Lang.go` only for now -- every one of these
//! rules is Go's own specific lexical shape (double-quote escaping,
//! backtick raw strings, single-quote runes, `//`/`/* */` comments), not
//! a generic multi-language tokenizer. Rust/Python/C++ will each need
//! their own `Lang` case with their own real rules (Rust's `r"..."`/
//! `r#"..."#` raw strings and no backtick strings; Python's `#` comments,
//! no `/* */`, triple-quoted strings) whenever those SDKs actually land
//! (matching the project's demand-driven SDK approach) -- not assumed or
//! guessed at here.

const std = @import("std");

pub const Lang = enum { go };

/// Scans a double-quoted string literal starting at the opening `"`,
/// returning the raw (unescaped) content between the quotes.
/// Escape-aware only enough to find the real closing quote -- `\"` never
/// ends the literal early, never interprets what an escape means, same
/// "store raw source bytes" choice as the returned value.
pub fn scanQuotedString(parser: anytype, lang: Lang) error{ParseError}![]const u8 {
    switch (lang) {
        .go => {
            const quote_line = parser.line;
            const quote_col = parser.col;
            parser.advance(); // consume opening '"'
            const start = parser.pos;
            while (parser.peek()) |b| {
                if (b == '"') {
                    const content = parser.src[start..parser.pos];
                    parser.advance();
                    return content;
                }
                if (b == '\\' and parser.peekAt(1) != null) {
                    parser.advance();
                    parser.advance();
                    continue;
                }
                parser.advance();
            }
            return parser.fail(quote_line, quote_col, "unterminated string literal", .{});
        },
    }
}

/// Scans a backtick-delimited raw string literal (Go's own -- no escape
/// sequences of any kind are recognized inside one, matching Go's real
/// semantics).
pub fn scanRawString(parser: anytype, lang: Lang) error{ParseError}!void {
    switch (lang) {
        .go => {
            const line = parser.line;
            const col = parser.col;
            parser.advance(); // opening '`'
            while (parser.peek()) |b| {
                parser.advance();
                if (b == '`') return;
            }
            return parser.fail(line, col, "unterminated raw string literal", .{});
        },
    }
}

/// Scans a single-quoted rune literal.
pub fn scanRuneLiteral(parser: anytype, lang: Lang) error{ParseError}!void {
    switch (lang) {
        .go => {
            const line = parser.line;
            const col = parser.col;
            parser.advance(); // opening '\''
            while (parser.peek()) |b| {
                if (b == '\\' and parser.peekAt(1) != null) {
                    parser.advance();
                    parser.advance();
                    continue;
                }
                parser.advance();
                if (b == '\'') return;
            }
            return parser.fail(line, col, "unterminated rune literal", .{});
        },
    }
}

/// Handles a bare `/` at the current position: a `//` line comment, a
/// `/* */` block comment, or (if followed by neither) just an ordinary
/// `/` byte -- consumes at least one byte in every case, so a caller's
/// own scan loop always makes forward progress.
pub fn skipSlash(parser: anytype, lang: Lang) void {
    switch (lang) {
        .go => {
            if (parser.peekAt(1) == '/') {
                while (parser.peek()) |c| {
                    if (c == '\n') break;
                    parser.advance();
                }
            } else if (parser.peekAt(1) == '*') {
                parser.advance();
                parser.advance();
                while (parser.peek()) |_| {
                    if (parser.peek() == '*' and parser.peekAt(1) == '/') {
                        parser.advance();
                        parser.advance();
                        break;
                    }
                    parser.advance();
                }
            } else {
                parser.advance();
            }
        },
    }
}

/// A minimal, purpose-built stand-in for `Parser`'s own cursor shape,
/// used only by this file's own tests -- proves these functions are
/// genuinely generic (work against *any* conforming type), not just
/// "happens to work because it was only ever exercised against the one
/// real `Parser`."
const TestCursor = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    last_error: ?struct { line: u32, col: u32, message: []const u8 } = null,

    fn peek(self: TestCursor) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn peekAt(self: TestCursor, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else null;
    }
    fn advance(self: *TestCursor) void {
        if (self.pos >= self.src.len) return;
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }
    fn fail(self: *TestCursor, line: u32, col: u32, comptime fmt: []const u8, args: anytype) error{ParseError} {
        self.last_error = .{ .line = line, .col = col, .message = std.fmt.comptimePrint(fmt, args) };
        return error.ParseError;
    }
};

test "scanQuotedString returns the raw content and stops at the real closing quote" {
    var c: TestCursor = .{ .src = "\"hello\" rest" };
    const content = try scanQuotedString(&c, .go);
    try std.testing.expectEqualStrings("hello", content);
    try std.testing.expectEqual(@as(usize, 7), c.pos); // right after the closing quote
}

test "scanQuotedString treats an escaped quote as content, not a terminator" {
    var c: TestCursor = .{ .src = "\"a\\\"b\"" };
    const content = try scanQuotedString(&c, .go);
    try std.testing.expectEqualStrings("a\\\"b", content);
}

test "scanQuotedString reports a real error on an unterminated string" {
    var c: TestCursor = .{ .src = "\"never closed" };
    try std.testing.expectError(error.ParseError, scanQuotedString(&c, .go));
}

test "scanRawString ignores backslashes entirely (Go's own raw-string semantics)" {
    var c: TestCursor = .{ .src = "`a\\b`" };
    try scanRawString(&c, .go);
    try std.testing.expectEqual(@as(usize, 5), c.pos);
}

test "scanRuneLiteral handles an escaped quote inside a rune" {
    var c: TestCursor = .{ .src = "'\\''" };
    try scanRuneLiteral(&c, .go);
    try std.testing.expectEqual(@as(usize, 4), c.pos);
}

test "skipSlash consumes a line comment through the newline, not past it" {
    var c: TestCursor = .{ .src = "// a comment\nnext" };
    skipSlash(&c, .go);
    try std.testing.expectEqual(@as(u8, '\n'), c.peek().?);
}

test "skipSlash consumes a block comment through its closing */" {
    var c: TestCursor = .{ .src = "/* a } weird block */ rest" };
    skipSlash(&c, .go);
    try std.testing.expectEqualStrings(" rest", c.src[c.pos..]);
}

test "skipSlash treats a bare slash as an ordinary single byte" {
    var c: TestCursor = .{ .src = "/x" };
    skipSlash(&c, .go);
    try std.testing.expectEqual(@as(u8, 'x'), c.peek().?);
}
