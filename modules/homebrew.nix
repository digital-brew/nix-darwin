# Created by: https://github.com/malob
{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.homebrew;

  brewfileFile = pkgs.writeText "Brewfile" cfg.brewfile;

  # Brewfile creation helper functions -------------------------------------------------------------

  mkBrewfileSectionString = heading: entries: optionalString (entries != [ ]) ''
    # ${heading}
    ${concatMapStringsSep "\n" (v: v.brewfileLine or v) entries}

  '';

  mkBrewfileLineValueString = v:
    if isInt v then toString v
    else if isFloat v then strings.floatToString v
    else if isBool v then boolToString v
    else if isString v then ''"${v}"''
    else if isAttrs v then "{ ${concatStringsSep ", " (mapAttrsToList (n: v': "${n}: ${mkBrewfileLineValueString v'}") v)} }"
    else if isList v then "[${concatMapStringsSep ", " mkBrewfileLineValueString v}]"
    else abort "The value: ${generators.toPretty v} is not a valid Brewfile value.";

  mkBrewfileLineOptionsListString = attrs:
    concatStringsSep ", " (mapAttrsToList (n: v: "${n}: ${v}") attrs);


  # Option and submodule helper functions ----------------------------------------------------------

  mkNullOrBoolOption = args: mkOption (args // {
    type = types.nullOr types.bool;
    default = null;
  });

  mkNullOrStrOption = args: mkOption (args // {
    type = types.nullOr types.str;
    default = null;
  });

  mkInternalOption = args: mkOption (args // {
    visible = false;
    internal = true;
    readOnly = true;
  });

  mkProcessedSubmodConfig = attrs: mapAttrs (_: mkBrewfileLineValueString)
    (filterAttrsRecursive (n: v: n != "_module" && n != "brewfileLine" && v != null) attrs);


  # Submodules -------------------------------------------------------------------------------------
  # Option values and descriptions of Brewfile entries are sourced/derived from:
  #   * `brew` manpage: https://docs.brew.sh/Manpage
  #   * `brew bundle` source files (at https://github.com/Homebrew/homebrew-bundle/tree/9fffe077f1a5a722ed5bd26a87ed622e8cb64e0c):
  #     * lib/bundle/dsl.rb
  #     * lib/bundle/{brew,cask,tap}_installer.rb
  #     * spec/bundle/{brew,cask,tap}_installer_spec.rb

  onActivationOptions = { config, ... }: {
    options = {
      cleanup = mkOption {
        type = types.enum [ "none" "uninstall" "zap" ];
        default = "none";
        example = "uninstall";
        description = ''
          This option manages what happens to formulae installed by Homebrew, that aren't present in
          the Brewfile generated by this module, during {command}`nix-darwin` system
          activation.

          When set to `"none"` (the default), formulae not present in the generated
          Brewfile are left installed.

          When set to `"uninstall"`, {command}`nix-darwin` invokes
          {command}`brew bundle [install]` with the {command}`--cleanup` flag. This
          uninstalls all formulae not listed in generated Brewfile, i.e.,
          {command}`brew uninstall` is run for those formulae.

          When set to `"zap"`, {command}`nix-darwin` invokes
          {command}`brew bundle [install]` with the {command}`--cleanup --zap`
          flags. This uninstalls all formulae not listed in the generated Brewfile, and if the
          formula is a cask, removes all files associated with that cask. In other words,
          {command}`brew uninstall --zap` is run for all those formulae.

          If you plan on exclusively using {command}`nix-darwin` to manage formulae
          installed by Homebrew, you probably want to set this option to
          `"uninstall"` or `"zap"`.
        '';
      };
      autoUpdate = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable Homebrew to auto-update itself and all formulae during
          {command}`nix-darwin` system activation. The default is `false`
          so that repeated invocations of {command}`darwin-rebuild switch` are idempotent.

          Note that Homebrew auto-updates when it's been more then 5 minutes since it last updated.

          Although auto-updating is disabled by default during system activation, note that Homebrew
          will auto-update when you manually invoke certain Homebrew commands. To modify this
          behavior see [](#opt-homebrew.global.autoUpdate).

          Implementation note: when disabled, this option sets the `HOMEBREW_NO_AUTO_UPDATE`
          environment variable when {command}`nix-darwin` invokes {command}`brew bundle [install]`
          during system activation.
        '';
      };
      upgrade = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable Homebrew to upgrade outdated formulae and Mac App Store apps during
          {command}`nix-darwin` system activation. The default is `false`
          so that repeated invocations of {command}`darwin-rebuild switch` are idempotent.

          Implementation note: when disabled, {command}`nix-darwin` invokes
          {command}`brew bundle [install]` with the {command}`--no-upgrade` flag during system
          activation.
        '';
      };
      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--verbose" ];
        description = ''
          Extra flags to pass to {command}`brew bundle [install]` during {command}`nix-darwin`
          system activation.
        '';
      };

      brewBundleCmd = mkInternalOption { type = types.str; };
    };

    config = {
      brewBundleCmd = concatStringsSep " " (
        optional (!config.autoUpdate) "HOMEBREW_NO_AUTO_UPDATE=1"
        ++ [ "brew bundle --file='${brewfileFile}' --no-lock" ]
        ++ optional (!config.upgrade) "--no-upgrade"
        ++ optional (config.cleanup == "uninstall") "--cleanup"
        ++ optional (config.cleanup == "zap") "--cleanup --zap"
        ++ config.extraFlags
      );
    };
  };

  globalOptions = { config, ... }: {
    options = {
      brewfile = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable Homebrew to automatically use the Brewfile that this module generates in
          the Nix store, when you manually invoke {command}`brew bundle`.

          Enabling this option will change the default value of
          [](#opt-homebrew.global.lockfiles) to `false` since, with
          this option enabled, {command}`brew bundle [install]` will default to using the
          Brewfile that this module generates in the Nix store, unless you explicitly point it at
          another Brewfile using the `--file` flag. As a result, it will try to
          write the lockfile in the Nix store, and complain that it can't (though the command will
          run successfully regardless).

          Implementation note: when enabled, this option sets the
          `HOMEBREW_BUNDLE_FILE` environment variable to the path of the Brewfile
          that this module generates in the Nix store, by adding it to
          [](#opt-environment.variables).
        '';
      };
      autoUpdate = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable Homebrew to auto-update itself and all formulae when you manually invoke
          commands like {command}`brew install`, {command}`brew upgrade`,
          {command}`brew tap`, and {command}`brew bundle [install]`.

          Note that Homebrew auto-updates when you manually invoke commands like the ones mentioned
          above if it's been more then 5 minutes since it last updated.

          You may want to consider disabling this option if you have
          [](#opt-homebrew.onActivation.upgrade) enabled, and
          [](#opt-homebrew.onActivation.autoUpdate) disabled, if you want to ensure that
          your installed formulae will only be upgraded during {command}`nix-darwin` system
          activation, after you've explicitly run {command}`brew update`.

          Implementation note: when disabled, this option sets the
          `HOMEBREW_NO_AUTO_UPDATE` environment variable, by adding it to
          [](#opt-environment.variables).
        '';
      };
      lockfiles = mkOption {
        type = types.bool;
        default = !config.brewfile;
        defaultText = literalExpression "!config.homebrew.global.brewfile";
        description = ''
          Whether to enable Homebrew to generate lockfiles when you manually invoke
          {command}`brew bundle [install]`.

          This option will default to `false` if
          [](#opt-homebrew.global.brewfile) is enabled since, with that option enabled,
          {command}`brew bundle [install]` will default to using the Brewfile that this
          module generates in the Nix store, unless you explicitly point it at another Brewfile
          using the `--file` flag. As a result, it will try to write the
          lockfile in the Nix store, and complain that it can't (though the command will run
          successfully regardless).

          Implementation note: when disabled, this option sets the
          `HOMEBREW_BUNDLE_NO_LOCK` environment variable, by adding it to
          [](#opt-environment.variables).
        '';
      };

      # The `noLock` option was replaced by `lockfiles`. Due to `homebrew.global` being a submodule,
      # we can't use `mkRemovedOptionModule`, so we leave this option definition here, and trigger
      # and error message with an assertion below if it's set by the user.
      noLock = mkOption { visible = false; default = null; };

      homebrewEnvironmentVariables = mkInternalOption { type = types.attrs; };
    };

    config = {
      homebrewEnvironmentVariables = {
        HOMEBREW_BUNDLE_FILE = mkIf config.brewfile "${brewfileFile}";
        HOMEBREW_NO_AUTO_UPDATE = mkIf (!config.autoUpdate) "1";
        HOMEBREW_BUNDLE_NO_LOCK = mkIf (!config.lockfiles) "1";
      };
    };
  };

  tapOptions = { config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        example = "homebrew/cask-fonts";
        description = ''
          When {option}`clone_target` is unspecified, this is the name of a formula
          repository to tap from GitHub using HTTPS. For example, `"user/repo"`
          will tap https://github.com/user/homebrew-repo.
        '';
      };
      clone_target = mkNullOrStrOption {
        description = ''
          Use this option to tap a formula repository from anywhere, using any transport protocol
          that {command}`git` handles. When {option}`clone_target` is specified, taps
          can be cloned from places other than GitHub and using protocols other than HTTPS, e.g.,
          SSH, git, HTTP, FTP(S), rsync.
        '';
      };
      force_auto_update = mkNullOrBoolOption {
        description = ''
          Whether to auto-update the tap even if it is not hosted on GitHub. By default, only taps
          hosted on GitHub are auto-updated (for performance reasons).
        '';
      };

      brewfileLine = mkInternalOption { type = types.nullOr types.str; };
    };

    config =
      let
        sCfg = mkProcessedSubmodConfig config;
      in
      {
        brewfileLine =
          "tap ${sCfg.name}"
          + optionalString (sCfg ? clone_target) ", ${sCfg.clone_target}"
          + optionalString (sCfg ? force_auto_update)
            ", force_auto_update: ${sCfg.force_auto_update}";
      };
  };

  # Sourced from https://docs.brew.sh/Manpage#global-cask-options
  # and valid values for `HOMEBREW_CASK_OPTS`.
  caskArgsOptions = { config, ... }: {
    options = {
      appdir = mkNullOrStrOption {
        description = ''
          Target location for Applications.

          Homebrew's default is {file}`/Applications`.
        '';
      };
      colorpickerdir = mkNullOrStrOption {
        description = ''
          Target location for Color Pickers.

          Homebrew's default is {file}`~/Library/ColorPickers`.
        '';
      };
      prefpanedir = mkNullOrStrOption {
        description = ''
          Target location for Preference Panes.

          Homebrew's default is {file}`~/Library/PreferencePanes`.
        '';
      };
      qlplugindir = mkNullOrStrOption {
        description = ''
          Target location for QuickLook Plugins.

          Homebrew's default is {file}`~/Library/QuickLook`.
        '';
      };
      mdimporterdir = mkNullOrStrOption {
        description = ''
          Target location for Spotlight Plugins.

          Homebrew's default is {file}`~/Library/Spotlight`.
        '';
      };
      dictionarydir = mkNullOrStrOption {
        description = ''
          Target location for Dictionaries.

          Homebrew's default is {file}`~/Library/Dictionaries`.
        '';
      };
      fontdir = mkNullOrStrOption {
        description = ''
          Target location for Fonts.

          Homebrew's default is {file}`~/Library/Fonts`.
        '';
      };
      servicedir = mkNullOrStrOption {
        description = ''
          Target location for Services.

          Homebrew's default is {file}`~/Library/Services`.
        '';
      };
      input_methoddir = mkNullOrStrOption {
        description = ''
          Target location for Input Methods.

          Homebrew's default is {file}`~/Library/Input Methods`.
        '';
      };
      internet_plugindir = mkNullOrStrOption {
        description = ''
          Target location for Internet Plugins.

          Homebrew's default is {file}`~/Library/Internet Plug-Ins`.
        '';
      };
      audio_unit_plugindir = mkNullOrStrOption {
        description = ''
          Target location for Audio Unit Plugins.

          Homebrew's default is
          {file}`~/Library/Audio/Plug-Ins/Components`.
        '';
      };
      vst_plugindir = mkNullOrStrOption {
        description = ''
          Target location for VST Plugins.

          Homebrew's default is {file}`~/Library/Audio/Plug-Ins/VST`.
        '';
      };
      vst3_plugindir = mkNullOrStrOption {
        description = ''
          Target location for VST3 Plugins.

          Homebrew's default is {file}`~/Library/Audio/Plug-Ins/VST3`.
        '';
      };
      screen_saverdir = mkNullOrStrOption {
        description = ''
          Target location for Screen Savers.

          Homebrew's default is {file}`~/Library/Screen Savers`.
        '';
      };
      language = mkNullOrStrOption {
        description = ''
          Comma-separated list of language codes to prefer for cask installation. The first matching
          language is used, otherwise it reverts to the cask’s default language. The default value
          is the language of your system.
        '';
        example = "zh-TW";
      };
      require_sha = mkNullOrBoolOption {
        description = ''
          Whether to require cask(s) to have a checksum.

          Homebrew's default is `false`.
        '';
      };
      no_quarantine = mkNullOrBoolOption {
        description = "Whether to disable quarantining of downloads.";
      };
      no_binaries = mkNullOrBoolOption {
        description = "Whether to disable linking of helper executables.";
      };

      brewfileLine = mkInternalOption { type = types.nullOr types.str; };
    };

    config =
      let
        sCfg = mkProcessedSubmodConfig config;
      in
      {
        brewfileLine =
          if sCfg == { } then null
          else "cask_args ${mkBrewfileLineOptionsListString sCfg}";
      };
  };

  brewOptions = { config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        description = "The name of the formula to install.";
      };
      args = mkOption {
        type = with types; nullOr (listOf str);
        default = null;
        description = ''
          Arguments flags to pass to {command}`brew install`. Values should not include the
          leading `"--"`.
        '';
      };
      conflicts_with = mkOption {
        type = with types; nullOr (listOf str);
        default = null;
        description = ''
          List of formulae that should be unlinked and their services stopped (if they are
          installed).
        '';
      };
      restart_service = mkOption {
        type = with types; nullOr (either bool (enum [ "changed" ]));
        default = null;
        description = ''
          Whether to run {command}`brew services restart` for the formula and register it to
          launch at login (or boot). If set to `"changed"`, the service will only
          be restarted on version changes.

          Homebrew's default is `false`.
        '';
      };
      start_service = mkNullOrBoolOption {
        description = ''
          Whether to run {command}`brew services start` for the formula and register it to
          launch at login (or boot).

          Homebrew's default is `false`.
        '';
      };
      link = mkNullOrBoolOption {
        description = ''
          Whether to link the formula to the Homebrew prefix. When this option is
          `null`, Homebrew will use it's default behavior which is to link the
          formula if it's currently unlinked and not keg-only, and to unlink the formula if it's
          currently linked and keg-only.
        '';
      };

      brewfileLine = mkInternalOption { type = types.nullOr types.str; };
    };

    config =
      let
        sCfg = mkProcessedSubmodConfig config;
        sCfgSubset = removeAttrs sCfg [ "name" "restart_service" ];
      in
      {
        brewfileLine =
          "brew ${sCfg.name}"
          + optionalString (sCfgSubset != { }) ", ${mkBrewfileLineOptionsListString sCfgSubset}"
          # We need to handle the `restart_service` option seperately since it can be either a bool
          # or `:changed` in the Brewfile.
          + optionalString (sCfg ? restart_service) (
            ", restart_service: " + (
              if isBool config.restart_service then sCfg.restart_service
              else ":${config.restart_service}"
            )
          );
      };
  };

  caskOptions = { config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        description = "The name of the cask to install.";
      };
      args = mkOption {
        type = types.nullOr (types.submodule caskArgsOptions);
        default = null;
        visible = "shallow"; # so that options from `homebrew.caskArgs` aren't repeated.
        description = ''
          Arguments passed to {command}`brew install --cask` when installing this cask. See
          [](#opt-homebrew.caskArgs) for the available options.
        '';
      };
      greedy = mkNullOrBoolOption {
        description = ''
          Whether to always upgrade this cask regardless of whether it's unversioned or it updates
          itself.
        '';
      };

      brewfileLine = mkInternalOption { type = types.nullOr types.str; };
    };

    config =
      let
        sCfg = mkProcessedSubmodConfig config;
        sCfgSubset = removeAttrs sCfg [ "name" ];
      in
      {
        brewfileLine =
          "cask ${sCfg.name}"
          + optionalString (sCfgSubset != { }) ", ${mkBrewfileLineOptionsListString sCfgSubset}";
      };
  };
