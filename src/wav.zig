const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const buffered_io = @import("buffered_io.zig");

/// helper for buffered writing / reading
pub const bufferedReadStream = buffered_io.bufferedReadStream;
pub const bufferedWriteStream = buffered_io.bufferedWriteStream;
pub const BufferedReadStream = buffered_io.BufferedReadStream;
pub const BufferedWriteStream = buffered_io.BufferedWriteStream;

pub const tests = @import("tests.zig");
test "test" {
    _ = .{tests};
}

fn readFloat(comptime T: type, reader: anytype) !T {
    var f: T = undefined;
    try reader.readNoEof(std.mem.asBytes(&f));
    return f;
}

const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
    extensible = 0xFFFE,
    _,
};

const FormatChunk = packed struct {
    code: FormatCode,
    channels: u16,
    sample_rate: u32,
    bytes_per_second: u32,
    block_align: u16,
    bits: u16,

    fn parse(reader: anytype, chunk_size: usize) !FormatChunk {
        if (chunk_size < @sizeOf(FormatChunk)) {
            return error.InvalidSize;
        }
        const fmt = try reader.readStruct(FormatChunk);
        if (chunk_size > @sizeOf(FormatChunk)) {
            try reader.skipBytes(chunk_size - @sizeOf(FormatChunk), .{});
        }
        return fmt;
    }

    fn validate(self: FormatChunk) !void {
        switch (self.code) {
            .pcm, .ieee_float, .extensible => {},
            else => {
                std.log.debug("unsupported format code {x}", .{self.code});
                return error.Unsupported;
            },
        }
        if (self.channels == 0) {
            return error.InvalidValue;
        }
        switch (self.bits) {
            0 => return error.InvalidValue,
            8, 16, 24, 32 => {},
            else => {
                std.log.debug("unsupported bits per sample {}", .{self.bits});
                return error.Unsupported;
            },
        }
        if (self.bytes_per_second != self.bits / 8 * self.sample_rate * self.channels) {
            std.log.debug("invalid bytes_per_second", .{});
            return error.InvalidValue;
        }
    }
};

