//
//  LyricsService.swift
//  boringNotch
//
//  Extracted from MusicManager for better separation of concerns.
//

import AppKit
import Foundation

/// Service responsible for fetching and parsing lyrics for the currently playing track.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []

    // Cache to avoid redundant fetches; NSCache evicts under memory pressure
    // instead of growing for the whole session.
    private final class LyricsEntry {
        let plain: String
        let synced: [(time: Double, text: String)]
        init(plain: String, synced: [(time: Double, text: String)]) {
            self.plain = plain
            self.synced = synced
        }
    }
    private let lyricsCache = NSCache<NSString, LyricsEntry>()
    private var currentFetchTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Fetches lyrics for the given track, preferring native Apple Music lyrics when available.
    func fetchLyrics(bundleIdentifier: String?, title: String, artist: String) async {
        // Cancel any pending fetch
        currentFetchTask?.cancel()

        guard !title.isEmpty else {
            clearLyrics()
            return
        }

        // Check cache first
        let cacheKey = cacheKey(title: title, artist: artist)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            currentLyrics = cached.plain
            syncedLyrics = cached.synced
            isFetchingLyrics = false
            return
        }

        isFetchingLyrics = true
        currentLyrics = ""
        syncedLyrics = []
        bnDebugLog("lyrics fetch title=\(title) artist=\(artist) player=\(bundleIdentifier ?? "nil")")

        let task = Task { [weak self] in
            guard let self = self else { return }

            // 11-07: a TIME LINE is worth more than a fuller text. The old
            // order tried Music.app first: `lyrics of current track` is plain
            // prose with no timestamps, and returning it immediately meant the
            // LRC sources below were NEVER reached. For an Apple Music-only
            // listener that showed the whole song squeezed into one static
            // line. Synced sources now win; AppleScript is the last resort.
            let webResult = await self.fetchLyricsFromWeb(title: title, artist: artist)
            guard !Task.isCancelled else { return }
            if !webResult.synced.isEmpty {
                await MainActor.run {
                    self.store(plain: webResult.plain, synced: webResult.synced, cacheKey: cacheKey, source: "LRCLIB")
                }
                return
            }

            // LRCLIB has thin coverage for Chinese / Asian-language songs.
            // NetEase returns a standard [mm:ss.xxx] LRC, which parseLRC
            // already understands; this is the same fallback Lyric Fever uses.
            let netEaseResult = await self.fetchLyricsFromNetEase(title: title, artist: artist)
            guard !Task.isCancelled else { return }
            if !netEaseResult.synced.isEmpty {
                await MainActor.run {
                    self.store(plain: netEaseResult.plain, synced: netEaseResult.synced, cacheKey: cacheKey, source: "NetEase")
                }
                return
            }

            // No time line anywhere: prefer the fuller plain text, and only
            // then ask Music.app. Never let plain text stand in for synced.
            var plain = webResult.plain.isEmpty ? netEaseResult.plain : webResult.plain
            if plain.isEmpty,
               let bundleIdentifier = bundleIdentifier,
               bundleIdentifier.contains(MediaAppBundleID.appleMusic) {
                plain = await self.fetchAppleMusicLyrics() ?? ""
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.store(plain: plain, synced: [], cacheKey: cacheKey, source: "plain-only")
            }
        }

        currentFetchTask = task
        await task.value
    }

    /// Clears all lyrics data.
    func clearLyrics() {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        currentLyrics = ""
        syncedLyrics = []
        isFetchingLyrics = false
    }

    /// Returns the lyric line at the given elapsed time for synced lyrics.
    /// Logs only when the line CHANGES — the island redraws every 0.25s, so
    /// logging every tick would bury /tmp/bn-notch.log. This is the runtime
    /// proof that the LRC time line is actually advancing.
    private var lastLoggedLine: String = ""

    func lyricLine(at elapsed: Double) -> String {
        let text = lyricLineContext(at: elapsed).text
        if text != lastLoggedLine {
            lastLoggedLine = text
            bnDebugLog("lyrics line @\(Int(elapsed))s: \(text)")
        }
        return text
    }

    /// Returns the active synced lyric line and its timing window.
    func lyricLineContext(at elapsed: Double) -> (text: String, startTime: Double, endTime: Double?) {
        guard !syncedLyrics.isEmpty else { return (currentLyrics, 0, nil) }

        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let nextIndex = syncedLyrics.index(after: idx)
        let endTime = nextIndex < syncedLyrics.endIndex ? syncedLyrics[nextIndex].time : nil
        return (syncedLyrics[idx].text, syncedLyrics[idx].time, endTime)
    }

    // MARK: - Private Methods

    private func cacheKey(title: String, artist: String) -> String {
        "\(normalizedQuery(title))|\(normalizedQuery(artist))"
    }

    private func store(plain: String, synced: [(time: Double, text: String)], cacheKey: String, source: String) {
        bnDebugLog("lyrics hit source=\(source) syncedLines=\(synced.count) plainChars=\(plain.count)")
        currentLyrics = plain
        syncedLyrics = synced
        isFetchingLyrics = false
        if !plain.isEmpty || !synced.isEmpty {
            lyricsCache.setObject(LyricsEntry(plain: plain, synced: synced), forKey: cacheKey as NSString)
        }
    }

    /// NetEase Cloud Music fallback (11-07). Both endpoints are public, need
    /// no key, and return a standard [mm:ss.xxx] LRC in `lrc.lyric`. Used only
    /// when LRCLIB has no time-synced lines — its Chinese coverage is thin.
    private func fetchLyricsFromNetEase(title: String, artist: String) async -> (plain: String, synced: [(time: Double, text: String)]) {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        guard !cleanTitle.isEmpty,
              let query = "\(cleanTitle) \(cleanArtist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/search/get?s=\(query)&type=1&offset=0&limit=10") else {
            return ("", [])
        }

        do {
            let searchData = try await self.fetchData(from: searchURL)
            guard let json = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let songID = self.bestNetEaseMatch(in: songs, title: cleanTitle, artist: cleanArtist) else {
                return ("", [])
            }

            guard let lyricURL = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else {
                return ("", [])
            }
            let lyricData = try await self.fetchData(from: lyricURL)
            guard let lyricJSON = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJSON["lrc"] as? [String: Any],
                  let lrcText = lrc["lyric"] as? String, !lrcText.isEmpty else {
                return ("", [])
            }

            let lines = parseLRC(lrcText).filter { !isCreditsLine($0.text) }
            return (lines.map { $0.text }.joined(separator: "\n"), lines)
        } catch {
            return ("", [])
        }
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (BoringNotch)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Rank by title/artist so a cover or a live version does not win over the
    /// recording that is actually playing. No duration guard: MusicManager's
    /// duration is not always populated for streamed tracks.
    private func bestNetEaseMatch(in songs: [[String: Any]], title: String, artist: String) -> Int? {
        var bestID: Int?
        var bestScore = 0
        for song in songs {
            guard let number = song["id"] as? NSNumber else { continue }
            let name = (song["name"] as? String) ?? ""
            let artists = (song["artists"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }
                .joined(separator: " ") ?? ""
            var score = 0
            if name.lowercased() == title.lowercased() {
                score += 10
            } else if name.lowercased().contains(title.lowercased()) {
                score += 4
            }
            let artistMatch = !artist.isEmpty && !artists.isEmpty
                && (artists.lowercased().contains(artist.lowercased())
                    || artist.lowercased().contains(artists.lowercased()))
            // An artist match outranks an exact title match: covers and live
            // edits otherwise win over the actual recording. Some catalogue
            // tracks are gone from NetEase entirely (only covers remain), so a
            // title-only match is still accepted as a best effort — the LRC
            // text is usually shared, the timing is approximately right.
            if artistMatch { score += 20 }
            if score > bestScore {
                bestScore = score
                bestID = number.intValue
            }
        }
        return bestID
    }

    /// NetEase LRC files open with 作词 / 作曲 / 编曲 credit lines. They are
    /// never sung; showing one as "the current line" reads as broken lyrics.
    private func isCreditsLine(_ text: String) -> Bool {
        let prefixes = ["作词", "作曲", "编曲", "制作人", "演唱", "吉他", "贝斯", "鼓", "录音", "混音", "和声", "出品", "监制", "词:", "曲:", "Lyrics", "Composed", "Producer"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private func fetchAppleMusicLyrics() async -> String? {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
        guard !runningApps.isEmpty else { return nil }

        let script = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return ""
                        else
                            return l
                        end if
                    on error
                        return ""
                    end try
                else
                    return ""
                end if
            else
                return ""
            end if
        end tell
        """

        do {
            if let result = try await AppleScriptHelper.execute(script),
               let lyricsString = result.stringValue,
               !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Fall through to return nil
        }
        return nil
    }

    private func fetchLyricsFromWeb(title: String, artist: String) async -> (plain: String, synced: [(time: Double, text: String)]) {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)

        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ("", [])
        }

        // Try with artist first, then without if no results
        let searchStrategies: [String] = {
            var strategies: [String] = []

            // Strategy 1: Search with artist (if provided)
            if !cleanArtist.isEmpty,
               let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                strategies.append("https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)")
            }

            // Strategy 2: Search with title only (always include as fallback)
            strategies.append("https://lrclib.net/api/search?track_name=\(encodedTitle)")

            return strategies
        }()

        for urlString in searchStrategies {
            guard let url = URL(string: urlString) else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }

                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = findBestMatch(in: jsonArray, title: cleanTitle, artist: cleanArtist) {
                    let plain = (first["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let synced = (first["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if !plain.isEmpty || !synced.isEmpty {
                        let resolvedPlain = plain.isEmpty ? synced : plain
                        let parsedSynced = synced.isEmpty ? [] : parseLRC(synced)
                        return (resolvedPlain, parsedSynced)
                    }
                }
            } catch {
                continue
            }
        }

        return ("", [])
    }

    /// Find the best matching result from the search results based on title similarity
    private func findBestMatch(in results: [[String: Any]], title: String, artist: String) -> [String: Any]? {
        guard !results.isEmpty else { return nil }

        // If only one result, use it
        if results.count == 1 { return results.first }

        let normalizedTitle = title.lowercased()
        let normalizedArtist = artist.lowercased()

        // Score each result and pick the best
        var bestResult: [String: Any]?
        var bestScore = 0

        for result in results {
            var score = 0

            // Check title match
            if let resultTitle = result["trackName"] as? String {
                if resultTitle.lowercased() == normalizedTitle {
                    score += 10
                } else if resultTitle.lowercased().contains(normalizedTitle) || normalizedTitle.contains(resultTitle.lowercased()) {
                    score += 5
                }
            }

            // Check artist match (bonus if provided and matches)
            if !normalizedArtist.isEmpty, let resultArtist = result["artistName"] as? String {
                if resultArtist.lowercased() == normalizedArtist {
                    score += 8
                } else if resultArtist.lowercased().contains(normalizedArtist) || normalizedArtist.contains(resultArtist.lowercased()) {
                    score += 4
                }
            }

            // Prefer results with lyrics
            if let plain = result["plainLyrics"] as? String, !plain.isEmpty {
                score += 2
            }
            if let synced = result["syncedLyrics"] as? String, !synced.isEmpty {
                score += 3
            }

            if score > bestScore {
                bestScore = score
                bestResult = result
            }
        }

        return bestResult ?? results.first
    }

    // MARK: - Synced lyrics helpers

    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for lineSub in lrc.split(separator: "\n") {
            let line = String(lineSub)
            let nsLine = line as NSString

            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
                continue
            }

            let minStr = nsLine.substring(with: match.range(at: 1))
            let secStr = nsLine.substring(with: match.range(at: 2))
            let msRange = match.range(at: 3)
            let msStr = msRange.location != NSNotFound ? nsLine.substring(with: msRange) : "0"

            let minutes = Double(minStr) ?? 0
            let seconds = Double(secStr) ?? 0
            // Handle both centiseconds (2 digits) and milliseconds (3 digits)
            let msValue = Double(msStr) ?? 0
            let msDivisor = msStr.count == 3 ? 1000.0 : 100.0
            let time = minutes * 60 + seconds + msValue / msDivisor

            let textStart = match.range.location + match.range.length
            let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result.append((time, text))
            }
        }

        return result.sorted { $0.0 < $1.0 }
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
