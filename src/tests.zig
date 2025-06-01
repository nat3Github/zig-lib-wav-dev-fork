const std = @import("std");
const builtin = @import("builtin");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;
const wav = @import("wav.zig");
const sample = wav.sample;
const encoder = wav.encoder;
const decoder = wav.decoder;
const convert = wav.sample.convert;

fn expectApproxEqualInt(expected: anytype, actual: @TypeOf(expected), tolerance: @TypeOf(expected)) !void {
    const abs = if (expected > actual) expected - actual else actual - expected;
    try std.testing.expect(abs <= tolerance);
}

////// ----------- sample conversion

fn testDownwardsConversions(
    float32: f32,
    uint8: u8,
    int16: i16,
    int24: i24,
    int32: i32,
) !void {
    try expectEqual(uint8, convert(u8, uint8));
    try expectEqual(uint8, convert(u8, int16));
    try expectEqual(uint8, convert(u8, int24));
    try expectEqual(uint8, convert(u8, int32));

    try expectEqual(int16, convert(i16, int16));
    try expectEqual(int16, convert(i16, int24));
    try expectEqual(int16, convert(i16, int32));

    try expectEqual(int24, convert(i24, int24));
    try expectEqual(int24, convert(i24, int32));

    try expectEqual(int32, convert(i32, int32));

    const tolerance: f32 = 0.00001;
    try expectApproxEqAbs(float32, convert(f32, uint8), tolerance * 512.0);
    try expectApproxEqAbs(float32, convert(f32, int16), tolerance * 4.0);
    try expectApproxEqAbs(float32, convert(f32, int24), tolerance * 2.0);
    try expectApproxEqAbs(float32, convert(f32, int32), tolerance);

    try expectApproxEqualInt(uint8, convert(u8, float32), 1);
    try expectApproxEqualInt(int16, convert(i16, float32), 2);
    try expectApproxEqualInt(int24, convert(i24, float32), 2);
    try expectApproxEqualInt(int32, convert(i32, float32), 200);
}

test "sanity test" {
    try testDownwardsConversions(0.0, 0x80, 0, 0, 0);
    try testDownwardsConversions(0.0122069996, 0x81, 0x18F, 0x18FFF, 0x18FFFBB);
    try testDownwardsConversions(0.00274699973, 0x80, 0x5A, 0x5A03, 0x5A0381);
    try testDownwardsConversions(-0.441255282, 0x47, -14460, -3701517, -947588300);

    var uint8: u8 = 0x81;
    try expectEqual(@as(i16, 0x100), convert(i16, uint8));
    try expectEqual(@as(i24, 0x10000), convert(i24, uint8));
    try expectEqual(@as(i32, 0x1000000), convert(i32, uint8));
    var int16: i16 = 0x18F;
    try expectEqual(@as(i24, 0x18F00), convert(i24, int16));
    try expectEqual(@as(i32, 0x18F0000), convert(i32, int16));
    var int24: i24 = 0x18FFF;
    try expectEqual(@as(i32, 0x18FFF00), convert(i32, int24));

    uint8 = 0x80;
    try expectEqual(@as(i16, 0), convert(i16, uint8));
    try expectEqual(@as(i24, 0), convert(i24, uint8));
    try expectEqual(@as(i32, 0), convert(i32, uint8));
    int16 = 0x5A;
    try expectEqual(@as(i24, 0x5A00), convert(i24, int16));
    try expectEqual(@as(i32, 0x5A0000), convert(i32, int16));
    int24 = 0x5A03;
    try expectEqual(@as(i32, 0x5A0300), convert(i32, int24));

    uint8 = 0x47;
    try expectEqual(@as(i16, -14592), convert(i16, uint8));
    try expectEqual(@as(i24, -3735552), convert(i24, uint8));
    try expectEqual(@as(i32, -956301312), convert(i32, uint8));
    int16 = -14460;
    try expectEqual(@as(i24, -3701760), convert(i24, int16));
    try expectEqual(@as(i32, -947650560), convert(i32, int16));
    int24 = -3701517;
    try expectEqual(@as(i32, -947588352), convert(i32, int24));
}

////// ----------- decoder / encoder

test "pcm(bits=8) sample_rate=22050 channels=1" {
    var file = try std.fs.cwd().openFile("test/pcm8_22050_mono.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 22050), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(@as(usize, 8), wav_decoder.bits());
    try expectEqual(@as(usize, 104676), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf, true) * wav_decoder.channels() < buf.len) {
            break;
        }
    }
}

