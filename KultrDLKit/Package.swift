// swift-tools-version:5.9
import PackageDescription

// The parts of KultrDL for iOS that are not the interface:
//
// - KultrDLCore: the catalogues (YouTube Music, YouTube, Apple Music,
//   Deezer, Spotify, SoundCloud, Bandcamp, song.link, store pages), link
//   recognition, the matcher, YouTube's player API with its JavaScript
//   challenges (the part yt-dlp does on Android), streams from each site,
//   and the file formats written by hand (WebM, ID3, Vorbis comments, WAV).
// - KultrDLMedia: turning a downloaded stream into FLAC, MP3, AAC, Opus,
//   ALAC, WAV or Ogg Vorbis with tags and cover art (what ffmpeg does on
//   Android), with libFLAC, LAME, libopus, libvorbis and AVFoundation.
// - KultrDLRemote: FTP, FTPS and SFTP uploads, with CBcryptPBKDF (OpenBSD's
//   bcrypt_pbkdf) for passphrase-protected OpenSSH keys.
//
// The app links all three; `swift test` runs the tests on a Mac.
let package = Package(
    name: "KultrDLKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KultrDLCore", targets: ["KultrDLCore"]),
        .library(name: "KultrDLMedia", targets: ["KultrDLMedia"]),
        .library(name: "KultrDLRemote", targets: ["KultrDLRemote"]),
        .executable(name: "kultrdl-probe", targets: ["kultrdl-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/lame-binary-xcframework", exact: "0.1.2"),
        .package(url: "https://github.com/sbooth/flac-binary-xcframework", exact: "0.2.0"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework", exact: "0.1.3"),
        .package(url: "https://github.com/sbooth/vorbis-binary-xcframework", exact: "0.1.2"),
        .package(url: "https://github.com/sbooth/opus-binary-xcframework", exact: "0.3.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        // The same fork Citadel 0.12.0 depends on, named so NIOSSH can be imported directly.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "KultrDLCore",
            resources: [.copy("Resources/ejs")]
        ),
        .target(
            name: "COpusShim",
            dependencies: [.product(name: "opus", package: "opus-binary-xcframework")]
        ),
        .target(
            name: "KultrDLMedia",
            dependencies: [
                "KultrDLCore",
                "COpusShim",
                .product(name: "lame", package: "lame-binary-xcframework"),
                .product(name: "FLAC", package: "flac-binary-xcframework"),
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                .product(name: "vorbis", package: "vorbis-binary-xcframework"),
                .product(name: "opus", package: "opus-binary-xcframework"),
            ]
        ),
        .target(name: "CBcryptPBKDF"),
        .target(
            name: "KultrDLRemote",
            dependencies: [
                "KultrDLCore",
                "CBcryptPBKDF",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "kultrdl-probe",
            dependencies: ["KultrDLCore", "KultrDLMedia", "KultrDLRemote"]
        ),
        .testTarget(
            name: "KultrDLCoreTests",
            dependencies: ["KultrDLCore"]
        ),
        .testTarget(
            name: "KultrDLMediaTests",
            dependencies: ["KultrDLCore", "KultrDLMedia"]
        ),
    ]
)
