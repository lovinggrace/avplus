import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Decodes an audio track with FFmpeg (bundled with MPVKit) for formats AVAssetReader cannot read,
/// e.g. Opus or Vorbis in Matroska/WebM, AC-3 in AVI, FLAC in Ogg.
final class FFmpegAudioDecoder: AudioChunkDecoder, @unchecked Sendable {
    private(set) var duration: TimeInterval?
    /// Whether only the front centre channel of a surround track is decoded.
    private(set) var usesCenterChannel = false

    // Defaults let `init` release partially opened FFmpeg state when it throws.
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    /// Container start time; players show `pts - startTime` as the current time.
    private var startTime: TimeInterval = 0
    private var inputSampleRate: Int32 = 0
    private let sampleRate: Double
    private var nextFrameTime: TimeInterval?
    private var didReachEndOfFile = false
    private var didFlushDecoder = false

    // Function-like macros are not imported into Swift.
    private static let errorEOF: Int32 = -541_478_725 // AVERROR_EOF, FFERRTAG('E','O','F',' ')
    private static let errorAgain: Int32 = -EAGAIN // AVERROR(EAGAIN)
    private static let noTimestamp = Int64.min // AV_NOPTS_VALUE
    /// Timestamps this close to the end of the previous frame count as continuous audio.
    private static let timestampTolerance: TimeInterval = 0.01

