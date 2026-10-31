cask "macpet" do
  version "0.1.4"
  sha256 "a4a06b3ee2353b311e3d327ea71d7f49b9da71439763d1fb46119999f5124f18"

  url "https://github.com/PedroTatibanoWorkSpace/macpet/releases/download/v#{version}/MacPet-#{version}.zip"
  name "MacPet"
  desc "Monitor de sistema na barra de menu com um pet que acompanha o Claude Code"
  homepage "https://github.com/PedroTatibanoWorkSpace/macpet"

  depends_on macos: :sonoma

  app "MacPet.app"

  # O app é assinado ad-hoc (sem conta paga de desenvolvedor Apple); remove a quarentena
  # para o Gatekeeper não bloquear a abertura.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MacPet.app"]
  end

  uninstall quit: "app.macpet"

  zap trash: [
    "~/.macpet",
    "~/Library/Application Support/MacPet",
    "~/Library/Preferences/app.macpet.plist",
  ]
end
