class Lantana < Formula
  desc "Terminal viewer for Git patches"
  homepage "https://github.com/hashiiiii/Lantana"
  version "{{VERSION}}"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-arm64.zip"
      sha256 "{{SHA256_MACOS_ARM64}}"
    end
    on_intel do
      url "https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-x64.zip"
      sha256 "{{SHA256_MACOS_X64}}"
    end
  end
  on_linux do
    on_arm do
      url "https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-arm64.zip"
      sha256 "{{SHA256_LINUX_ARM64}}"
    end
    on_intel do
      url "https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-x64.zip"
      sha256 "{{SHA256_LINUX_X64}}"
    end
  end

  def install
    bin.install "lantana"
  end

  test do
    assert_equal "lantana #{version}\n", shell_output("#{bin}/lantana --version")
  end
end