    /// - Parameter prefersCenterChannel: Take only the front centre channel of surround audio,
    ///   where film and TV mixes put the dialogue, instead of a downmix that includes music.
    /// - Parameter headers: Request headers for media read over HTTP. FFmpeg passes them on to the
    ///   segment and key requests of an HLS stream.
    init(url: URL, headers: HTTPHeaders = HTTPHeaders([:]), trackIndex: Int?, sampleRate: Double, prefersCenterChannel: Bool = false) throws {
        self.sampleRate = sampleRate
        let path = url.isFileURL ? url.path : url.absoluteString
        if !url.isFileURL { avformat_network_init() }

        var options: OpaquePointer?
        // Match mpv's HLS demuxer: CDNs may serve MPEG-TS under names such as
        // .ts.jpg. Probe the content instead of requiring its extension to
        // match the detected format. Keep FFmpeg's protocol and local-file
        // extension allowlists intact.
        av_dict_set(&options, "extension_picky", "0", 0)
        if let userAgent = headers.userAgent { av_dict_set(&options, "user_agent", userAgent, 0) }
        if let referer = headers.referer { av_dict_set(&options, "referer", referer, 0) }
        let fields = headers.others.map { "\($0.name): \($0.value)\r\n" }.joined()
        if !fields.isEmpty { av_dict_set(&options, "headers", fields, 0) }
        defer { av_dict_free(&options) }
        try Self.check(avformat_open_input(&formatContext, path, nil, &options), "open the media")
        guard let formatContext else { throw SubtitleGenerationError.decodingFailed("FFmpeg could not open the media") }
        do {
            try Self.check(avformat_find_stream_info(formatContext, nil), "read stream info")

            let streams = (0..<Int(formatContext.pointee.nb_streams)).compactMap { formatContext.pointee.streams[$0] }
            let audioStreams = streams.filter { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO }
            let index = trackIndex ?? 0
            guard audioStreams.indices.contains(index) else { throw SubtitleGenerationError.noAudioTrack }
            let stream = audioStreams[index]
            for other in streams where other != stream {
                other.pointee.discard = AVDISCARD_ALL
            }
            streamIndex = stream.pointee.index
            timeBase = stream.pointee.time_base

            let parameters = stream.pointee.codecpar!
            guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
                throw SubtitleGenerationError.decodingFailed("No FFmpeg decoder for this audio codec")
            }
            codecContext = avcodec_alloc_context3(codec)
            guard let codecContext else { throw SubtitleGenerationError.decodingFailed("Out of memory") }
            try Self.check(avcodec_parameters_to_context(codecContext, parameters), "configure the decoder")
            codecContext.pointee.pkt_timebase = stream.pointee.time_base
            try Self.check(avcodec_open2(codecContext, codec, nil), "open the decoder")
            inputSampleRate = codecContext.pointee.sample_rate

            var outputLayout = AVChannelLayout()
            av_channel_layout_default(&outputLayout, 1)
            try Self.check(swr_alloc_set_opts2(
                &resampler,
                &outputLayout, AV_SAMPLE_FMT_FLT, Int32(sampleRate),
                &codecContext.pointee.ch_layout, codecContext.pointee.sample_fmt, codecContext.pointee.sample_rate,
                0, nil
            ), "configure the resampler")
            let inputChannels = codecContext.pointee.ch_layout.nb_channels
            let center = av_channel_layout_index_from_channel(&codecContext.pointee.ch_layout, AV_CHAN_FRONT_CENTER)
            if prefersCenterChannel, inputChannels > 2, center >= 0 {
                var matrix = [Double](repeating: 0, count: Int(inputChannels))
                matrix[Int(center)] = 1
                try Self.check(swr_set_matrix(resampler, matrix, inputChannels), "select the centre channel")
                usesCenterChannel = true
            }
            try Self.check(swr_init(resampler), "start the resampler")

            packet = av_packet_alloc()
            frame = av_frame_alloc()

            let containerStart = formatContext.pointee.start_time
            startTime = containerStart == Self.noTimestamp ? 0 : Double(containerStart) / 1_000_000
            let containerDuration = formatContext.pointee.duration
            duration = containerDuration > 0 ? Double(containerDuration) / 1_000_000 : nil
        } catch {
            release()
            throw error
        }
    }

    func nextChunk() throws -> DecodedAudioChunk? {
        guard let codecContext, let formatContext, let packet, let frame else { return nil }
        while true {
            let received = avcodec_receive_frame(codecContext, frame)
            if received == 0 {
                defer { av_frame_unref(frame) }
                if let chunk = convert(frame) { return chunk }
                continue
            }
            if received == Self.errorEOF { return nil }
            guard received == Self.errorAgain else { throw Self.error(received, "decode audio") }

            // The decoder needs more input.
            if didReachEndOfFile {
                guard !didFlushDecoder else { return nil }
                didFlushDecoder = true
                avcodec_send_packet(codecContext, nil)
                continue
            }
            if av_read_frame(formatContext, packet) < 0 {
                didReachEndOfFile = true
                continue
            }
            if packet.pointee.stream_index == streamIndex {
                // Corrupt packets are skipped rather than ending the transcription.
                _ = avcodec_send_packet(codecContext, packet)
            }
            av_packet_unref(packet)
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedAudioChunk? {
        let inputCount = frame.pointee.nb_samples
        guard inputCount > 0, let resampler else { return nil }

        let timestamp = frame.pointee.best_effort_timestamp
        var frameTime = timestamp == Self.noTimestamp
            ? (nextFrameTime ?? 0)
            : Double(timestamp) * av_q2d(timeBase) - startTime
        // Containers with coarse timestamps (Matroska counts milliseconds) round each frame's start,
        // so a 21.33 ms AAC frame appears to start up to a millisecond early or late. Taken
        // literally that drops or shifts samples at every frame; continuous audio follows on exactly.
        if let nextFrameTime, abs(frameTime - nextFrameTime) < Self.timestampTolerance { frameTime = nextFrameTime }
        nextFrameTime = frameTime + Double(inputCount) / Double(inputSampleRate)
        // Samples still buffered in the resampler come out first, so the output starts earlier.
        let delay = Double(swr_get_delay(resampler, Int64(inputSampleRate))) / Double(inputSampleRate)

        let capacity = swr_get_out_samples(resampler, inputCount)
        guard capacity > 0 else { return nil }
        var samples = [Float](repeating: 0, count: Int(capacity))
        let input = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let converted = samples.withUnsafeMutableBytes { bytes -> Int32 in
            var output: UnsafeMutablePointer<UInt8>? = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return swr_convert(resampler, &output, capacity, input, inputCount)
        }
        guard converted > 0 else { return nil }
        samples.removeLast(samples.count - Int(converted))

        var start = frameTime - delay
        if start < 0 {
            samples.removeFirst(min(samples.count, Int((-start * sampleRate).rounded())))
            start = 0
        }
        return samples.isEmpty ? nil : DecodedAudioChunk(samples: samples, startTime: start, sampleRate: sampleRate)
    }

    private func release() {
        swr_free(&resampler)
        av_frame_free(&frame)
        av_packet_free(&packet)
        avcodec_free_context(&codecContext)
        avformat_close_input(&formatContext)
    }

    deinit {
        release()
    }

    private static func check(_ status: Int32, _ action: String) throws {
        if status < 0 { throw error(status, action) }
    }

    private static func error(_ status: Int32, _ action: String) -> SubtitleGenerationError {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(status, &buffer, buffer.count)
        let message = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .decodingFailed("FFmpeg could not \(action): \(message)")
    }
}
