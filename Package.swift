import PackageDescription

let package = Package(
  name: "EpollInSwift",
  dependencies: [
    .Package(url: "git@github.com:machados/GlibcExtras.git", majorVersion: 0)
  ]
)
