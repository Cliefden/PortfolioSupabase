// swift-tools-version: 6.0
import PackageDescription

// Shared helpers for the portfolio apps that use the official supabase-swift
// SDK (Stokked, Nassau, Jeroboam, Carpe Vitem, ThenCam, and the hand-rolled
// apps as they migrate). It does not wrap the SDK: apps keep calling
// `client.auth`, `client.from(...)` and so on. It holds the code each app used
// to copy: auth storage, the client factory, the auth-state stream, the
// refresh-once wrapper, Sign in with Apple, validation, error copy, account
// deletion, storage uploads and pagination.
//
// The package's own UI strings live in Resources/Localizable.xcstrings and are
// resolved against `Bundle.module` (see Localization.swift).
let package = Package(
    name: "PortfolioSupabase",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "PortfolioSupabase", targets: ["PortfolioSupabase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.40.0"),
    ],
    targets: [
        .target(
            name: "PortfolioSupabase",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PortfolioSupabaseTests",
            dependencies: [
                "PortfolioSupabase",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
    ]
)