test "pcm(bits=16) sample_rate=44100 channels=2" {
    const data_len: usize = 312542;

    var file = try std.fs.cwd().openFile("test/pcm16_44100_stereo.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 44100), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, data_len), wav_decoder.remaining());

    const buf = try std.testing.allocator.alloc(i16, data_len);
    defer std.testing.allocator.free(buf);

    try expectEqual(data_len / wav_decoder.channels(), try wav_decoder.read(i16, buf, true));
    try expectEqual(@as(usize, 0), try wav_decoder.read(i16, buf, true));
    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

test "pcm(bits=24) sample_rate=48000 channels=1" {
    var file = try std.fs.cwd().openFile("test/pcm24_48000_mono.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 48000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(@as(usize, 24), wav_decoder.bits());
    try expectEqual(@as(usize, 508800), wav_decoder.remaining());

    var buf: [1]f32 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try expectEqual(@as(usize, 1), try wav_decoder.read(f32, &buf, true));
    }
    try expectEqual(@as(usize, 507800), wav_decoder.remaining());

    while (true) {
        const samples_read = try wav_decoder.read(f32, &buf, true);
        if (samples_read == 0) {
            break;
        }
        try expectEqual(@as(usize, 1), samples_read);
    }
}

test "pcm(bits=24) sample_rate=44100 channels=2" {
    var file = try std.fs.cwd().openFile("test/pcm24_44100_stereo.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 44100), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 24), wav_decoder.bits());
    try expectEqual(@as(usize, 157952), wav_decoder.remaining());

    var buf: [2]f32 = undefined;
    while (true) {
        const samples_read = try wav_decoder.read(f32, &buf, true);
        if (samples_read == 0) {
            break;
        }
        try expectEqual(@as(usize, 1), samples_read);
    }
}

test "ieee_float(bits=32) sample_rate=48000 channels=2" {
    var file = try std.fs.cwd().openFile("test/float32_48000_stereo.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 48000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 32), wav_decoder.bits());
    try expectEqual(@as(usize, 592342), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf, true) * wav_decoder.channels() < buf.len) {
            break;
        }
    }
}

test "ieee_float(bits=32) sample_rate=96000 channels=2" {
    var file = try std.fs.cwd().openFile("test/float32_96000_stereo.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    try expectEqual(@as(usize, 96000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 32), wav_decoder.bits());
    try expectEqual(@as(usize, 67744), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf, true) * wav_decoder.channels() * wav_decoder.channels() < buf.len) {
            break;
        }
    }

    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

test "error truncated" {
    var file = try std.fs.cwd().openFile("test/error-trunc.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);
    var buf: [3000]f32 = undefined;
    try expectError(error.EndOfStream, wav_decoder.read(f32, &buf, true));
}

test "error data_size too big" {
    var file = try std.fs.cwd().openFile("test/error-data_size1.wav", .{});
    defer file.close();

    var wav_decoder = try decoder(file);

    var buf: [1]u8 = undefined;
    var i: usize = 0;
    while (i < 44100) : (i += 1) {
        try expectEqual(@as(usize, 1), try wav_decoder.read(u8, &buf, true));
    }
    try expectError(error.EndOfStream, wav_decoder.read(u8, &buf, true));
}

fn testEncodeDecode(comptime T: type, comptime sample_rate: usize) !void {
    const twopi = std.math.pi * 2.0;
    const freq = 440.0;
    const secs = 3;
    const increment = freq / @as(f32, @floatFromInt(sample_rate)) * twopi;

    const buf = try std.testing.allocator.alloc(u8, sample_rate * @bitSizeOf(T) / 8 * (secs + 1));
    defer std.testing.allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    var wav_encoder = try encoder(T, &stream, sample_rate, 1);

    var phase: f32 = 0.0;
    var i: usize = 0;
    while (i < secs * sample_rate) : (i += 1) {
        try wav_encoder.write(f32, &.{std.math.sin(phase)}, true);
        phase += increment;
    }

    try wav_encoder.finalize();
    try stream.seekTo(0);

    var wav_decoder = try decoder(&stream);
    try expectEqual(sample_rate, wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(secs * sample_rate, wav_decoder.remaining());

    phase = 0.0;
    i = 0;
    while (i < secs * sample_rate) : (i += 1) {
        var value: [1]f32 = undefined;
        try expectEqual(try wav_decoder.read(f32, &value, true), 1);
        try std.testing.expectApproxEqAbs(std.math.sin(phase), value[0], 0.0001);
        phase += increment;
    }

    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

test "encode-decode sine" {
    try testEncodeDecode(f32, 44100);
    try testEncodeDecode(i24, 48000);
    try testEncodeDecode(i16, 44100);
}
