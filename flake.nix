{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			supportedSystems = nixpkgs.lib.platforms.all;
			devShells = 
				nixpkgs.lib.genAttrs supportedSystems (system: 
				let
					pkgs = import nixpkgs { inherit system; };
					inherit (pkgs) stdenv;
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
		in
		let
			supportedSystems = nixpkgs.lib.platforms.all;
			packages = {};
		in
		{
			inherit devShells packages;
		};
}
