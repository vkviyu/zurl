/// Command-line argument parsing utilities.
///
/// Provides functions for parsing quoted/unquoted argument values
/// from a raw input string with manual cursor tracking.

/// Parse a single argument value starting at `pos.*`.
/// Supports double-quoted ("..."), single-quoted ('...'), and bare tokens.
/// Advances `pos` past the parsed value (including closing quote if any).
pub fn parseValue(input: []const u8, pos: *usize) ![]const u8 {
    var i = pos.*;
    if (i >= input.len) return error.MissingArgValue;

    if (input[i] == '"' or input[i] == '\'') {
        const quote = input[i];
        i += 1;
        const start = i;
        while (i < input.len and input[i] != quote) : (i += 1) {}
        const val = input[start..i];
        if (i < input.len) i += 1; // skip closing quote
        pos.* = i;
        return val;
    }

    // Unquoted: read until whitespace
    const start = i;
    while (i < input.len and input[i] != ' ' and input[i] != '\t') : (i += 1) {}
    pos.* = i;
    return input[start..i];
}

/// Skip whitespace characters (space and tab) starting from `pos.*`.
pub fn skipWhitespace(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t')) : (pos.* += 1) {}
}

/// Check if the character at `pos` is a flag of the form `-X` (dash + non-space).
pub fn isFlag(input: []const u8, pos: usize) bool {
    return pos + 1 < input.len and input[pos] == '-' and input[pos + 1] != ' ';
}

/// Check if the character at `pos` matches a specific single-char flag `-c`.
pub fn matchFlag(input: []const u8, pos: usize, flag_char: u8) bool {
    return pos + 1 < input.len and input[pos] == '-' and input[pos + 1] == flag_char;
}
