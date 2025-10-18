{ pkgs
, suite ? "bookworm"
, architecture ? "amd64"
, variant ? "minbase"
, components ? [ "main" ]
, includePackages ? null
, hostKernelPackage ? "linux-image-amd64"
}:

let
  # Package grouping is maintained in ./package-groups so shell code stays clean.
  # Import it once here and reuse the result for all derived lists.
  packageGroups = import ./package-groups;

  # By default the live image always contains the packages from these groups.
  #  core      – base OS tooling (systemd, ssh, live-boot bits, etc.)
  #  kernel    – initramfs + kernel support infrastructure
  #  bootloader – grub/EFI packages required to boot the ISO
  essentialGroups = [
    packageGroups.core
    packageGroups.kernel
    packageGroups.bootloader
  ];
  essentialPackages = builtins.concatLists essentialGroups;
  defaultIncludePackages = pkgs.lib.lists.unique essentialPackages;

  # Callers can pass includePackages explicitly; otherwise we fall back to the
  # default essential set computed above.
  effectiveIncludePackages =
    if includePackages == null then defaultIncludePackages else includePackages;

  # All remaining groups are considered "optional". They are installed after
  # the base system is bootstrapped and failures are tolerated (recorded in
  # failed-optional-packages.txt for later inspection).
  optionalGroups = builtins.removeAttrs packageGroups [ "core" "kernel" "bootloader" ];
  rawOptionalPackages = builtins.concatLists (builtins.attrValues optionalGroups);
  optionalPackages =
    pkgs.lib.lists.unique (pkgs.lib.lists.subtractLists defaultIncludePackages rawOptionalPackages);
  optionalPackagesString = builtins.concatStringsSep " " optionalPackages;

  # debootstrap chokes if asked to include packages we don't want yet (like the
  # kernel meta-package). Remove those from the --include set and provide them
  # via --exclude instead.
  debootstrapExclusions = pkgs.lib.lists.unique (
    pkgs.lib.lists.remove null [
      hostKernelPackage
    ]
  );
  debootstrapExcludeString = builtins.concatStringsSep "," debootstrapExclusions;

  # The shell template receives pre-rendered CSV lists for clarity.
  componentsString = builtins.concatStringsSep "," components;
  includeString = builtins.concatStringsSep "," effectiveIncludePackages;

  # Wire everything into the shell script template. Any @token@ in the script
  # is replaced with the value we provide here, letting you edit the shell file
  # without touching the Nix plumbing.
  bootstrapScript = pkgs.replaceVars ./scripts/helix-os-base.sh {
    optionalPackagesString = optionalPackagesString;
    hostKernelPackage = hostKernelPackage;
    debootstrapExcludeString = debootstrapExcludeString;
    suite = suite;
    architecture = architecture;
    variant = variant;
    componentsString = componentsString;
    includeString = includeString;
  };
in

pkgs.writeShellApplication {
  name = "helix-os-base";

  # Executable dependencies used by the rendered script.
  runtimeInputs = with pkgs; [
    debootstrap
    util-linux
    coreutils
    findutils
    squashfsTools
    xorriso
    mtools
    grub2
  ];

  # Embed the substituted shell script as the application payload.
  text = builtins.readFile bootstrapScript;
}