/// Loads wav file from stream. Read and convert samples to a desired type.
pub fn Decoder(comptime InnerReaderType: type, comptime SeekAbleStreamType: type) type {
    return struct {
        const Self = @This();

        const ReaderType = std.io.CountingReader(InnerReaderType);
        const Error = ReaderType.Error || error{ EndOfStream, InvalidFileType, InvalidArgument, InvalidSize, InvalidValue, Overflow, Unsupported };

        counting_reader: ReaderType,
        seekable_stream: SeekAbleStreamType,
        fmt: FormatChunk,
        data_start: usize,
        data_size: usize,

        pub fn sampleRate(self: *const Self) usize {
            return self.fmt.sample_rate;
        }

        pub fn channels(self: *const Self) usize {
            return self.fmt.channels;
        }

        pub fn bits(self: *const Self) usize {
            return self.fmt.bits;
        }
        /// Number of samples remaining.
        pub fn remaining(self: *const Self) usize {
            const sample_size = self.bits() / 8;
            const bytes_remaining = self.data_size + self.data_start - self.counting_reader.bytes_read;

            std.debug.assert(bytes_remaining % sample_size == 0);
            return bytes_remaining / sample_size;
        }
        /// Parse and validate headers/metadata. Prepare to read samples.
        fn init(readable: InnerReaderType, seekable: SeekAbleStreamType) Error!Self {
            comptime std.debug.assert(builtin.target.cpu.arch.endian() == .little);
            try seekable.seekTo(0);

            var counting_reader = ReaderType{ .child_reader = readable };
            var reader = counting_reader.reader();

            var chunk_id = try reader.readBytesNoEof(4);
            if (!std.mem.eql(u8, "RIFF", &chunk_id)) {
                std.log.debug("not a RIFF file", .{});
                return error.InvalidFileType;
            }
            const total_size = try std.math.add(u32, try reader.readInt(u32, .little), 8);

            chunk_id = try reader.readBytesNoEof(4);
            if (!std.mem.eql(u8, "WAVE", &chunk_id)) {
                std.log.debug("not a WAVE file", .{});
                return error.InvalidFileType;
            }
            // Iterate through chunks. Require fmt and data.
            var fmt: ?FormatChunk = null;
            var data_size: usize = 0; // Bytes in data chunk.
            var chunk_size: usize = 0;
            while (true) {
                chunk_id = try reader.readBytesNoEof(4);
                chunk_size = try reader.readInt(u32, .little);

                if (std.mem.eql(u8, "fmt ", &chunk_id)) {
                    fmt = try FormatChunk.parse(reader, chunk_size);
                    try fmt.?.validate();

                    // TODO Support 32-bit aligned i24 blocks.
                    const bytes_per_sample = fmt.?.block_align / fmt.?.channels;
                    if (bytes_per_sample * 8 != fmt.?.bits) {
                        return error.Unsupported;
                    }
                } else if (std.mem.eql(u8, "data", &chunk_id)) {
                    // Expect data chunk to be last.
                    data_size = chunk_size;
                    break;
                } else {
                    std.log.info("skipping unrecognized chunk {s}", .{chunk_id});
                    try reader.skipBytes(chunk_size, .{});
                }
            }

            if (fmt == null) {
                std.log.debug("no fmt chunk present", .{});
                return error.InvalidFileType;
            }

            std.log.info(
                "{}(bits={}) sample_rate={} channels={} size=0x{x}",
                .{ fmt.?.code, fmt.?.bits, fmt.?.sample_rate, fmt.?.channels, total_size },
            );

            const data_start = counting_reader.bytes_read;
            if (data_start + data_size > total_size) {
                return error.InvalidSize;
            }
            if (data_size % (fmt.?.channels * fmt.?.bits / 8) != 0) {
                return error.InvalidSize;
            }

            return .{
                .counting_reader = counting_reader,
                .fmt = fmt.?,
                .data_start = data_start,
                .data_size = data_size,
                .seekable_stream = seekable,
            };
        }

        /// Read samples from stream and converts to type T. Supports PCM encoded ints and IEEE float.
        /// returns frames read, rest of buffer is nulled
        pub fn read(self: *Self, comptime T: type, buf: []T, comptime interleaved: bool) !usize {
            assert(buf.len % self.channels() == 0);
            return switch (self.fmt.code) {
                .pcm => switch (self.fmt.bits) {
                    8 => self.readInternal(u8, T, buf, interleaved),
                    16 => self.readInternal(i16, T, buf, interleaved),
                    24 => self.readInternal(i24, T, buf, interleaved),
                    32 => self.readInternal(i32, T, buf, interleaved),
                    else => unreachable,
                },
                .ieee_float => self.readInternal(f32, T, buf, interleaved),
                else => unreachable,
            };
        }
        fn readInternal(self: *Self, comptime S: type, comptime T: type, buf: []T, comptime interleaved: bool) !usize {
            assert(buf.len % self.channels() == 0);
            var reader = self.counting_reader.reader();
            const limit = @min(buf.len, self.remaining());
            const frames = limit / self.channels();
            const total_frames = buf.len / self.channels();
            for (0..frames) |frame| {
                for (0..self.channels()) |channel| {
                    const index = if (interleaved)
                        sample.interleaved_index(self.channels(), frame, channel)
                    else
                        sample.planar_index(total_frames, frame, channel);
                    const s = sample.convert(T, switch (@typeInfo(S)) {
                        .float => try readFloat(S, reader),
                        .int => try reader.readInt(S, .little),
                        else => unreachable,
                    });
                    buf[index] = s;
                }
            }
            for (frames..total_frames) |frame| {
                for (0..self.channels()) |channel| {
                    const index = if (interleaved)
                        sample.interleaved_index(self.channels(), frame, channel)
                    else
                        sample.planar_index(total_frames, frame, channel);
                    buf[index] = sample.convert(T, @as(f32, 0.0));
                }
            }
            return frames;
        }
        pub fn totalFrames(self: *const Self) usize {
            const bytes_per_frame = (self.fmt.bits / 8) * self.fmt.channels;
            return self.data_size / bytes_per_frame;
        }
        pub fn currentFrame(self: *const Self) usize {
            const bytes_read_in_data_chunk = self.counting_reader.bytes_read - self.data_start;
            const bytes_per_frame = (self.fmt.bits / 8) * self.fmt.channels;
            return bytes_read_in_data_chunk / bytes_per_frame;
        }

        pub fn seekToFrame(self: *Self, frame: usize) !usize {
            const frame_number = @min(frame, self.totalFrames());
            const bytes_per_frame = (self.fmt.bits / 8) * self.fmt.channels;
            const target_data_offset = frame_number * bytes_per_frame;
            const absolute_target_offset = @as(u64, self.data_start + target_data_offset);
            try self.seekable_stream.seekTo(absolute_target_offset);
            self.counting_reader.bytes_read = absolute_target_offset;
            return self.currentFrame();
        }
    };
}

