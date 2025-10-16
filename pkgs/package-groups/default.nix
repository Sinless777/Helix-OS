{
  pentest = import ./pentest.nix;
  networking = import ./networking.nix;
  desktopEnv = import ./desktop-env.nix;
  kernel = import ./kernel.nix;
  bootloader = import ./bootloader.nix;
  k8s = import ./k8s.nix;
  devTools = import ./dev-tools.nix;
  hacking = import ./hacking.nix;
  sandboxing = import ./sandboxing.nix;
  devLanguages = import ./dev-languages.nix;
}
