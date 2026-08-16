import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import CoreMedia

/// `--test-stt-partials` の計測専用ストリーミング経路。
///
/// `--test-stt` が使う `transcribeFile` はファイル全体を1バッファで投入するため、
/// マイク録音で観測される暫定結果の遅延を再現できない。ここでは
/// `TranscriptionEngine.startStreaming` と同じ
/// 「tap → AsyncStream<AVAudioPCMBuffer> → 単一consumer → AsyncStream<AnalyzerInput> → analyzer.start」
/// を組み、実時間ペースで小さなバッファを供給する。Speech側の構成だけをフラグで
/// 差し替えられるようにし、遅延の原因仮説を1つずつ潰すために使う。
///
/// 計測専用のため `AppLog` を使わず標準出力にだけ書く。保存先へは何も残さない。
enum StreamingPartialProbe {
    struct Config: Sendable {
        var path: String = ""
        var localeIdentifier: String = "ja-JP"
        /// 実機のtap粒度（`AudioRecorder` の bufferSize 4096 フレーム / 48kHz）。
        var chunkMilliseconds: Double = 4096.0 / 48_000.0 * 1_000.0
        var feed: Feed = .realtime
        var format: FormatMode = .best
        /// ファイル末尾へ足す無音の長さ。実機のハンズフリー送信では、トリガー句を
        /// 言い終えた後もマイクは動き続ける。ストリーム終端のフラッシュに助けられない
        /// 状態でのトリガー検出遅延を測るために使う。
        var trailingSilenceMilliseconds: Double = 0
        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        var transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption> = []
        var attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange]
        var preset: String?
        var reserveLocale = false
        var prepareToAnalyze = false
        var passesBufferStartTime = false
        var usesSpeechDetector = false
        var label = "default"
    }

    enum Feed: String, Sendable {
        /// 実機と同じく、チャンク長ぶんの実時間を空けて供給する。
        case realtime
        /// 供給待ちを入れず、可能な限り速くチャンクを流し込む。
        case fast
        /// ファイル全体を1バッファで投入する（`--test-stt` 相当の対照）。
        case bulk
    }

    enum FormatMode: String, Sendable {
        /// `SpeechAnalyzer.bestAvailableAudioFormat` へ変換して供給する（実機と同じ）。
        case best
        /// 変換せず、ファイルの processingFormat のまま供給する。
        case source
        /// ファイルの processingFormat を naturalFormat として渡した best を使う。
        case natural
    }

    struct ResultRecord: Sendable {
        let elapsed: TimeInterval
        /// `TranscriptionEngine.handleResult` と同じ、確定分＋volatileの累積本文。
        let text: String
        let segment: String
        let isFinal: Bool
        let rangeStart: Double
        let rangeEnd: Double
    }

    static func parse(arguments args: [String]) -> Config? {
        guard let index = args.firstIndex(of: "--test-stt-partials"), index + 1 < args.count else {
            return nil
        }
        var config = Config()
        config.path = args[index + 1]
        if let value = value(after: "--probe-locale", in: args) { config.localeIdentifier = value }
        if let value = value(after: "--probe-chunk-ms", in: args), let ms = Double(value) { config.chunkMilliseconds = ms }
        if let value = value(after: "--probe-feed", in: args), let feed = Feed(rawValue: value) { config.feed = feed }
        if let value = value(after: "--probe-format", in: args), let mode = FormatMode(rawValue: value) { config.format = mode }
        if let value = value(after: "--probe-reporting", in: args) {
            config.reportingOptions = Set(value.split(separator: ",").compactMap(reportingOption))
        }
        if let value = value(after: "--probe-transcription", in: args) {
            config.transcriptionOptions = Set(value.split(separator: ",").compactMap(transcriptionOption))
        }
        if let value = value(after: "--probe-attributes", in: args) {
            config.attributeOptions = Set(value.split(separator: ",").compactMap(attributeOption))
        }
        if let value = value(after: "--probe-trailing-silence-ms", in: args), let ms = Double(value) {
            config.trailingSilenceMilliseconds = ms
        }
        if let value = value(after: "--probe-preset", in: args) { config.preset = value }
        if let value = value(after: "--probe-label", in: args) { config.label = value }
        config.reserveLocale = args.contains("--probe-reserve")
        config.prepareToAnalyze = args.contains("--probe-prepare")
        config.passesBufferStartTime = args.contains("--probe-start-time")
        config.usesSpeechDetector = args.contains("--probe-detector")
        return config
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func reportingOption(_ name: Substring) -> SpeechTranscriber.ReportingOption? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "volatile", "volatileResults": return .volatileResults
        case "fast", "fastResults": return .fastResults
        case "alternatives", "alternativeTranscriptions": return .alternativeTranscriptions
        default: return nil
        }
    }

    private static func transcriptionOption(_ name: Substring) -> SpeechTranscriber.TranscriptionOption? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "etiquette", "etiquetteReplacements": return .etiquetteReplacements
        default: return nil
        }
    }

    private static func attributeOption(_ name: Substring) -> SpeechTranscriber.ResultAttributeOption? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "audioTimeRange": return .audioTimeRange
        case "confidence", "transcriptionConfidence": return .transcriptionConfidence
        default: return nil
        }
    }

    private static func preset(named name: String) -> SpeechTranscriber.Preset? {
        switch name {
        case "transcription": return .transcription
        case "transcriptionWithAlternatives": return .transcriptionWithAlternatives
        case "timeIndexedTranscriptionWithAlternatives": return .timeIndexedTranscriptionWithAlternatives
        case "progressiveTranscription": return .progressiveTranscription
        case "timeIndexedProgressiveTranscription": return .timeIndexedProgressiveTranscription
        default: return nil
        }
    }

    static func run(config: Config) async -> Int32 {
        print("=== Koedex --test-stt-partials ===")
        print("label=\(config.label) file=\((config.path as NSString).lastPathComponent)")
        let url = URL(fileURLWithPath: config.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // すぐ上の行と同じくファイル名だけにする。この出力は計測レポートへ貼られる。
            print("エラー: ファイルが見つかりません: \((config.path as NSString).lastPathComponent)")
            return 1
        }

        let requestedLocale = Locale(identifier: config.localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolvedIdentifier = await TranscriptionEngine.resolvedSupportedLocaleIdentifier(
            requestedIdentifier: requestedLocale.identifier(.bcp47),
            supportedIdentifiers: supported.map { $0.identifier(.bcp47) }
        ) else {
            print("エラー: locale \(config.localeIdentifier) は未対応です")
            return 1
        }
        let locale = Locale(identifier: resolvedIdentifier)

        let transcriber: SpeechTranscriber
        if let presetName = config.preset {
            guard let preset = preset(named: presetName) else {
                print("エラー: 未知のpreset: \(presetName)")
                return 1
            }
            transcriber = SpeechTranscriber(locale: locale, preset: preset)
            print("preset=\(presetName) transcription=\(names(preset.transcriptionOptions)) reporting=\(names(preset.reportingOptions)) attributes=\(names(preset.attributeOptions))")
        } else {
            transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: config.transcriptionOptions,
                reportingOptions: config.reportingOptions,
                attributeOptions: config.attributeOptions
            )
            print("transcription=\(names(config.transcriptionOptions)) reporting=\(names(config.reportingOptions)) attributes=\(names(config.attributeOptions))")
        }

        let modules: [any SpeechModule] = config.usesSpeechDetector
            ? [SpeechDetector(), transcriber]
            : [transcriber]

        print("locale=requested:\(config.localeIdentifier) resolved:\(resolvedIdentifier)")
        let statusBefore = await AssetInventory.status(forModules: modules)
        let reservedBefore = await AssetInventory.reservedLocales
        print("assetStatus=\(statusBefore) reserved=\(reservedBefore.map { $0.identifier(.bcp47) }) maxReserved=\(AssetInventory.maximumReservedLocales)")

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                print("assetInstall=required")
                try await request.downloadAndInstall()
                print("assetInstall=done")
            } else {
                print("assetInstall=notRequired")
            }
        } catch {
            print("エラー: asset install失敗: \(AppLog.safeDescription(error))")
            return 1
        }

        if config.reserveLocale {
            do {
                let reserved = try await AssetInventory.reserve(locale: locale)
                let after = await AssetInventory.reservedLocales
                print("reserve=\(reserved) reservedAfter=\(after.map { $0.identifier(.bcp47) })")
            } catch {
                print("reserve=失敗 \(AppLog.safeDescription(error))")
            }
        }

        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: url)
        } catch {
            print("エラー: 音声ファイルを開けません: \(AppLog.safeDescription(error))")
            return 1
        }
        let sourceFormat = sourceFile.processingFormat
        let sourceDuration = Double(sourceFile.length) / sourceFormat.sampleRate

        let bestFormat: AVAudioFormat?
        switch config.format {
        case .best:
            bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        case .natural:
            bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: sourceFormat)
        case .source:
            bestFormat = nil
        }
        let compatible = await transcriber.availableCompatibleAudioFormats
        print("sourceFormat=\(describe(sourceFormat)) durationSec=\(String(format: "%.2f", sourceDuration))")
        print("analyzerBestFormat=\(bestFormat.map(describe) ?? "none(sourceのまま供給)") formatMode=\(config.format.rawValue)")
        print("compatibleFormats=\(compatible.map(describe))")

        let feedFormat = bestFormat ?? sourceFormat
        let chunks: [AVAudioPCMBuffer]
        do {
            chunks = try makeChunks(
                file: sourceFile,
                sourceFormat: sourceFormat,
                targetFormat: feedFormat,
                chunkMilliseconds: config.feed == .bulk ? (sourceDuration + 1) * 1_000 : config.chunkMilliseconds
            )
        } catch {
            print("エラー: 音声の分割・変換に失敗: \(AppLog.safeDescription(error))")
            return 1
        }
        let chunkFrames = chunks.first.map { Int($0.frameLength) } ?? 0
        let chunkSeconds = Double(chunkFrames) / feedFormat.sampleRate
        let silenceChunks = config.trailingSilenceMilliseconds > 0 && chunkSeconds > 0
            ? Int((config.trailingSilenceMilliseconds / 1_000 / chunkSeconds).rounded())
            : 0
        let paddedChunks = chunks + makeSilence(
            format: feedFormat,
            frames: AVAudioFrameCount(chunkFrames),
            count: silenceChunks
        )
        print("feedFormat=\(describe(feedFormat)) chunks=\(paddedChunks.count) chunkFrames=\(chunkFrames) chunkMs=\(String(format: "%.1f", chunkSeconds * 1_000)) feed=\(config.feed.rawValue) trailingSilenceMs=\(String(format: "%.0f", Double(silenceChunks) * chunkSeconds * 1_000))")

        let analyzer = SpeechAnalyzer(modules: modules)
        if config.prepareToAnalyze {
            let preparedAt = Date()
            do {
                try await analyzer.prepareToAnalyze(in: bestFormat)
                print(String(format: "prepareToAnalyze=ok elapsedMs=%.0f", Date().timeIntervalSince(preparedAt) * 1_000))
            } catch {
                print("prepareToAnalyze=失敗 \(AppLog.safeDescription(error))")
            }
        }

        let collector = ResultCollector()
        let startedAt = Date()
        collector.setStart(startedAt)

        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    collector.record(result)
                }
            } catch {
                print("結果ストリーム読み取りエラー: \(AppLog.safeDescription(error))")
            }
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let passesStartTime = config.passesBufferStartTime
        let sampleRate = feedFormat.sampleRate

        // TranscriptionEngine.startStreaming と同じ直列パイプライン。
        let consumerTask = Task.detached(priority: .userInitiated) {
            var frameCursor: Int64 = 0
            for await buffer in bufferStream {
                if passesStartTime {
                    let time = CMTime(value: frameCursor, timescale: CMTimeScale(sampleRate))
                    inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
                } else {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
                frameCursor += Int64(buffer.frameLength)
            }
        }

        let analyzerTask = Task {
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                print("analyzer.start失敗: \(AppLog.safeDescription(error))")
            }
        }

        let feed = config.feed
        let feedTask = Task.detached(priority: .userInitiated) {
            for (index, chunk) in paddedChunks.enumerated() {
                if feed == .realtime {
                    let wait = startedAt
                        .addingTimeInterval(Double(index) * chunkSeconds)
                        .timeIntervalSinceNow
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                }
                bufferContinuation.yield(chunk)
            }
        }
        await feedTask.value
        let inputFinishedAt = Date()

        bufferContinuation.finish()
        await consumerTask.value
        inputContinuation.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("finalize失敗: \(AppLog.safeDescription(error))")
        }
        await resultsTask.value
        await analyzerTask.value

        let records = collector.snapshot()
        print("--- results (経過ms / 文字数 / isFinal / 末尾20文字) ---")
        for record in records {
            print(String(
                format: "%8.0f  %4d  %-5@  %@",
                record.elapsed * 1_000,
                record.text.count,
                record.isFinal ? "true" : "false",
                tail(record.text, count: 20)
            ))
        }

        printSummary(
            records: records,
            startedAt: startedAt,
            inputFinishedAt: inputFinishedAt,
            sourceDuration: sourceDuration,
            config: config
        )
        await simulateHandsFreeSend(
            records: records,
            startedAt: startedAt,
            speechEndedSeconds: sourceDuration,
            config: config
        )

        if config.reserveLocale {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        return 0
    }

    private static func printSummary(
        records: [ResultRecord],
        startedAt: Date,
        inputFinishedAt: Date,
        sourceDuration: Double,
        config: Config
    ) {
        let inputFinishedElapsed = inputFinishedAt.timeIntervalSince(startedAt)
        let volatiles = records.filter { !$0.isFinal }
        let finals = records.filter { $0.isFinal }
        let midStreamFinals = finals.filter { $0.elapsed < inputFinishedElapsed }

        var intervals: [Double] = []
        var previous: Double?
        for record in volatiles {
            if let previous { intervals.append((record.elapsed - previous) * 1_000) }
            previous = record.elapsed
        }

        print("--- summary ---")
        print("label=\(config.label)")
        print(String(format: "sourceDurationSec=%.2f inputFinishedMs=%.0f", sourceDuration, inputFinishedElapsed * 1_000))
        if let first = volatiles.first {
            print(String(
                format: "firstVolatileMs=%.0f (録音長比 %.0f%%)",
                first.elapsed * 1_000,
                first.elapsed / max(sourceDuration, 0.001) * 100
            ))
        } else {
            print("firstVolatileMs=none")
        }
        print(String(
            format: "firstFinalMs=%@",
            finals.first.map { String(format: "%.0f", $0.elapsed * 1_000) } ?? "none"
        ))
        print(String(
            format: "volatileIntervalMedianMs=%@ volatileIntervalP95Ms=%@",
            intervals.isEmpty ? "none" : String(format: "%.0f", percentile(intervals, 0.5)),
            intervals.isEmpty ? "none" : String(format: "%.0f", percentile(intervals, 0.95))
        ))
        print("midStreamFinalCount=\(midStreamFinals.count)")
        print("volatileCount=\(volatiles.count) finalCount=\(finals.count)")
        print("finalTranscript=\(records.last?.text ?? "")")
    }

    /// 記録した partial の時系列を、実機と同じ `HandsFreeSendSession` へ再生する。
    /// 現行の0.35秒安定窓での発火時刻と、トリガー句の初到達・初 `isFinal` を比較する。
    @MainActor
    private static func simulateHandsFreeSend(
        records: [ResultRecord],
        startedAt: Date,
        speechEndedSeconds: Double,
        config: Config
    ) {
        let language: AppLanguage = config.localeIdentifier.lowercased().hasPrefix("ja") ? .japanese : .english
        let session = HandsFreeSendSession(snapshot: HandsFreeSendSnapshot(
            settings: HandsFreeSendSettings(enabled: true, triggerSource: .preset, customPhrase: ""),
            sttLanguage: language,
            externalCompatibilityEnabledAtRecordingStart: false
        ))
        session.markRecordingStarted(at: startedAt)

        var firstCandidate: ResultRecord?
        var firstFinalCandidate: ResultRecord?
        var firedAt: Date?
        var pending: HandsFreeSendSession.HandsFreeSendPendingCandidate?
        var lastTranscript = ""

        for record in records {
            let now = startedAt.addingTimeInterval(record.elapsed)
            // KoedexApp の deadline timer 相当。partial 到着より前に期限が来ていれば先に評価する。
            if let current = pending, current.deadline <= now {
                switch session.reevaluatePendingCandidate(current.candidate, for: lastTranscript, now: current.deadline) {
                case .ready:
                    firedAt = current.deadline
                case .pending(let next):
                    pending = next
                case .none:
                    pending = nil
                }
            }
            guard firedAt == nil else { break }

            let observation = session.observePartial(record.text, isFinal: record.isFinal, now: now)
            lastTranscript = record.text
            switch observation {
            case .none:
                pending = nil
            case .pending(let next):
                if firstCandidate == nil { firstCandidate = record }
                if record.isFinal, firstFinalCandidate == nil { firstFinalCandidate = record }
                pending = next
            case .ready:
                if firstCandidate == nil { firstCandidate = record }
                if record.isFinal, firstFinalCandidate == nil { firstFinalCandidate = record }
                pending = nil
                firedAt = now
            }
        }
        if firedAt == nil, let current = pending,
           case .ready = session.reevaluatePendingCandidate(
               current.candidate,
               for: lastTranscript,
               now: current.deadline
           ) {
            firedAt = current.deadline
        }

        let fireElapsed = firedAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        print("--- handsfree ---")
        print(String(
            format: "firstTriggerVolatileMs=%@ firstTriggerFinalMs=%@ currentPolicyFireMs=%@",
            firstCandidate.map { String(format: "%.0f", $0.elapsed * 1_000) } ?? "none",
            firstFinalCandidate.map { String(format: "%.0f", $0.elapsed * 1_000) } ?? "none",
            fireElapsed.map { String(format: "%.0f", $0) } ?? "none"
        ))
        if let firstCandidate, let fireElapsed {
            print(String(format: "savedByImmediateOnDetectionMs=%.0f", fireElapsed - firstCandidate.elapsed * 1_000))
        }
        if let firstFinalCandidate, let fireElapsed {
            print(String(format: "savedByImmediateOnFinalMs=%.0f", fireElapsed - firstFinalCandidate.elapsed * 1_000))
        }
        if let firstCandidate {
            print(String(
                format: "triggerDetectLagAfterSpeechMs=%.0f",
                firstCandidate.elapsed * 1_000 - speechEndedSeconds * 1_000
            ))
        }
    }

    private static func makeChunks(
        file: AVAudioFile,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        chunkMilliseconds: Double
    ) throws -> [AVAudioPCMBuffer] {
        let frameCount = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: max(frameCount, 1)) else {
            throw TranscriptionEngineInternalError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer)

        let whole: AVAudioPCMBuffer
        if sourceFormat == targetFormat {
            whole = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw TranscriptionEngineInternalError.converterCreationFailed
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw TranscriptionEngineInternalError.bufferAllocationFailed
            }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }
            if let conversionError { throw conversionError }
            whole = converted
        }

        let chunkFrames = max(AVAudioFrameCount(chunkMilliseconds / 1_000 * targetFormat.sampleRate), 1)
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(whole.mutableAudioBufferList)
        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let length = min(chunkFrames, whole.frameLength - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: length) else {
                throw TranscriptionEngineInternalError.bufferAllocationFailed
            }
            chunk.frameLength = length
            let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for index in 0..<min(source.count, destination.count) {
                guard let sourceData = source[index].mData,
                      let destinationData = destination[index].mData else { continue }
                memcpy(
                    destinationData,
                    sourceData.advanced(by: Int(offset) * bytesPerFrame),
                    Int(length) * bytesPerFrame
                )
            }
            chunks.append(chunk)
            offset += length
        }
        return chunks
    }

    private static func makeSilence(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        count: Int
    ) -> [AVAudioPCMBuffer] {
        guard count > 0, frames > 0 else { return [] }
        return (0..<count).compactMap { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            buffer.frameLength = frames
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for index in 0..<list.count {
                guard let data = list[index].mData else { continue }
                memset(data, 0, Int(list[index].mDataByteSize))
            }
            return buffer
        }
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    private static func tail(_ text: String, count: Int) -> String {
        text.count <= count ? text : String(text.suffix(count))
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        String(
            format: "%.0fHz/%dch/%@/%@",
            format.sampleRate,
            format.channelCount,
            commonFormatName(format.commonFormat),
            format.isInterleaved ? "interleaved" : "deinterleaved"
        )
    }

    private static func commonFormatName(_ value: AVAudioCommonFormat) -> String {
        switch value {
        case .pcmFormatFloat32: return "f32"
        case .pcmFormatFloat64: return "f64"
        case .pcmFormatInt16: return "i16"
        case .pcmFormatInt32: return "i32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }

    private static func names<T>(_ options: Set<T>) -> [String] {
        options.map { String(describing: $0) }.sorted()
    }
}

/// 結果コールバックはSpeech側のスレッドから届くためロックで保護する。
/// 本文の組み立ては `TranscriptionEngine.handleResult` と同じ規則にそろえる。
private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [StreamingPartialProbe.ResultRecord] = []
    private var finalizedSegments: [String] = []
    private var startedAt = Date()

    func setStart(_ date: Date) {
        lock.lock()
        startedAt = date
        lock.unlock()
    }

    func record(_ result: SpeechTranscriber.Result) {
        let now = Date()
        let segment = String(result.text.characters)
        lock.lock()
        let accumulated: String
        if result.isFinal {
            finalizedSegments.append(segment)
            accumulated = finalizedSegments.joined()
        } else {
            accumulated = finalizedSegments.joined() + segment
        }
        records.append(StreamingPartialProbe.ResultRecord(
            elapsed: now.timeIntervalSince(startedAt),
            text: accumulated,
            segment: segment,
            isFinal: result.isFinal,
            rangeStart: result.range.start.seconds,
            rangeEnd: result.range.end.seconds
        ))
        lock.unlock()
    }

    func snapshot() -> [StreamingPartialProbe.ResultRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
