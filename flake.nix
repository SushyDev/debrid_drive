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

		apps = sushy-lib.forPlatforms sushy-lib.platforms.default (system:
			let
				pkgs = import nixpkgs { inherit system; };
			in
			{
				sync-db = {
					name = "sync-db";
					type = "app";
					program = "${pkgs.writeShellScript "sync-db" ''
						set -e
						REMOTE_HOST="pulsar"
						REMOTE_PATH="~/docker/mediaserver/data/debrid_drive/debrid_stream_prod.db"
						LOCAL_DB="debrid_stream_dev.db"
						echo "Copying database from $REMOTE_HOST:$REMOTE_PATH to $LOCAL_DB"
						scp "$REMOTE_HOST:$REMOTE_PATH" "$LOCAL_DB.tmp"
						scp "$REMOTE_HOST:$REMOTE_PATH-shm" "$LOCAL_DB-shm.tmp" 2>/dev/null || true
						scp "$REMOTE_HOST:$REMOTE_PATH-wal" "$LOCAL_DB-wal.tmp" 2>/dev/null || true
						mv "$LOCAL_DB.tmp" "$LOCAL_DB"
						mv "$LOCAL_DB-shm.tmp" "$LOCAL_DB-shm" 2>/dev/null || true
						mv "$LOCAL_DB-wal.tmp" "$LOCAL_DB-wal" 2>/dev/null || true
						echo "Database synced successfully"
					''}";
				};
			}
		);
	};
}
