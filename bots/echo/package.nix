# The reference kmatrix bot, as a package.
#
# Go dependencies come from go.mod/go.sum via `vendorHash` — there is no
# `pythonPackages`-style list to keep in sync. Bump a dependency by
# running `go get`/`go mod tidy` here and updating the hash.
{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "kmatrix-echo";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-ZiCiMyEPDjhQx9jeZwk/iw4ds4oxPkE/QdxoiqSjrZg=";

  # The Go module's last path element is `echo`; give the binary a name
  # that is unambiguous in `ps`, `journalctl` and $PATH.
  postInstall = ''
    mv $out/bin/echo $out/bin/kmatrix-echo
  '';

  meta = {
    description = "Reference Matrix chatbot for the kmatrix module";
    mainProgram = "kmatrix-echo";
    license = lib.licenses.mit;
  };
}
