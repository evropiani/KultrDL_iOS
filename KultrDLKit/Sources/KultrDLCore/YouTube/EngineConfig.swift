import Foundation

/**
 * One way of asking YouTube for a video's streams: a client of the
 * InnerTube player API, as yt-dlp lists them. YouTube refuses some clients
 * on some networks, or for some videos, so KultrDL tries them in order and
 * remembers the one that works.
 */
public struct InnerTubeClient: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var clientName: String
    public var clientVersion: String
    /** X-YouTube-Client-Name. */
    public var clientNameId: Int
    public var userAgent: String?
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    public var androidSdkVersion: Int?
    /** Its stream links need the player's JavaScript (signature and "n" challenges). */
    public var requiresJS: Bool
    /** Asks as a player embedded on another site. */
    public var embedded: Bool
    public var host: String

    public var id: String { key }

    public init(
        key: String, label: String, clientName: String, clientVersion: String, clientNameId: Int,
        userAgent: String? = nil, deviceMake: String? = nil, deviceModel: String? = nil,
        osName: String? = nil, osVersion: String? = nil, androidSdkVersion: Int? = nil,
        requiresJS: Bool, embedded: Bool = false, host: String = "www.youtube.com"
    ) {
        self.key = key
        self.label = label
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientNameId = clientNameId
        self.userAgent = userAgent
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
        self.androidSdkVersion = androidSdkVersion
        self.requiresJS = requiresJS
        self.embedded = embedded
        self.host = host
    }
}

/**
 * The parts of KultrDL that follow YouTube: its clients and their
 * versions, and the challenge solver's version. The defaults are built in;
 * a newer copy is fetched from the KultrDL repository (Settings → Engine),
 * so a change on YouTube's side is fixed without a new release, as yt-dlp
 * updating itself does on Android.
 */
public struct EngineConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var updated: String
    public var clients: [InnerTubeClient]
    public var musicClientVersion: String
    public var webClientVersion: String
    /** Where newer challenge solver scripts can be fetched (yt-dlp/ejs release assets), if anywhere. */
    public var solverLibUrl: String?
    public var solverCoreUrl: String?
    public var solverVersion: String?

    public static let updateUrl = "https://raw.githubusercontent.com/evropiani/KultrDL_iOS/main/engine/youtube.json"

    public static let builtIn = EngineConfig(
        version: 1,
        updated: "2026-08-19",
        clients: [
            InnerTubeClient(
                key: "visionos", label: "visionOS client", clientName: "VISIONOS", clientVersion: "1.02", clientNameId: 101,
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                deviceMake: "Apple", deviceModel: "RealityDevice17,1", osName: "visionOS", osVersion: "26.5.23O471",
                requiresJS: false
            ),
            InnerTubeClient(
                key: "tv", label: "TV client", clientName: "TVHTML5", clientVersion: "7.20260707.07.00", clientNameId: 7,
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
                requiresJS: true
            ),
            InnerTubeClient(
                key: "web_embedded", label: "Embedded player", clientName: "WEB_EMBEDDED_PLAYER", clientVersion: "2.20260708.00.00", clientNameId: 56,
                requiresJS: true, embedded: true
            ),
            InnerTubeClient(
                key: "tv_downgraded", label: "Older TV client", clientName: "TVHTML5", clientVersion: "5.20260707", clientNameId: 7,
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
                requiresJS: true
            ),
            InnerTubeClient(
                key: "android_vr", label: "Android VR client", clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameId: 28,
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                deviceMake: "Oculus", deviceModel: "Quest 3", osName: "Android", osVersion: "12L", androidSdkVersion: 32,
                requiresJS: false
            ),
            InnerTubeClient(
                key: "ios", label: "iOS client", clientName: "IOS", clientVersion: "21.26.4", clientNameId: 5,
                userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82",
                requiresJS: false
            ),
        ],
        musicClientVersion: "1.20260707.12.00",
        webClientVersion: "2.20260708.00.00",
        solverLibUrl: nil,
        solverCoreUrl: nil,
        solverVersion: "0.8.0"
    )

    public func client(_ key: String) -> InnerTubeClient? { clients.first { $0.key == key } }

    /** The clients to try, starting with [first] when it is one of them. */
    public func order(startingWith first: String?) -> [InnerTubeClient] {
        guard let first, let head = client(first) else { return clients }
        return [head] + clients.filter { $0.key != first }
    }
}
