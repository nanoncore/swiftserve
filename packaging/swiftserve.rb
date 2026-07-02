# Homebrew formula template — lives in the tap repo (<account>/homebrew-tap,
# under Formula/) once the first release exists. Fill URL + sha256 from the
# release's checksums.txt.
class Swiftserve < Formula
  desc "Capability truth + dependency health for Swift packages"
  homepage "https://swiftserve.dev"
  version "0.1.0" # keep in sync with the tag
  license "TODO: set once the repo has a LICENSE"

  on_macos do
    url "https://github.com/nanoncore/swiftserve/releases/download/v#{version}/swiftserve-v#{version}-macos-universal.tar.gz"
    sha256 "TODO_FROM_CHECKSUMS_TXT"
  end

  on_linux do
    on_intel do
      url "https://github.com/nanoncore/swiftserve/releases/download/v#{version}/swiftserve-v#{version}-linux-x86_64.tar.gz"
      sha256 "TODO_FROM_CHECKSUMS_TXT"
    end
    on_arm do
      url "https://github.com/nanoncore/swiftserve/releases/download/v#{version}/swiftserve-v#{version}-linux-aarch64.tar.gz"
      sha256 "TODO_FROM_CHECKSUMS_TXT"
    end
  end

  def install
    bin.install "swiftserve"
  end

  test do
    system bin/"swiftserve", "--help"
  end
end
