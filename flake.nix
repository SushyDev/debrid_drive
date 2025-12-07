{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		sushy-lib = {
			url = "github:sushydev/nix-lib";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { self, nixpkgs, sushy-lib }: {
		devShells = sushy-lib.forPlatforms sushy-lib.platforms.default (system: 
			let
				pkgs = import nixpkgs { inherit system; };
			in 
			{
				default = pkgs.mkShell {
					buildInputs = [
						pkgs.beamMinimal28Packages.elixir_1_19
						pkgs.watchman
						pkgs.inotify-tools
						pkgs.protobuf
						pkgs.protoc-gen-elixir
						pkgs.sqlite
					];

					shellHook = ''
						echo "Elixir version: $(elixir --version)"
						export $(cat .env | xargs)
					'';
				};
			}
		);
	};
}
