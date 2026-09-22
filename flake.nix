{
  description = "Lean task manager development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/25.11";
  outputs = { self, nixpkgs }:
    let pkgs = import nixpkgs { system = "x86_64-linux"; };
    in {
      devShell.x86_64-linux = pkgs.mkShell {
        buildInputs = [ pkgs.elan pkgs.python312 ];
      };
    };
}
