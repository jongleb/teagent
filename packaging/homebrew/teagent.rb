class Teagent < Formula
  desc "Coding agent whose unit of work is a typed program"
  homepage "https://github.com/jongleb/teagent"
  license "BSD-3-Clause"

  on_macos do
    on_arm do
      url "https://github.com/jongleb/teagent/releases/download/v@VERSION@/teagent-@VERSION@-aarch64-apple-darwin.tar.gz"
      sha256 "@SHA256:aarch64-apple-darwin@"
    end

    on_intel do
      url "https://github.com/jongleb/teagent/releases/download/v@VERSION@/teagent-@VERSION@-x86_64-apple-darwin.tar.gz"
      sha256 "@SHA256:x86_64-apple-darwin@"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/jongleb/teagent/releases/download/v@VERSION@/teagent-@VERSION@-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "@SHA256:x86_64-unknown-linux-gnu@"
    end

    on_arm do
      url "https://github.com/jongleb/teagent/releases/download/v@VERSION@/teagent-@VERSION@-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "@SHA256:aarch64-unknown-linux-gnu@"
    end
  end

  def install
    bin.install "teagent"
    doc.install "README.md"
    (share/"licenses"/name).install "LICENSE", Dir["licenses/*"]
  end

  def caveats
    on_linux do
      <<~EOS
        The sandboxed shell needs bubblewrap at /usr/bin/bwrap:
          sudo apt install bubblewrap   # or dnf, pacman, apk
      EOS
    end
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/teagent --version").strip
  end
end