pub fn decoder(ReadSeekableStream: anytype) !Decoder(@TypeOf(ReadSeekableStream.reader()), @TypeOf(ReadSeekableStream.seekableStream())) {
    const Dec = Decoder(@TypeOf(ReadSeekableStream.reader()), @TypeOf(ReadSeekableStream.seekableStream()));
    return Dec.init(ReadSeekableStream.reader(), ReadSeekableStream.seekableStream());
}

pub const sample = struct {
    pub fn interleaved_index(channels_total: usize, frame: usize, channel: usize) usize {
        return frame * channels_total + channel;
    }

    pub fn planar_index(frames_total: usize, frame: usize, channel: usize) usize {
        return channel * frames_total + frame;
    }
    /// Converts between PCM and float sample types.
    pub fn convert(comptime T: type, value: anytype) T {
        const S = @TypeOf(value);
        if (S == T) {
            return value;
        }

        // PCM uses unsigned 8-bit ints instead of signed. Special case.
        if (S == u8) {
            const new_value: i8 = @bitCast(value -% 128);
            return convert(T, new_value);
        } else if (T == u8) {
            const rval: u8 = @bitCast(convert(i8, value));
            return rval +% 128;
        }

        return switch (S) {
            i8, i16, i24, i32 => switch (T) {
                i8, i16, i24, i32 => convertSignedInt(T, value),
                f32 => convertIntToFloat(T, value),
                else => unreachable,
            },
            f32 => switch (T) {
                i8, i16, i24, i32 => convertFloatToInt(T, value),
                f32 => value,
                else => unreachable,
            },
            else => unreachable,
        };
    }

    fn convertFloatToInt(comptime T: type, value: anytype) T {
        const S = @TypeOf(value);

        const min: S = comptime @floatFromInt(std.math.minInt(T));
        const max: S = comptime @floatFromInt(std.math.maxInt(T));

        // Need lossyCast instead of @floatToInt because float representation of max/min T may be
        // out of range.
        return std.math.lossyCast(T, std.math.clamp(@round(value * (1.0 + max)), min, max));
    }

    fn convertIntToFloat(comptime T: type, value: anytype) T {
        const S = @TypeOf(value);
        const max_value: T = @floatFromInt(std.math.maxInt(S));
        const value_as_float: T = @floatFromInt(value);
        return 1.0 / (1.0 + max_value) * value_as_float;
    }

    fn convertSignedInt(comptime T: type, value: anytype) T {
        const S = @TypeOf(value);

        const src_bits = @typeInfo(S).int.bits;
        const dst_bits = @typeInfo(T).int.bits;

        if (src_bits < dst_bits) {
            const shift = dst_bits - src_bits;
            return @as(T, value) << shift;
        } else if (src_bits > dst_bits) {
            const shift = src_bits - dst_bits;
            return @intCast(value >> shift);
        }

        comptime std.debug.assert(S == T);
        return value;
    }
};

