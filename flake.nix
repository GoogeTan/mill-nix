{
  description = "Reusable pure Nix flake for Mill 1.1.x (native builds)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Platform-specific suffix for Mill 1.x native builds
        nativeSuffix = 
          if system == "aarch64-darwin" then "-native-mac-aarch64"
          else if system == "x86_64-darwin" then "-native-mac-amd64"
          else if system == "aarch64-linux" then "-native-linux-aarch64"
          else if system == "x86_64-linux" then "-native-linux-amd64"
          else throw "Unsupported system: ${system}";

        mkMill = { version, hash, jdk ? pkgs.jdk21 }:
          pkgs.stdenvNoCC.mkDerivation {
            pname = "mill";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://repo1.maven.org/maven2/com/lihaoyi/mill-dist${nativeSuffix}/${version}/mill-dist${nativeSuffix}-${version}.exe";
              hash = hash.${system};
            };

            dontUnpack = true;
            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin

              install -m755 $src $out/bin/mill

              wrapProgram $out/bin/mill \
                --set JAVA_HOME ${jdk} \
                --prefix PATH : ${jdk}/bin

              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Mill build tool ${version} (native)";
              homepage = "https://mill-build.org/";
              license = licenses.mit;
              platforms = platforms.unix;
              meta.mainProgram = "mill";
            };
          };

        mkMillFromFile = { filePath, hash, jdk ? pkgs.jdk21  }:
          let
            raw = builtins.readFile filePath;
            version = pkgs.lib.strings.trim raw;
          in
            mkMill { inherit version hash jdk; };

        # Makes a source that consists only of build configs and meta build
        makeMillConfigsSrc = original:
            pkgs.lib.cleanSourceWith {
                src = pkgs.lib.cleanSource original;
                filter = path: type:
                  let
                    baseName = baseNameOf (toString path);
                  in
                    type == "directory" ||
                    baseName == ".mill-version" ||
                    baseName == "build.sc" ||
                    pkgs.lib.hasSuffix ".mill" baseName ||
                    baseName == "build.mill.yaml" ||
                    baseName == "package.mill" ||
                    baseName == "package.mill.yaml" ||
                    builtins.match ".*/(\\.mill|mill-build)/.*" path != null;
              };

        buildMillProject = {
            pname,
            version,
            src,
            depsSrc ? makeMillConfigsSrc src,
            millPackage,
            buildInputs ? [],
            nativeBuildInputs ? [],
            hash ? pkgs.lib.fakeHash,
            fetchCommand ? "${millPackage}/bin/mill --no-server __.prepareOffline",
            buildPhase ? ''${millPackage}/bin/mill --no-server assembly'',
            installPhase ? ''
                mkdir -p $out/bin
                cp out/assembly.dest/out.jar $out/bin/
            ''
          }:
           let
             deps = pkgs.stdenv.mkDerivation {
                inherit pname version buildInputs;
                src = depsSrc;
                #pkgs.cacert is needed for ssl verification for coursier
                nativeBuildInputs = nativeBuildInputs ++ [millPackage pkgs.cacert];
                
                buildPhase = ''
                  echo "DEBUG"
                  ls ${depsSrc}

                  runHook preBuild
                  export HOME=$NIX_BUILD_TOP/home
                  # Force Java to use our tmpdir instead of /var/empty on macOS
                  export _JAVA_OPTIONS="-Duser.home=$HOME"

                  
                  # Force Mill to use JAVA_HOME instead of downloading its own JVM
                  echo "system" > .mill-jvm-version

                  export COURSIER_CACHE=$HOME/coursier
                  export COURSIER_ARCHIVE_CACHE=$COURSIER_CACHE/arc
                  export COURSIER_JVM_CACHE=$COURSIER_CACHE/jvm
                  export COURSIER_CONFIG_DIR=$COURSIER_CACHE/config
                  export COURSIER_DATA_DIR=$COURSIER_CACHE/data

                  export XDG_CACHE_HOME=$HOME/mill
                  ${fetchCommand}
                  runHook postBuild
                '';

                installPhase = ''
                  mkdir -p $out
                  mkdir -p $out/coursier
                  mkdir -p $out/mill
                  mkdir -p $out/.ivy2
                  mkdir -p $COURSIER_CACHE
                  mkdir -p $XDG_CACHE_HOME
                  mkdir -p $HOME/.ivy2
                  cp -a $COURSIER_CACHE/. $out/coursier/
                  cp -a $XDG_CACHE_HOME/. $out/mill/
                  cp -a $HOME/.ivy2/. $out/.ivy2/
                  # Remove Coursier lockfiles and volatile files to ensure the hash is deterministic
                  find $out \( -name maven-metadata.xml \) -delete
                  find $out -name "*.log" -delete
                  find $out -type f -name "*.lock" -delete
                  find $out -name "*.lastUpdated" -delete
                  find $out -name "_remote.repositories" -delete
                '';
                    
                outputHashMode = "recursive";
                outputHash = hash;
             };
           in pkgs.stdenv.mkDerivation {
                inherit pname version src buildInputs installPhase;
                nativeBuildInputs = nativeBuildInputs ++ [millPackage];
          
                buildPhase = ''
                  runHook preBuild
                  export HOME=$NIX_BUILD_TOP/home
                  mkdir -p $HOME
                  export _JAVA_OPTIONS="-Duser.home=$HOME"
              
                  # Create a writable directory for Coursier. Even in offline mode,
                  # Coursier attempts to write lockfiles, which fails in the read-only Nix store.
                  export COURSIER_CACHE=$NIX_BUILD_TOP/coursier_cache
                  export XDG_CACHE_HOME=$NIX_BUILD_TOP/xdg_cache_home

                  # Force Mill to use JAVA_HOME instead of downloading its own JVM
                  echo "system" > .mill-jvm-version
                
                  # Copy the pre-downloaded dependencies into our writable cache
                  cp -a ${deps}/coursier/. $COURSIER_CACHE/
                  chmod -R u+w $COURSIER_CACHE
                  # Copy mill dependencies, runners, and etc
                  cp -a ${deps}/mill/. $XDG_CACHE_HOME/
                  # it has to be writable due to read/write locks.
                  chmod -R u+w $XDG_CACHE_HOME
                  cp -a ${deps}/.ivy2 $HOME/.ivy2/
                  # it has to be writable due to read/write locks.
                  chmod -R u+w $HOME/.ivy2
              
                  # Force offline mode so Coursier doesn't attempt network calls
                  export COURSIER_MODE=offline

                  ${buildPhase}
                  runHook postBuild
                '';
           };

        buildMillApplication = {
            pname,
            binaryName ? pname,
            version,
            src,
            depsSrc ? makeMillConfigsSrc src,
            millPackage,
            buildInputs ? [],
            nativeBuildInputs ? [],
            hash ? pkgs.lib.fakeHash,
            fetchCommand ? "mill --no-server __.prepareOffline",
            buildPhase ? ''mill --no-server assembly'',
            javaPackage ? pkgs.jre21_minimal
          }:
          buildMillProject {
            inherit pname version src depsSrc millPackage buildInputs nativeBuildInputs hash fetchCommand buildPhase;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp out/assembly.dest/out.jar $out/bin/app.jar
              makeWrapper ${javaPackage}/bin/java $out/bin/${binaryName} \
                --add-flags "-jar $out/bin/app.jar"

              runHook postInstall
            '';
          };
      in
      {
        lib = {
          inherit mkMill mkMillFromFile buildMillProject;
        };

        # Example (update with your version + hash)
        packages.default = mkMill {
          version = "1.1.0";
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      });
}