in

{
  # Interface --------------------------------------------------------------------------------------

  imports = [
    (mkRenamedOptionModule [ "homebrew" "autoUpdate" ] [ "homebrew" "onActivation" "autoUpdate" ])
    (mkRenamedOptionModule [ "homebrew" "cleanup" ] [ "homebrew" "onActivation" "cleanup" ])
  ];

  options.homebrew = {
    enable = mkEnableOption ''
      {command}`nix-darwin` to manage installing/updating/upgrading Homebrew taps, formulae,
      and casks, as well as Mac App Store apps and Docker containers, using Homebrew Bundle.

      Note that enabling this option does not install Homebrew, see the Homebrew
      [website](https://brew.sh) for installation instructions.

      Use the [](#opt-homebrew.brews), [](#opt-homebrew.casks),
      [](#opt-homebrew.masApps), and [](#opt-homebrew.whalebrews) options
      to list the Homebrew formulae, casks, Mac App Store apps, and Docker containers you'd like to
      install. Use the [](#opt-homebrew.taps) option, to make additional formula
      repositories available to Homebrew. This module uses those options (along with the
      [](#opt-homebrew.caskArgs) options) to generate a Brewfile that
      {command}`nix-darwin` passes to the {command}`brew bundle` command during
      system activation.

      The default configuration of this module prevents Homebrew Bundle from auto-updating Homebrew
      and all formulae, as well as upgrading anything that's already installed, so that repeated
      invocations of {command}`darwin-rebuild switch` (without any change to the
      configuration) are idempotent. You can modify this behavior using the options under
      [](#opt-homebrew.onActivation).

      This module also provides a few options for modifying how Homebrew commands behave when
      you manually invoke them, under [](#opt-homebrew.global)'';

    brewPrefix = mkOption {
      type = types.str;
      default = if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew/bin" else "/usr/local/bin";
      defaultText = literalExpression ''
        if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew/bin"
        else "/usr/local/bin"
      '';
      description = ''
        The path prefix where the {command}`brew` executable is located. This will be set to
        the correct value based on your system's platform, and should only need to be changed if you
        manually installed Homebrew in a non-standard location.
      '';
    };

    onActivation = mkOption {
      type = types.submodule onActivationOptions;
      default = { };
      description = ''
        Options for configuring the behavior of the {command}`brew bundle` command that
        {command}`nix-darwin` runs during system activation.
      '';
    };

    global = mkOption {
      type = types.submodule globalOptions;
      default = { };
      description = ''
        Options for configuring the behavior of Homebrew commands when you manually invoke them.
      '';
    };

    taps = mkOption {
      type = with types; listOf (coercedTo str (name: { inherit name; }) (submodule tapOptions));
      default = [ ];
      example = literalExpression ''
        # Adapted examples from https://github.com/Homebrew/homebrew-bundle#usage
        [
          # `brew tap`
          "homebrew/cask"

          # `brew tap` with custom Git URL and arguments
          {
            name = "user/tap-repo";
            clone_target = "https://user@bitbucket.org/user/homebrew-tap-repo.git";
            force_auto_update = true;
          }
        ]
      '';
      description = ''
        List of Homebrew formula repositories to tap.

        Taps defined as strings, e.g., `"user/repo"`, are a shorthand for:

        `{ name = "user/repo"; }`
      '';
    };

    caskArgs = mkOption {
      type = types.submodule caskArgsOptions;
      default = { };
      example = literalExpression ''
        {
          appdir = "~/Applications";
          require_sha = true;
        }
      '';
      description = ''
        Arguments passed to {command}`brew install --cask` for all casks listed in
        [](#opt-homebrew.casks).
      '';
    };

    brews = mkOption {
      type = with types; listOf (coercedTo str (name: { inherit name; }) (submodule brewOptions));
      default = [ ];
      example = literalExpression ''
        # Adapted examples from https://github.com/Homebrew/homebrew-bundle#usage
        [
          # `brew install`
          "imagemagick"

          # `brew install --with-rmtp`, `brew services restart` on version changes
          {
            name = "denji/nginx/nginx-full";
            args = [ "with-rmtp" ];
            restart_service = "changed";
          }

          # `brew install`, always `brew services restart`, `brew link`, `brew unlink mysql` (if it is installed)
          {
            name = "mysql@5.6";
            restart_service = true;
            link = true;
            conflicts_with = [ "mysql" ];
          }
        ]
      '';
      description = ''
        List of Homebrew formulae to install.

        Formulae defined as strings, e.g., `"imagemagick"`, are a shorthand for:

        `{ name = "imagemagick"; }`
      '';
    };

    casks = mkOption {
      type = with types; listOf (coercedTo str (name: { inherit name; }) (submodule caskOptions));
      default = [ ];
      example = literalExpression ''
        # Adapted examples from https://github.com/Homebrew/homebrew-bundle#usage
        [
          # `brew install --cask`
          "google-chrome"

          # `brew install --cask --appdir=~/my-apps/Applications`
          {
            name = "firefox";
            args = { appdir = "~/my-apps/Applications"; };
          }

          # always upgrade auto-updated or unversioned cask to latest version even if already installed
          {
            name = "opera";
            greedy = true;
          }
        ]
      '';
      description = ''
        List of Homebrew casks to install.

        Casks defined as strings, e.g., `"google-chrome"`, are a shorthand for:

        `{ name = "google-chrome"; }`
      '';
    };

    masApps = mkOption {
      type = types.attrsOf types.ints.positive;
      default = { };
      example = literalExpression ''
        {
          "1Password for Safari" = 1569813296;
          Xcode = 497799835;
        }
      '';
      description = ''
        Applications to install from Mac App Store using {command}`mas`.

        When this option is used, `"mas"` is automatically added to
        [](#opt-homebrew.brews).

        Note that you need to be signed into the Mac App Store for {command}`mas` to
        successfully install and upgrade applications, and that unfortunately apps removed from this
        option will not be uninstalled automatically even if
        [](#opt-homebrew.onActivation.cleanup) is set to `"uninstall"`
        or `"zap"` (this is currently a limitation of Homebrew Bundle).

        For more information on {command}`mas` see:
        [github.com/mas-cli/mas](https://github.com/mas-cli/mas).
      '';
    };

    whalebrews = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "whalebrew/wget" ];
      description = ''
        List of Docker images to install using {command}`whalebrew`.

        When this option is used, `"whalebrew"` is automatically added to
        [](#opt-homebrew.brews).

        For more information on {command}`whalebrew` see:
        [github.com/whalebrew/whalebrew](https://github.com/whalebrew/whalebrew).
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        # 'brew cask install' only if '/usr/libexec/java_home --failfast' fails
        cask "java" unless system "/usr/libexec/java_home --failfast"
      '';
      description = "Extra lines to be added verbatim to the bottom of the generated Brewfile.";
    };

    brewfile = mkInternalOption {
      type = types.str;
      description = "String reprensentation of the generated Brewfile useful for debugging.";
    };
  };


  # Implementation ---------------------------------------------------------------------------------

  config = {

    assertions = [
      # See comment above `homebrew.global.noLock` option declaration for why this is required.
      { assertion = cfg.global.noLock == null; message = "The option `homebrew.global.noLock' was removed, use `homebrew.global.lockfiles' in it's place."; }
    ];

    warnings = [
      (mkIf (options.homebrew.autoUpdate.isDefined || options.homebrew.cleanup.isDefined) "The `homebrew' module no longer upgrades outdated formulae and apps by default during `nix-darwin' system activation. To enable upgrading, set `homebrew.onActivation.upgrade = true'.")
    ];

    homebrew.brews =
      optional (cfg.masApps != { }) "mas"
      ++ optional (cfg.whalebrews != [ ]) "whalebrew";

    homebrew.brewfile =
      "# Created by `nix-darwin`'s `homebrew` module\n\n"
      + mkBrewfileSectionString "Taps" cfg.taps
      + mkBrewfileSectionString "Arguments for all casks"
        (optional (cfg.caskArgs.brewfileLine != null) cfg.caskArgs)
      + mkBrewfileSectionString "Brews" cfg.brews
      + mkBrewfileSectionString "Casks" cfg.casks
      + mkBrewfileSectionString "Mac App Store apps"
        (mapAttrsToList (n: id: ''mas "${n}", id: ${toString id}'') cfg.masApps)
      + mkBrewfileSectionString "Docker containers" (map (v: ''whalebrew "${v}"'') cfg.whalebrews)
      + optionalString (cfg.extraConfig != "") ("# Extra config\n" + cfg.extraConfig);

    environment.variables = mkIf cfg.enable cfg.global.homebrewEnvironmentVariables;

    system.activationScripts.homebrew.text = mkIf cfg.enable ''
      # Homebrew Bundle
      echo >&2 "Homebrew bundle..."
      if [ -f "${cfg.brewPrefix}/brew" ]; then
        PATH="${cfg.brewPrefix}":$PATH ${cfg.onActivation.brewBundleCmd}
      else
        echo -e "\e[1;31merror: Homebrew is not installed, skipping...\e[0m" >&2
      fi
    '';
  };
}