/// Encode audio samples to wav file. Must call `finalize()` once complete. Samples will be encoded
/// with type T (PCM int or IEEE float).
pub fn Encoder(
    comptime T: type,
    comptime WriterType: type,
    comptime SeekableType: type,
) type {
    return struct {
        const Self = @This();
        writer: WriterType,
        seekable: SeekableType,

        fmt: FormatChunk,
        data_size: usize = 0,

        pub fn init(
            writer: WriterType,
            seekable: SeekableType,
            sample_rate: usize,
            channel_num: usize,
        ) !Self {
            const bits = switch (T) {
                u8 => 8,
                i16 => 16,
                i24 => 24,
                f32 => 32,
                else => unreachable,
            };

            if (sample_rate == 0 or sample_rate > std.math.maxInt(u32)) {
                std.log.debug("invalid sample_rate {}", .{sample_rate});
                return error.InvalidArgument;
            }
            if (channel_num == 0 or channel_num > std.math.maxInt(u16)) {
                std.log.debug("invalid channels {}", .{channel_num});
                return error.InvalidArgument;
            }
            const bytes_per_second = sample_rate * channel_num * bits / 8;
            if (bytes_per_second > std.math.maxInt(u32)) {
                std.log.debug("bytes_per_second, {}, too large", .{bytes_per_second});
                return error.InvalidArgument;
            }
            try seekable.seekTo(0);
            var self = Self{
                .writer = writer,
                .seekable = seekable,
                .fmt = .{
                    .code = switch (T) {
                        u8, i16, i24 => .pcm,
                        f32 => .ieee_float,
                        else => unreachable,
                    },
                    .channels = @intCast(channel_num),
                    .sample_rate = @intCast(sample_rate),
                    .bytes_per_second = @intCast(bytes_per_second),
                    .block_align = @intCast(channel_num * bits / 8),
                    .bits = @intCast(bits),
                },
            };

            try self.writeHeader();
            return self;
        }

        pub fn channels(self: *const Self) usize {
            return self.fmt.channels;
        }
        pub fn writeEx(self: *Self, comptime S: type, buf: []const S, frame_num: usize, comptime interleaved: bool) !void {
            assert(buf.len % self.channels() == 0);
            const total_frames = buf.len / self.channels();
            const frames = @min(total_frames, frame_num);
            for (0..frames) |frame| {
                for (0..self.channels()) |channel| {
                    const index = if (interleaved)
                        sample.interleaved_index(self.channels(), frame, channel)
                    else
                        sample.planar_index(total_frames, frame, channel);
                    const x = buf[index];
                    switch (T) {
                        u8, i16, i24 => {
                            try self.writer.writeInt(T, sample.convert(T, x), .little);
                            self.data_size += @bitSizeOf(T) / 8;
                        },
                        f32 => {
                            const f: f32 = sample.convert(f32, x);
                            try self.writer.writeAll(std.mem.asBytes(&f));
                            self.data_size += @bitSizeOf(T) / 8;
                        },
                        else => unreachable,
                    }
                }
            }
        }

        /// Write samples of type S to stream after converting to type T. Supports PCM encoded ints and
        /// IEEE float. Multi-channel samples must be interleaved: samples for time `t` for all channels
        /// are written to `t * channels`.
        /// buf.len must be multiple of channels
        pub fn write(self: *Self, comptime S: type, buf: []const S, comptime interleaved: bool) !void {
            assert(buf.len % self.channels() == 0);
            try self.writeEx(S, buf, buf.len / self.channels(), interleaved);
        }

        fn writeHeader(self: *Self) !void {
            // Size of RIFF header + fmt id/size + fmt chunk + data id/size.
            const header_size: usize = 12 + 8 + @sizeOf(@TypeOf(self.fmt)) + 8;

            if (header_size + self.data_size > std.math.maxInt(u32)) {
                return error.Overflow;
            }

            try self.writer.writeAll("RIFF");
            try self.writer.writeInt(u32, @intCast(header_size + self.data_size), .little); // Overwritten by finalize().
            try self.writer.writeAll("WAVE");

            try self.writer.writeAll("fmt ");
            try self.writer.writeInt(u32, @sizeOf(@TypeOf(self.fmt)), .little);
            try self.writer.writeStruct(self.fmt);

            try self.writer.writeAll("data");
            try self.writer.writeInt(u32, @intCast(self.data_size), .little);
        }
        /// Must be called once writing is complete. Writes total size to file header.
        pub fn finalize(self: *Self) !void {
            try self.seekable.seekTo(0);
            try self.writeHeader();
        }
    };
}

pub fn encoder(
    comptime T: type,
    WriteSeekableStream: anytype,
    sample_rate: usize,
    channels: usize,
) !Encoder(T, @TypeOf(WriteSeekableStream.writer()), @TypeOf(WriteSeekableStream.seekableStream())) {
    const Enc = Encoder(T, @TypeOf(WriteSeekableStream.writer()), @TypeOf(WriteSeekableStream.seekableStream()));
    return Enc.init(WriteSeekableStream.writer(), WriteSeekableStream.seekableStream(), sample_rate, channels);
}
