{
  config,
  lib,
  pkgs,
  ...
}:

let
  devenv =
    pkgs.runCommand "devenv-0.0.0" { } ''
      mkdir -p $out/bin
      cat > $out/bin/devenv <<'EOF'
      #!/usr/bin/env bash
      exit 0
      EOF
      chmod +x $out/bin/devenv
    ''
    // {
      meta.mainProgram = "devenv";
    };
in
{
  programs.bash.enable = true;
  programs.zsh.enable = true;
  programs.fish.enable = true;

  programs.devenv = {
    enable = true;
    package = devenv;
  };

  test = ''
    echo >&2 "checking devenv bash integration in /etc/bashrc"
    grep 'devenv hook bash' ${config.out}/etc/bashrc

    echo >&2 "checking devenv zsh integration in /etc/zshrc"
    grep 'devenv hook zsh' ${config.out}/etc/zshrc

    echo >&2 "checking devenv fish integration in /etc/fish/config.fish"
    grep 'devenv hook fish' ${config.out}/etc/fish/config.fish
  '';
}
