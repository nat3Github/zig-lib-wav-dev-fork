const std = @import("std");

pub fn bufferedWriteStream(comptime buffer_size: usize, WriteSeekableStream: anytype) BufferedReadStream(buffer_size, @TypeOf(WriteSeekableStream.writer()), @TypeOf(WriteSeekableStream.seekableStream())) {
    const BuffStream = BufferedWriteStream(buffer_size, @TypeOf(WriteSeekableStream.writer()), @TypeOf(WriteSeekableStream.seekableStream()));
    return BuffStream.init(WriteSeekableStream.writer(), WriteSeekableStream.seekableStream());
}

pub fn BufferedWriteStream(buffer_size: usize, WriterType: type, SeekableStreamType: type) type {
    return struct {
        const BuffWriterT = std.io.BufferedWriter(buffer_size, WriterType);
        const SeekErrorType = error{SeekError};
        const SeekableStreamT =
            std.io.SeekableStream(
                *@This(),
                SeekErrorType,
                SeekErrorType,
                seekTo,
                seekBy,
                getPos,
                getEndPos,
            );
        buffered: BuffWriterT,
        seekable: std.fs.File.SeekableStream,
        write_pos: u64 = 0,
        pub fn init(wrt: WriterType, seekable_stream: SeekableStreamType) @This() {
            return @This(){
                .buffered = .{ .unbuffered_writer = wrt },
                .seekable = seekable_stream,
            };
        }
        pub fn finish(self: *@This()) !void {
            try self.buffered.flush();
        }
        pub fn writer(self: *@This()) std.io.AnyWriter {
            return std.io.AnyWriter{
                .context = @ptrCast(self),
                .writeFn = &@This().write,
            };
        }
        pub fn write(userData: *const anyopaque, buffer: []const u8) anyerror!usize {
            const self: *@This() = @constCast(@alignCast(@ptrCast(userData)));
            const res = try self.buffered.writer().write(buffer);
            self.write_pos += res;
            return res;
        }
        pub fn seekableStream(self: *@This()) SeekableStreamT {
            return SeekableStreamT{
                .context = self,
            };
        }
        pub fn seekTo(self: *@This(), pos: u64) SeekErrorType!void {
            self.buffered.flush() catch return error.SeekError;
            self.seekable.seekTo(pos) catch return error.SeekError;
            self.write_pos = pos;
        }
        pub fn seekBy(self: *@This(), amt: i64) SeekErrorType!void {
            const new_pos: i128 = @as(i128, @intCast(amt)) + @as(i128, @intCast(self.write_pos));
            return self.seekTo(@intCast(new_pos));
        }
        pub fn getEndPos(self: *@This()) SeekErrorType!u64 {
            return self.seekable.getEndPos() catch error.SeekError;
        }
        pub fn getPos(self: *@This()) SeekErrorType!u64 {
            return self.seekable.getPos() catch error.SeekError;
        }
    };
}

pub fn bufferedReadStream(comptime buffer_size: usize, ReadSeekableStream: anytype) BufferedReadStream(buffer_size, @TypeOf(ReadSeekableStream.reader()), @TypeOf(ReadSeekableStream.seekableStream())) {
    const BuffStream = BufferedReadStream(buffer_size, @TypeOf(ReadSeekableStream.reader()), @TypeOf(ReadSeekableStream.seekableStream()));
    return BuffStream.init(ReadSeekableStream.reader(), ReadSeekableStream.writer());
}

pub fn BufferedReadStream(buffer_size: usize, ReaderType: type, SeekableStreamType: type) type {
    return struct {
        const BuffReaderT = std.io.BufferedReader(buffer_size, ReaderType);
        const SeekErrorType = error{SeekError};
        const SeekableStreamT =
            std.io.SeekableStream(
                *@This(),
                SeekErrorType,
                SeekErrorType,
                seekTo,
                seekBy,
                getPos,
                getEndPos,
            );
        buffered: BuffReaderT,
        seekable: std.fs.File.SeekableStream,
        read_pos: u64 = 0,
        pub fn init(rd: ReaderType, seekable_stream: SeekableStreamType) @This() {
            return @This(){
                .buffered = .{ .unbuffered_reader = rd },
                .seekable = seekable_stream,
            };
        }
        pub fn reader(self: *@This()) std.io.AnyReader {
            return std.io.AnyReader{
                .context = @ptrCast(self),
                .readFn = &@This().read,
            };
        }
        pub fn read(userData: *const anyopaque, buffer: []u8) anyerror!usize {
            const self: *@This() = @constCast(@alignCast(@ptrCast(userData)));
            const res = try self.buffered.reader().read(buffer);
            self.read_pos += res;
            return res;
        }
        pub fn seekableStream(self: *@This()) SeekableStreamT {
            return SeekableStreamT{
                .context = self,
            };
        }
        pub fn seekTo(self: *@This(), pos: u64) SeekErrorType!void {
            self.seekable.seekTo(pos) catch return error.SeekError;
            self.read_pos = pos;
            self.buffered.start = 0;
            self.buffered.end = 0;
        }
        pub fn seekBy(self: *@This(), amt: i64) SeekErrorType!void {
            const new_pos: i128 = @as(i128, @intCast(amt)) + @as(i128, @intCast(self.read_pos));
            return self.seekTo(@intCast(new_pos));
        }
        pub fn getEndPos(self: *@This()) SeekErrorType!u64 {
            return self.seekable.getEndPos() catch error.SeekError;
        }
        pub fn getPos(self: *@This()) SeekErrorType!u64 {
            return self.seekable.getPos() catch error.SeekError;
        }
    };
}
