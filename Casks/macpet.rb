cask "macpet" do
  version "0.1.5"
  sha256 "613c479f54da055ae2bc4669f4acceb515d631e800ca39c741c0d2ecc82c90f0"

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
