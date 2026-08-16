# Mill nix flake

This flake introduces several functions for working with mill in nix:
- `mkMill` for creating mill package for certain version
- `mkMillFromFile` for creating mill package based on .mill-version file
- `buildMillProject` for wrapping mill projects to applications 

Note that default arguments to `buildMillProject` rely on Mill being at least 1.1.0 for fetching dependencies so if you use older versions you should pass your own `fetchCommand` 

## Example

```nix
{
  description = "Example flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
	mill-flake.url = "github:GoogeTan/mill-nix";
  };

  outputs = { self, nixpkgs, mill-flake }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          jdk = pkgs.jdk21;
          millLib = mill-flake.lib.${system};
          mill = millLib.mkMillFromFile {
            filePath = ./.mill-version;
            hash = "sha256-zssJgQWY4QI0giYPGeviUbgZ2z8XtIyvkP0BoqcfRbc=";
            inherit jdk;
          };
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              mill
              jdk
            ];
          };
        }
      );

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          jdk = pkgs.jdk21;
          millLib = mill-flake.lib.${system};
          mill = millLib.mkMillFromFile {
            filePath = ./.mill-version;
            hash = "sha256-zssJgQWY4QI0giYPGeviUbgZ2z8XtIyvkP0BoqcfRbc=";
            inherit jdk;
          };
        in
        {
          default = millLib.buildMillProject {
            pname = "my-example-application";
            version = "1.0.0";
            src = ./.;
            millPackage = mill;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            hash = pkgs.lib.fakeHash;
            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              cp out/assembly.dest/out.jar $out/bin/app.jar
              makeWrapper ${jdk}/bin/java $out/bin/my-app \
                --add-flags "-jar $out/bin/app.jar"

              runHook postInstall
            '';
          };
        }
      );
    };
}
```
This example will fail with hash mismatch and print the right hash.
You should replace pkgs.lib.fakeHash with the correct hash string for project to compile


## Api reference

### mkMill
Creates a package for a specific version of Mill
- `version` (String): The Mill version to download (e.g., "1.1.0").
- `hash` (String): The SHA256 hash of the Mill binary.
- `jdk` (Package, optional): The JDK for Mill to use(Mill itself is precompiled with GraalVM but it uses Zinc and scala compiler which require JDK). Defaults to pkgs.jdk21.

### mkMillFromFile
The same as mkMill but reads version from provided file:
- `filePath` (Path): Path to project's .mill-version file.
- `hash` (String): The SHA256 hash of the Mill binary.
- `jdk` (Package, optional): The JDK for Mill to use(Mill itself is precompiled with GraalVM but it uses Zinc and scala compiler which require JDK). Defaults to pkgs.jdk21.

### buildMillProject
A wrapper around `stdenv.mkDerivation` for wrapping mill projects. It uses two-phase build for dependency extraction(may download dependencies from the internet)
and actual project build(isolated and can't use internet).
- `pname`, `version`, `src`, `buildInputs`, `nativeBuildInputs`: Standard mkDerivation arguments
- `millPackage` (Package): The Mill package to use (e.g., generated from mkMill). Must provide a binary named `mill` unless both fetchCommand and buildPhase are overriden to use something else).
- `fetchCommand` (String, optional): The Mill command used to fetch dependencies. Defaults to "mill --no-server __.prepareOffline"
- `buildPhase` (String, optional): The Mill command to build the project. Defaults to ''mill --no-server assembly''
- `installPhase` (String, optional): Script that forms an output application from Mill output. Defaults to:
	```bash
    mkdir -p $out/bin
    cp out/assembly.dest/out.jar $out/bin/
    ```
- `hash` (String, optional): Hash of all project dependencies. Defaults to `pkgs.lib.fakeHash`. 
